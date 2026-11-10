defmodule ChainGuard.Rules.Predicate do
  @moduledoc """
  The record-matching language used by rules.

  A predicate is a map of `path => matcher`; every entry must hold:

      kind: erc20_transfer                      # equality
      label.to.category: [mixer, bridge]        # membership
      value_usd: { gte: 1000000 }               # comparison
      label.spender: { exists: false }          # presence
      event.amount: { gte: "2^255" }            # big integers as strings

  Combinators: `all: [p, …]`, `any: [p, …]`, `not: p`.
  Operators: `eq ne in not_in gt gte lt lte exists`.

  Predicates compile once, at rule load time. Unknown paths and operators are
  rejected with a message, so a typo in a community rule fails loudly
  instead of silently never matching.
  """

  alias ChainGuard.Record

  @ops ~w(eq ne in not_in gt gte lt lte exists)
  @numeric_ops ~w(gt gte lt lte)

  @type t :: {:all, [t]} | {:any, [t]} | {:not, t} | {:cmp, [String.t()], String.t(), term()}

  @spec compile(term()) :: {:ok, t()} | {:error, String.t()}
  def compile(spec) do
    {:ok, do_compile(spec)}
  catch
    {:predicate_error, msg} -> {:error, msg}
  end

  defp fail(msg), do: throw({:predicate_error, msg})

  defp do_compile(%{"all" => list}) when is_list(list), do: {:all, Enum.map(list, &do_compile/1)}
  defp do_compile(%{"any" => list}) when is_list(list), do: {:any, Enum.map(list, &do_compile/1)}
  defp do_compile(%{"not" => p}), do: {:not, do_compile(p)}

  defp do_compile(map) when is_map(map) and map_size(map) > 0 do
    {:all, Enum.map(map, fn {path, matcher} -> compile_entry(to_string(path), matcher) end)}
  end

  defp do_compile(other), do: fail("a predicate must be a non-empty map, got: #{inspect(other)}")

  defp compile_entry(path, matcher) do
    segments = String.split(path, ".")

    unless hd(segments) in Record.roots() do
      fail("unknown field #{inspect(path)}; valid roots: #{Enum.join(Record.roots(), ", ")}")
    end

    case matcher do
      m when is_map(m) and map_size(m) == 1 ->
        [{op, value}] = Map.to_list(m)
        op = to_string(op)

        op in @ops ||
          fail("unknown operator #{inspect(op)} on #{path}; valid: #{Enum.join(@ops, ", ")}")

        {:cmp, segments, op, normalize(op, value, path)}

      m when is_map(m) ->
        fail("#{path}: give exactly one operator per field (use `all:` to combine)")

      list when is_list(list) ->
        {:cmp, segments, "in", Enum.map(list, &normalize_scalar/1)}

      scalar ->
        {:cmp, segments, "eq", normalize_scalar(scalar)}
    end
  end

  defp normalize(op, value, path) when op in @numeric_ops do
    case to_number(value) do
      nil -> fail("#{path}: #{op} needs a number, got #{inspect(value)}")
      n -> n
    end
  end

  defp normalize("exists", v, _) when is_boolean(v), do: v

  defp normalize("exists", v, path),
    do: fail("#{path}: exists takes true/false, got #{inspect(v)}")

  defp normalize(op, list, _) when op in ~w(in not_in) and is_list(list),
    do: Enum.map(list, &normalize_scalar/1)

  defp normalize(op, v, path) when op in ~w(in not_in),
    do: fail("#{path}: #{op} takes a list, got #{inspect(v)}")

  defp normalize(_, v, _), do: normalize_scalar(v)

  defp normalize_scalar(v) when is_binary(v), do: if(hex?(v), do: String.downcase(v), else: v)
  defp normalize_scalar(v), do: v

  defp hex?(<<"0x", _::binary>>), do: true
  defp hex?(_), do: false

  @doc """
  Numbers from rules and records: integers, floats, decimal strings (256-bit
  amounts arrive as strings), `"2^N"`, `"uint256_max"`, and `_` separators.
  """
  def to_number(n) when is_number(n), do: n
  def to_number("uint256_max"), do: Integer.pow(2, 256) - 1

  def to_number("2^" <> exp) do
    case Integer.parse(exp) do
      {e, ""} when e >= 0 and e <= 256 -> Integer.pow(2, e)
      _ -> nil
    end
  end

  def to_number(s) when is_binary(s) do
    s = String.replace(s, "_", "")

    case Integer.parse(s) do
      {i, ""} ->
        i

      _ ->
        case Float.parse(s) do
          {f, ""} -> f
          _ -> nil
        end
    end
  end

  def to_number(_), do: nil

  @spec matches?(t(), map()) :: boolean()
  def matches?({:all, ps}, r), do: Enum.all?(ps, &matches?(&1, r))
  def matches?({:any, ps}, r), do: Enum.any?(ps, &matches?(&1, r))
  def matches?({:not, p}, r), do: not matches?(p, r)

  def matches?({:cmp, path, "exists", want}, r), do: not is_nil(Record.get(r, path)) == want

  def matches?({:cmp, path, op, want}, r) do
    case Record.get(r, path) do
      nil -> op in ~w(ne not_in)
      actual -> compare(op, normalize_scalar(actual), want)
    end
  end

  defp compare("eq", a, b), do: a == b
  defp compare("ne", a, b), do: a != b
  defp compare("in", a, list), do: a in list
  defp compare("not_in", a, list), do: a not in list

  defp compare(op, a, b) do
    case to_number(a) do
      nil -> false
      n -> num(op, n, b)
    end
  end

  defp num("gt", a, b), do: a > b
  defp num("gte", a, b), do: a >= b
  defp num("lt", a, b), do: a < b
  defp num("lte", a, b), do: a <= b
end
