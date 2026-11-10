defmodule ChainGuard.Rules.Evaluator do
  @moduledoc """
  Pure evaluation of a rule against one block. No processes, no I/O.

  `evaluate/3` takes the rule, its per-chain state (only `window` rules have
  any) and a block context, and returns alert *candidates* plus the new
  state. `orphan/3` drops a reorged block's contributions from window state.

  A block context is `%{chain_id, block, records, txs}`, where `txs` maps
  each tx hash to its records in log order.
  """

  alias ChainGuard.Record
  alias ChainGuard.Rules.{Predicate, Rule, Template}

  @max_window_evidence 20

  @type ctx :: %{
          chain_id: integer(),
          block: map(),
          records: [map()],
          txs: %{String.t() => [map()]}
        }
  @type candidate :: %{
          rule: Rule.t(),
          dedup_key: String.t(),
          title: String.t(),
          evidence: [map()],
          block: map(),
          chain_id: integer()
        }

  @doc "Group a block's records by transaction, preserving log order."
  def context(chain_id, block, records) do
    records = Enum.sort_by(records, & &1["log_index"])
    txs = Enum.group_by(records, & &1["tx_hash"])
    %{chain_id: chain_id, block: block, records: records, txs: txs}
  end

  def initial_state, do: %{}

  @spec evaluate(Rule.t(), map(), ctx()) :: {[candidate()], map()}
  def evaluate(%Rule{enabled: false}, state, _ctx), do: {[], state}

  def evaluate(%Rule{scope: :record} = rule, state, ctx) do
    candidates =
      for r <- ctx.records, Predicate.matches?(rule.match, r) do
        candidate(rule, [r], ctx, fn path -> Record.get(r, path) end)
      end

    {candidates, state}
  end

  def evaluate(%Rule{scope: :tx} = rule, state, ctx) do
    candidates =
      ctx.txs
      |> Enum.sort_by(fn {_, [first | _]} -> first["log_index"] end)
      |> Enum.flat_map(fn {tx_hash, recs} ->
        results = Enum.map(rule.require, fn q -> {q.name, satisfy(q, recs)} end)

        if Enum.all?(results, fn {_, r} -> r != nil end) do
          results = Map.new(results)

          evidence =
            rule.evidence
            |> Enum.flat_map(&results[&1].records)
            |> Enum.uniq_by(& &1["id"])
            |> Enum.sort_by(& &1["log_index"])

          [candidate(rule, evidence, ctx, tx_lookup(tx_hash, results, evidence))]
        else
          []
        end
      end)

    {candidates, state}
  end

  def evaluate(%Rule{scope: :window} = rule, state, ctx) do
    ws = Map.get(state, ctx.chain_id, %{entries: %{}, fired: MapSet.new(), seen: %{}, blocks: 0})
    ws = %{ws | blocks: ws.blocks + 1}
    number = ctx.block["number"]

    matched =
      ctx.records
      |> Enum.filter(&Predicate.matches?(rule.match, &1))
      |> Enum.flat_map(fn r ->
        case norm(Record.get(r, rule.group_by)) do
          nil ->
            []

          g ->
            entry = %{
              block_number: number,
              block_hash: ctx.block["hash"],
              distinct: norm(Record.get(r, rule.distinct)),
              record: r
            }

            [{g, entry}]
        end
      end)

    seen =
      Enum.reduce(matched, ws.seen, fn {g, _}, acc -> Map.put_new(acc, g, ws.blocks) end)

    entries =
      Enum.reduce(matched, ws.entries, fn {g, e}, acc -> Map.update(acc, g, [e], &[e | &1]) end)
      |> prune(number - rule.within_blocks + 1)

    touched = matched |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    {candidates, fired} =
      Enum.reduce(touched, {[], ws.fired}, fn g, {cands, fired} ->
        group_entries = Map.get(entries, g, [])
        distinct = group_entries |> Enum.uniq_by(& &1.distinct) |> Enum.reverse()
        count = length(distinct)
        qualifies = not rule.novel_group or Map.fetch!(seen, g) > rule.warmup_blocks

        if count >= rule.threshold and qualifies and not MapSet.member?(fired, g) do
          evidence = distinct |> Enum.take(@max_window_evidence) |> Enum.map(& &1.record)

          vars = %{
            "group" => g,
            "count" => count,
            "threshold" => rule.threshold,
            "within_blocks" => rule.within_blocks
          }

          lookup = fn
            "first." <> path -> Record.get(hd(evidence), path)
            key -> Map.get(vars, key, Record.get(hd(evidence), key))
          end

          {[candidate(rule, evidence, ctx, lookup) | cands], MapSet.put(fired, g)}
        else
          {cands, fired}
        end
      end)

    ws = %{ws | entries: entries, seen: seen, fired: refire(fired, entries, rule.threshold)}
    {Enum.reverse(candidates), Map.put(state, ctx.chain_id, ws)}
  end

  @doc "Forget everything a now-orphaned block contributed to window state."
  def orphan(%Rule{scope: :window} = rule, state, {chain_id, block_hash}) do
    case Map.fetch(state, chain_id) do
      {:ok, ws} ->
        entries =
          ws.entries
          |> Map.new(fn {g, es} -> {g, Enum.reject(es, &(&1.block_hash == block_hash))} end)
          |> Map.reject(fn {_, es} -> es == [] end)

        Map.put(state, chain_id, %{
          ws
          | entries: entries,
            fired: refire(ws.fired, entries, rule.threshold)
        })

      :error ->
        state
    end
  end

  def orphan(_rule, state, _), do: state

  # A group may fire again once it has dropped back below the threshold.
  defp refire(fired, entries, threshold) do
    MapSet.filter(fired, fn g ->
      entries |> Map.get(g, []) |> Enum.uniq_by(& &1.distinct) |> length() >= threshold
    end)
  end

  defp prune(entries, min_block) do
    entries
    |> Map.new(fn {g, es} -> {g, Enum.filter(es, &(&1.block_number >= min_block))} end)
    |> Map.reject(fn {_, es} -> es == [] end)
  end

  defp norm(<<"0x", _::binary>> = s), do: String.downcase(s)
  defp norm(v), do: v

  # --- tx requirements -------------------------------------------------------

  defp satisfy(%{type: :match} = q, recs) do
    matched = Enum.filter(recs, &Predicate.matches?(q.match, &1))
    sum = matched |> Enum.map(&(Record.get(&1, "value_usd") || 0)) |> Enum.sum()

    cond do
      length(matched) < q.min_count -> nil
      q.sum_gte != nil and sum < q.sum_gte -> nil
      true -> %{records: matched, count: length(matched), value_usd: sum, first: hd(matched)}
    end
  end

  # Net USD outflow per labeled party across the transaction's priced token
  # transfers. A flash-loan lender sends the principal out and gets it back
  # plus a fee, so its net flow is positive. A drained protocol's is not.
  defp satisfy(%{type: :net_outflow} = q, recs) do
    transfers =
      Enum.filter(recs, fn r ->
        Record.get(r, "kind") == "erc20_transfer" and is_number(Record.get(r, "value_usd"))
      end)

    flows =
      Enum.reduce(transfers, %{}, fn r, acc ->
        v = Record.get(r, "value_usd")

        acc
        |> add_flow(Record.label(r, "from"), q.party_category, -v, r)
        |> add_flow(Record.label(r, "to"), q.party_category, v, r)
      end)

    case Enum.min_by(Map.values(flows), & &1.net, fn -> nil end) do
      %{net: net} = party when -net >= q.gte_usd ->
        %{
          records: Enum.reverse(party.records),
          count: length(party.records),
          value_usd: -net,
          first: List.last(party.records),
          address: party.address,
          name: party.name,
          protocol: party.protocol
        }

      _ ->
        nil
    end
  end

  defp add_flow(acc, nil, _cats, _v, _r), do: acc

  defp add_flow(acc, label, cats, v, r) do
    if label["category"] in cats do
      addr = String.downcase(label["address"])

      init = %{
        net: 0,
        records: [],
        address: addr,
        name: label["name"],
        protocol: label["protocol"]
      }

      Map.update(
        acc,
        addr,
        %{init | net: v, records: [r]},
        &%{&1 | net: &1.net + v, records: [r | &1.records]}
      )
    else
      acc
    end
  end

  defp tx_lookup(tx_hash, results, evidence) do
    fn
      "tx_hash" ->
        tx_hash

      path ->
        case String.split(path, ".", parts: 2) do
          [name, rest] when is_map_key(results, name) -> requirement_var(results[name], rest)
          _ -> Record.get(hd(evidence), path)
        end
    end
  end

  defp requirement_var(res, "first." <> path), do: Record.get(res.first, path)

  defp requirement_var(res, key) when key in ~w(count value_usd address name protocol),
    do: Map.get(res, String.to_existing_atom(key))

  defp requirement_var(res, path), do: Record.get(res.first, path)

  defp candidate(rule, evidence, ctx, lookup) do
    %{
      rule: rule,
      dedup_key: "#{rule.id}:" <> Template.render(rule.dedup_key, lookup),
      title: Template.render(rule.title, lookup),
      evidence: evidence,
      block: ctx.block,
      chain_id: ctx.chain_id
    }
  end
end
