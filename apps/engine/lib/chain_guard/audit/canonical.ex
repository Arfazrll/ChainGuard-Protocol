defmodule ChainGuard.Audit.Canonical do
  @moduledoc """
  Canonical JSON: object keys sorted, no insignificant whitespace, atoms as
  strings, timestamps as ISO 8601. The same data always encodes to the same
  bytes, which is what makes the hash chain re-derivable.
  """

  def encode(term), do: term |> normalize() |> Jason.encode!()

  def normalize(%DateTime{} = d), do: DateTime.to_iso8601(d)
  def normalize(%NaiveDateTime{} = d), do: NaiveDateTime.to_iso8601(d)
  def normalize(%MapSet{} = s), do: s |> MapSet.to_list() |> Enum.map(&normalize/1) |> Enum.sort()

  def normalize(%_{} = struct), do: struct |> Map.from_struct() |> normalize()

  def normalize(m) when is_map(m) do
    m
    |> Enum.map(fn {k, v} -> {key(k), normalize(v)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  def normalize(l) when is_list(l), do: Enum.map(l, &normalize/1)
  def normalize(t) when is_tuple(t), do: t |> Tuple.to_list() |> normalize()
  def normalize(a) when is_atom(a) and a not in [nil, true, false], do: Atom.to_string(a)
  def normalize(v), do: v

  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k) when is_binary(k), do: k
  defp key(k), do: to_string(k)
end
