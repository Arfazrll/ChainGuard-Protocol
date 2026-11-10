defmodule ChainGuard.Invariants.Check do
  @moduledoc """
  Pure invariant checks. No processes, no I/O.

  `evaluate/3` takes an invariant, its state and a block context (the same
  `%{chain_id, block, records, txs}` the rules get) and returns alert
  candidates plus the new state. Reorg handling lives in the monitor, which
  snapshots state per block and restores it when a block is orphaned, so
  every check here is written as if the chain never reorgs.
  """

  alias ChainGuard.Invariants.Invariant
  alias ChainGuard.Record
  alias ChainGuard.Rules.{Rule, Template}

  @max_evidence 20

  def init(%Invariant{kind: :peg}), do: %{price: nil, deviation: nil, tier: nil, last: nil}

  def init(%Invariant{kind: :oracle}),
    do: %{price: nil, last: nil, last_ts: nil, stale: false, age_s: nil}

  def init(%Invariant{kind: :outflow}), do: %{entries: [], fired: false, window_net: 0.0}

  @spec evaluate(Invariant.t(), map(), map()) :: {[map()], map()}
  def evaluate(%Invariant{enabled: false}, st, _ctx), do: {[], st}

  # --- peg ---------------------------------------------------------------------

  def evaluate(%Invariant{kind: :peg, params: p} = inv, st, ctx) do
    ctx
    |> oracle_updates(p.feed)
    |> Enum.reduce({[], st}, fn {r, price}, {acc, st} ->
      dev = abs(price - p.peg_usd) / p.peg_usd
      tier = Enum.filter(p.bands, &(dev >= &1.deviation)) |> List.last()
      st2 = %{st | price: price, deviation: dev, tier: tier, last: Record.evidence(r)}

      if tier && rank(tier) > rank(st.tier) do
        title =
          "#{p.feed.name} at #{price(price)}: #{pct(dev)} off its #{price(p.peg_usd)} peg " <>
            "(band #{pct(tier.deviation)})"

        c = candidate(inv, tier.severity, "#{inv.id}:#{tier.severity}", title, [r], ctx)
        {[c | acc], st2}
      else
        {acc, st2}
      end
    end)
    |> then(fn {cs, st} -> {Enum.reverse(cs), st} end)
  end

  # --- oracle ------------------------------------------------------------------

  def evaluate(%Invariant{kind: :oracle, params: p} = inv, st, ctx) do
    ts = ctx.block["timestamp"]

    {cs, st} =
      ctx
      |> oracle_updates(p.feed)
      |> Enum.reduce({[], st}, fn {r, price}, {acc, st} ->
        acc =
          if is_number(st.price) and st.price > 0 and
               abs(price - st.price) / st.price > p.max_jump do
            jump = (price - st.price) / st.price

            title =
              "#{p.feed.name} moved #{signed_pct(jump)} in one update " <>
                "(#{price(st.price)} → #{price(price)}; limit #{pct(p.max_jump)})"

            round = get_in(r, ["event", "round_id"]) || r["id"]
            [candidate(inv, p.jump_severity, "#{inv.id}:jump:#{round}", title, [r], ctx) | acc]
          else
            acc
          end

        {acc, %{st | price: price, last: r, last_ts: ts, stale: false, age_s: 0}}
      end)

    # Staleness is judged at block time: the chain's clock, not ours.
    age = if is_integer(ts) and is_integer(st.last_ts), do: ts - st.last_ts
    st = %{st | age_s: age}

    if is_integer(age) and age > p.max_age_s and not st.stale do
      title =
        "#{p.feed.name} is stale: no update for #{duration(age)} at block ##{ctx.block["number"]} " <>
          "(limit #{duration(p.max_age_s)})"

      c =
        candidate(
          inv,
          p.stale_severity,
          "#{inv.id}:stale:#{st.last["id"]}",
          title,
          [st.last],
          ctx
        )

      {Enum.reverse([c | cs]), %{st | stale: true}}
    else
      {Enum.reverse(cs), st}
    end
  end

  # --- outflow -------------------------------------------------------------------

  def evaluate(%Invariant{kind: :outflow, params: p} = inv, st, ctx) do
    number = ctx.block["number"]
    {net, outs} = net_flow(inv.protocol, ctx.records)

    entries =
      [%{number: number, net: net, outs: outs} | st.entries]
      |> Enum.filter(&(&1.number > number - p.within_blocks))

    window_net = entries |> Enum.map(& &1.net) |> Enum.sum()
    st = %{st | entries: entries, window_net: window_net}

    cond do
      window_net >= p.max_net_outflow_usd and not st.fired ->
        evidence =
          entries
          |> Enum.flat_map(& &1.outs)
          |> Enum.sort_by(&(-(Record.get(&1, "value_usd") || 0)))
          |> Enum.take(@max_evidence)

        party = party_name(inv, evidence)

        share =
          if p.reference_tvl_usd,
            do: " (#{pct(window_net / p.reference_tvl_usd)} of reference TVL)",
            else: ""

        title =
          "#{party} net outflow #{Template.usd(window_net)} within #{p.within_blocks} blocks#{share}; " <>
            "limit #{Template.usd(p.max_net_outflow_usd)}"

        c = candidate(inv, p.severity, inv.id, title, evidence, ctx)
        {[c], %{st | fired: true}}

      # Hysteresis: re-arm only once the window has clearly recovered.
      st.fired and window_net < p.max_net_outflow_usd / 2 ->
        {[], %{st | fired: false}}

      true ->
        {[], st}
    end
  end

  @doc """
  Net USD flow out of the addresses labeled with `protocol`, from priced
  transfers. Transfers between two of the protocol's own contracts cancel
  out. Returns `{net_out_usd, outflow_records}`.
  """
  def net_flow(protocol, records) do
    Enum.reduce(records, {0.0, []}, fn r, {net, outs} ->
      v = Record.get(r, "value_usd")

      if Record.get(r, "kind") == "erc20_transfer" and is_number(v) do
        from? = party?(r, "from", protocol)
        to? = party?(r, "to", protocol)

        cond do
          from? and not to? -> {net + v, [r | outs]}
          to? and not from? -> {net - v, outs}
          true -> {net, outs}
        end
      else
        {net, outs}
      end
    end)
  end

  defp party?(r, role, protocol) do
    case Record.label(r, role) do
      %{"protocol" => ^protocol} -> true
      _ -> false
    end
  end

  defp party_name(inv, [r | _]) do
    case Record.label(r, "from") do
      %{"name" => name} when is_binary(name) -> name
      _ -> inv.protocol
    end
  end

  defp party_name(inv, []), do: inv.protocol

  # --- status --------------------------------------------------------------------

  @doc "A JSON-friendly snapshot for the dashboard and `/api/invariants`."
  def status(%Invariant{kind: :peg, params: p} = inv, st) do
    base(inv, %{
      state: pick(st.price == nil, :warming_up, if(st.tier, do: :breached, else: :ok)),
      value: st.price,
      unit: "usd",
      deviation: st.deviation,
      limit: hd(p.bands).deviation,
      feed: p.feed.name,
      evidence: st.last
    })
  end

  def status(%Invariant{kind: :oracle, params: p} = inv, st) do
    base(inv, %{
      state: pick(st.price == nil, :warming_up, if(st.stale, do: :breached, else: :ok)),
      value: st.price,
      unit: "usd",
      age_s: st.age_s,
      limit: p.max_age_s,
      feed: p.feed.name,
      evidence: st.last && Record.evidence(st.last)
    })
  end

  def status(%Invariant{kind: :outflow, params: p} = inv, st) do
    base(inv, %{
      state: pick(st.entries == [], :warming_up, if(st.fired, do: :breached, else: :ok)),
      value: st.window_net,
      unit: "usd",
      limit: p.max_net_outflow_usd,
      within_blocks: p.within_blocks,
      blocks_observed: length(st.entries)
    })
  end

  defp base(inv, m),
    do:
      Map.merge(
        %{
          id: inv.id,
          name: inv.name,
          kind: inv.kind,
          protocol: inv.protocol,
          chain_id: inv.chain_id
        },
        m
      )

  defp pick(true, a, _), do: a
  defp pick(false, _, b), do: b

  # --- helpers -------------------------------------------------------------------

  defp oracle_updates(ctx, feed) do
    for r <- ctx.records,
        Record.get(r, "kind") == "oracle_answer_updated",
        String.downcase(r["contract"] || "") in feed.aggregators,
        price = answer(r, feed.decimals),
        is_number(price),
        do: {r, price}
  end

  defp answer(r, decimals) do
    case get_in(r, ["event", "answer"]) do
      a when is_binary(a) ->
        case Integer.parse(a) do
          {n, ""} -> n / :math.pow(10, decimals)
          _ -> nil
        end

      a when is_integer(a) ->
        a / :math.pow(10, decimals)

      _ ->
        nil
    end
  end

  defp candidate(inv, severity, dedup_key, title, evidence, ctx) do
    %{
      rule: Invariant.as_rule(inv, severity),
      lane: "invariant",
      dedup_key: dedup_key,
      title: title,
      evidence: evidence,
      block: ctx.block,
      chain_id: ctx.chain_id
    }
  end

  defp rank(nil), do: -1
  defp rank(%{severity: s}), do: Rule.severity_rank(s)

  defp price(v), do: "$" <> :erlang.float_to_binary(v * 1.0, decimals: 4)
  defp pct(f), do: :erlang.float_to_binary(f * 100.0, decimals: 2) <> "%"
  defp signed_pct(f) when f >= 0, do: "+" <> pct(f)
  defp signed_pct(f), do: "-" <> pct(-f)

  defp duration(s) when s >= 3600, do: "#{Float.round(s / 3600, 1)} h"
  defp duration(s) when s >= 60, do: "#{div(s, 60)} min"
  defp duration(s), do: "#{s} s"
end
