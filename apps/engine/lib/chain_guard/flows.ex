defmodule ChainGuard.Flows do
  @moduledoc """
  Fund-flow edges for the live graph: priced token transfers of one block,
  aggregated per `from → to` pair.

  Only the largest edges are kept, plus every edge that touches a mixer or a
  bridge (where stolen funds go), so the graph stays readable at 1,000+
  transfers per block and the paths that matter are never cut.
  """

  alias ChainGuard.Record

  @top 40
  @watch_categories ~w(mixer bridge)

  @doc "Sum of priced ERC-20 transfer value in a block, in USD."
  def priced_volume(records) do
    for r <- records,
        Record.get(r, "kind") == "erc20_transfer",
        v = Record.get(r, "value_usd"),
        is_number(v),
        reduce: 0.0,
        do: (acc -> acc + v)
  end

  @spec edges([map()]) :: [map()]
  def edges(records) do
    all =
      records
      |> Enum.filter(
        &(Record.get(&1, "kind") == "erc20_transfer" and is_number(Record.get(&1, "value_usd")))
      )
      |> Enum.group_by(
        &{lower(get_in(&1, ["event", "from"])), lower(get_in(&1, ["event", "to"]))}
      )
      |> Enum.map(fn {{from, to}, rs} ->
        %{
          from: from,
          to: to,
          usd: rs |> Enum.map(&Record.get(&1, "value_usd")) |> Enum.sum(),
          transfers: length(rs),
          tokens:
            rs
            |> Enum.map(&Record.get(&1, "token.symbol"))
            |> Enum.reject(&is_nil/1)
            |> Enum.uniq(),
          txs: rs |> Enum.map(& &1["tx_hash"]) |> Enum.uniq() |> Enum.take(5),
          from_label: node_label(hd(rs), "from"),
          to_label: node_label(hd(rs), "to")
        }
      end)
      |> Enum.sort_by(&(-&1.usd))

    {top, rest} = Enum.split(all, @top)
    watched = Enum.filter(rest, &(watched?(&1.from_label) or watched?(&1.to_label)))
    top ++ watched
  end

  defp node_label(r, role) do
    case Record.label(r, role) do
      nil -> nil
      l -> Map.take(l, ["name", "category", "protocol"])
    end
  end

  defp watched?(%{"category" => c}), do: c in @watch_categories
  defp watched?(_), do: false

  defp lower(nil), do: nil
  defp lower(s), do: String.downcase(s)
end
