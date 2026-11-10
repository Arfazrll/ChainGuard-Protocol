defmodule ChainGuard.Rules.Rule do
  @moduledoc """
  A detection rule: pure data, loaded from YAML (see `priv/rules/`).

  Three scopes:

    * `record`: one alert per matching record.
    * `tx`: correlates all records of one transaction. Every entry in
      `require` must be satisfied, either by matching records (`match`,
      `min_count`, `sum_value_usd`) or by a net USD outflow from a labeled
      party (`net_outflow`).
    * `window`: counts *distinct* values of `distinct` per `group_by`
      across the last `within_blocks` blocks, firing at `threshold`.
      `novel_group: true` only counts groups first seen after a warm-up.

  See `docs/rules.md` for the full format.
  """

  alias ChainGuard.Rules.Predicate

  @severities ~w(info low medium high critical)a
  @scopes ~w(record tx window)

  defstruct [
    :id,
    :version,
    :name,
    :description,
    :severity,
    :weakness,
    :scope,
    :match,
    :require,
    :evidence,
    :group_by,
    :distinct,
    :threshold,
    :within_blocks,
    :novel_group,
    :warmup_blocks,
    :title,
    :dedup_key,
    :dedup_window_s,
    :rate_per_minute,
    :source,
    enabled: true
  ]

  @type severity :: :info | :low | :medium | :high | :critical
  @type t :: %__MODULE__{}

  def severities, do: @severities

  def severity_rank(s), do: Enum.find_index(@severities, &(&1 == s))

  @spec from_yaml(String.t(), String.t()) :: {:ok, t()} | {:error, String.t()}
  def from_yaml(yaml, source \\ "inline") do
    case YamlElixir.read_from_string(yaml) do
      {:ok, map} when is_map(map) -> from_map(map, source)
      {:ok, other} -> {:error, "#{source}: expected a YAML mapping, got #{inspect(other)}"}
      {:error, e} -> {:error, "#{source}: invalid YAML: #{Exception.message(e)}"}
    end
  end

  @spec from_map(map(), String.t()) :: {:ok, t()} | {:error, String.t()}
  def from_map(m, source \\ "inline") do
    {:ok, build(m, source)}
  catch
    {:rule_error, msg} -> {:error, "#{source}: #{msg}"}
  end

  defp fail(msg), do: throw({:rule_error, msg})

  defp build(m, source) do
    id = req_string(m, "id")

    Regex.match?(~r/^[a-z0-9][a-z0-9-]{2,63}$/, id) ||
      fail("id #{inspect(id)} must be kebab-case")

    scope = req_string(m, "scope")
    scope in @scopes || fail("scope must be one of #{Enum.join(@scopes, ", ")}")

    base = %__MODULE__{
      id: id,
      version: Map.get(m, "version", 1),
      name: req_string(m, "name"),
      description: Map.get(m, "description", ""),
      severity: severity(Map.get(m, "severity")),
      weakness: weakness(Map.get(m, "weakness")),
      scope: String.to_atom(scope),
      title: req_string(m, "title"),
      dedup_key: get_in(m, ["dedup", "key"]) || default_dedup(scope),
      dedup_window_s: get_in(m, ["dedup", "window_seconds"]) || 3600,
      rate_per_minute: get_in(m, ["rate_limit", "per_minute"]) || 10,
      enabled: Map.get(m, "enabled", true),
      source: source
    }

    scoped(base, m)
  end

  defp default_dedup("record"), do: "{{tx_hash}}:{{log_index}}"
  defp default_dedup("tx"), do: "{{tx_hash}}"
  defp default_dedup("window"), do: "{{group}}"

  defp scoped(%{scope: :record} = r, m), do: %{r | match: pred(m, "match")}

  defp scoped(%{scope: :window} = r, m) do
    %{
      r
      | match: pred(m, "match"),
        group_by: req_string(m, "group_by"),
        distinct: req_string(m, "distinct"),
        threshold: pos_int(m, "threshold"),
        within_blocks: pos_int(m, "within_blocks"),
        novel_group: Map.get(m, "novel_group", false),
        warmup_blocks: Map.get(m, "warmup_blocks", 0)
    }
  end

  defp scoped(%{scope: :tx} = r, m) do
    reqs = Map.get(m, "require")
    (is_list(reqs) and reqs != []) || fail("tx scope needs a non-empty `require` list")
    reqs = Enum.map(reqs, &requirement/1)
    names = Enum.map(reqs, & &1.name)
    length(Enum.uniq(names)) == length(names) || fail("requirement names must be unique")
    evidence = Map.get(m, "evidence", names)
    Enum.all?(evidence, &(&1 in names)) || fail("evidence lists an unknown requirement")
    %{r | require: reqs, evidence: evidence}
  end

  defp requirement(%{"name" => name} = q) when is_binary(name) do
    case q do
      %{"net_outflow" => no} ->
        party =
          case Map.get(no, "party_category") do
            l when is_list(l) and l != [] -> Enum.map(l, &to_string/1)
            _ -> fail("#{name}: net_outflow needs a party_category list")
          end

        gte =
          Predicate.to_number(Map.get(no, "gte_usd")) ||
            fail("#{name}: net_outflow needs gte_usd")

        %{name: name, type: :net_outflow, party_category: party, gte_usd: gte}

      %{"match" => _} ->
        sum =
          case get_in(q, ["sum_value_usd", "gte"]) do
            nil -> nil
            v -> Predicate.to_number(v) || fail("#{name}: sum_value_usd.gte must be a number")
          end

        %{
          name: name,
          type: :match,
          match: pred(q, "match"),
          min_count: Map.get(q, "min_count", 1),
          sum_gte: sum
        }

      _ ->
        fail("requirement #{name} needs `match` or `net_outflow`")
    end
  end

  defp requirement(q), do: fail("each requirement needs a name: #{inspect(q)}")

  defp pred(m, key) do
    case Map.fetch(m, key) do
      {:ok, spec} ->
        case Predicate.compile(spec) do
          {:ok, p} -> p
          {:error, msg} -> fail("#{key}: #{msg}")
        end

      :error ->
        fail("missing `#{key}`")
    end
  end

  defp req_string(m, k) do
    case Map.get(m, k) do
      v when is_binary(v) and v != "" -> v
      _ -> fail("missing or empty `#{k}`")
    end
  end

  defp pos_int(m, k) do
    case Map.get(m, k) do
      v when is_integer(v) and v > 0 -> v
      _ -> fail("`#{k}` must be a positive integer")
    end
  end

  defp severity(s) when is_binary(s) do
    Enum.find(@severities, &(Atom.to_string(&1) == s)) ||
      fail("severity must be one of #{Enum.join(@severities, ", ")}")
  end

  defp severity(_), do: fail("missing severity")

  defp weakness(%{"class" => class} = w) when is_binary(class),
    do: %{class: class, refs: List.wrap(Map.get(w, "refs", []))}

  defp weakness(_), do: fail("missing `weakness.class` (every alert maps to a weakness class)")

  @doc "Public, JSON-friendly description of a rule."
  def describe(%__MODULE__{} = r) do
    %{
      id: r.id,
      version: r.version,
      name: r.name,
      description: r.description,
      severity: r.severity,
      scope: r.scope,
      weakness: r.weakness,
      enabled: r.enabled,
      source: Path.basename(r.source)
    }
  end
end
