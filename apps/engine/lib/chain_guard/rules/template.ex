defmodule ChainGuard.Rules.Template do
  @moduledoc """
  `{{path}}` / `{{path|filter}}` substitution for alert titles and dedup keys.

  Filters: `usd` (`$8,904,507`), `short` (`0x2718…25d3`). Unknown values
  render as `?`, so a template never crashes alerting.
  """

  @re ~r/\{\{\s*([a-zA-Z0-9_.]+)\s*(?:\|\s*([a-z]+)\s*)?\}\}/

  @spec render(String.t() | nil, (String.t() -> term())) :: String.t()
  def render(nil, _), do: ""

  def render(template, lookup) do
    Regex.replace(@re, template, fn _, path, filter ->
      path |> lookup.() |> apply_filter(filter)
    end)
  end

  defp apply_filter(nil, _), do: "?"
  defp apply_filter(v, "usd"), do: usd(v)
  defp apply_filter(v, "short"), do: short(v)
  defp apply_filter(v, _), do: to_s(v)

  def usd(v) do
    case ChainGuard.Rules.Predicate.to_number(v) do
      nil -> "?"
      n -> "$" <> group(round(n))
    end
  end

  defp group(n) when n < 0, do: "-" <> group(-n)

  defp group(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.to_charlist()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  def short(<<"0x", _::binary>> = hex) when byte_size(hex) > 14,
    do: String.slice(hex, 0, 6) <> "…" <> String.slice(hex, -4, 4)

  def short(v), do: to_s(v)

  defp to_s(v) when is_binary(v), do: v
  defp to_s(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 2)
  defp to_s(v), do: to_string(v)
end
