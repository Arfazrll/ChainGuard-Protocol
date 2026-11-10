defmodule ChainGuard.Invariants.Invariant do
  @moduledoc """
  A per-protocol invariant: a property that must always hold, loaded from
  YAML (`priv/invariants/`). Three kinds:

    * `peg`: a stablecoin's Chainlink price stays within bands around its
      peg. Each band maps a deviation to a severity; an alert fires when the
      price enters a wider band than it was in before.
    * `oracle`: one oracle update never moves the answer more than
      `max_jump`, and the feed is never older than `max_age_seconds` at
      block time.
    * `outflow`: the net USD outflow from a protocol's labeled contracts over
      the last `within_blocks` blocks stays below `max_net_outflow_usd`. This
      is a TVL drawdown measured from priced transfers; it does not read
      balances, so unpriced tokens do not count.

  See `docs/invariants.md`.
  """

  alias ChainGuard.Rules.{Predicate, Rule}

  @kinds ~w(peg oracle outflow)

  defstruct [
    :id,
    :version,
    :kind,
    :name,
    :description,
    :protocol,
    :weakness,
    :chain_id,
    :params,
    :dedup_window_s,
    :rate_per_minute,
    :source,
    enabled: true
  ]

  @type t :: %__MODULE__{}

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
    {:invariant_error, msg} -> {:error, "#{source}: #{msg}"}
  end

  defp fail(msg), do: throw({:invariant_error, msg})

  @common ~w(id version kind name description protocol weakness chain_id dedup rate_limit enabled)

  defp build(m, source) do
    id = str(m, "id")

    Regex.match?(~r/^[a-z0-9][a-z0-9-]{2,63}$/, id) ||
      fail("id #{inspect(id)} must be kebab-case")

    kind = str(m, "kind")
    kind in @kinds || fail("kind must be one of #{Enum.join(@kinds, ", ")}")

    %__MODULE__{
      id: id,
      version: Map.get(m, "version", 1),
      kind: String.to_atom(kind),
      name: str(m, "name"),
      description: Map.get(m, "description", ""),
      protocol: str(m, "protocol"),
      weakness: weakness(Map.get(m, "weakness")),
      chain_id: Map.get(m, "chain_id", 1),
      params: params(kind, Map.drop(m, @common)),
      dedup_window_s: get_in(m, ["dedup", "window_seconds"]) || 6 * 3600,
      rate_per_minute: get_in(m, ["rate_limit", "per_minute"]) || 2,
      enabled: Map.get(m, "enabled", true),
      source: source
    }
  end

  defp params("peg", m) do
    only(m, ~w(feed peg_usd bands))
    bands = Map.get(m, "bands")
    (is_list(bands) and bands != []) || fail("peg needs a non-empty `bands` list")

    bands =
      bands
      |> Enum.map(fn b ->
        %{
          deviation: num(b, "deviation", "bands[].deviation"),
          severity: severity(Map.get(b, "severity"))
        }
      end)
      |> Enum.sort_by(& &1.deviation)

    Enum.all?(bands, &(&1.deviation > 0 and &1.deviation < 1)) ||
      fail("band deviations must be between 0 and 1 (0.02 = 2%)")

    %{feed: feed(m), peg_usd: num(m, "peg_usd", "peg_usd"), bands: bands}
  end

  defp params("oracle", m) do
    only(m, ~w(feed max_jump jump_severity max_age_seconds stale_severity))
    jump = num(m, "max_jump", "max_jump")
    (jump > 0 and jump < 10) || fail("max_jump must be a fraction, e.g. 0.1 for 10%")

    %{
      feed: feed(m),
      max_jump: jump,
      jump_severity: severity(Map.get(m, "jump_severity", "high")),
      max_age_s: pos_int(m, "max_age_seconds"),
      stale_severity: severity(Map.get(m, "stale_severity", "medium"))
    }
  end

  defp params("outflow", m) do
    only(m, ~w(within_blocks max_net_outflow_usd severity reference_tvl_usd))

    %{
      within_blocks: pos_int(m, "within_blocks"),
      max_net_outflow_usd: num(m, "max_net_outflow_usd", "max_net_outflow_usd"),
      severity: severity(Map.get(m, "severity")),
      reference_tvl_usd:
        case Map.get(m, "reference_tvl_usd") do
          nil -> nil
          v -> Predicate.to_number(v) || fail("reference_tvl_usd must be a number")
        end
    }
  end

  defp only(m, allowed) do
    case Map.keys(m) -- allowed do
      [] -> :ok
      extra -> fail("unknown field(s) #{Enum.join(extra, ", ")}")
    end
  end

  defp feed(m) do
    f = Map.get(m, "feed") || fail("missing `feed`")
    aggs = Map.get(f, "aggregators")

    (is_list(aggs) and aggs != [] and Enum.all?(aggs, &address?/1)) ||
      fail("feed.aggregators must be a non-empty list of 0x addresses")

    %{
      name: str(f, "name"),
      aggregators: MapSet.new(aggs, &String.downcase/1),
      decimals: pos_int(f, "decimals")
    }
  end

  defp address?(a), do: is_binary(a) and Regex.match?(~r/^0x[0-9a-fA-F]{40}$/, a)

  defp str(m, k) do
    case Map.get(m, k) do
      v when is_binary(v) and v != "" -> v
      _ -> fail("missing or empty `#{k}`")
    end
  end

  defp num(m, k, label) do
    case Predicate.to_number(Map.get(m, k)) do
      n when is_number(n) -> n
      _ -> fail("`#{label}` must be a number")
    end
  end

  defp pos_int(m, k) do
    case Map.get(m, k) do
      v when is_integer(v) and v > 0 -> v
      _ -> fail("`#{k}` must be a positive integer")
    end
  end

  defp severity(s) when is_binary(s) do
    Enum.find(Rule.severities(), &(Atom.to_string(&1) == s)) ||
      fail("severity must be one of #{Enum.join(Rule.severities(), ", ")}")
  end

  defp severity(_), do: fail("missing severity")

  defp weakness(%{"class" => class} = w) when is_binary(class),
    do: %{class: class, refs: List.wrap(Map.get(w, "refs", []))}

  defp weakness(_), do: fail("missing `weakness.class` (every alert maps to a weakness class)")

  @doc "The rule-shaped view the alert manager needs (dedup, rate limit, severity)."
  def as_rule(%__MODULE__{} = inv, severity) do
    %Rule{
      id: inv.id,
      version: inv.version,
      name: inv.name,
      description: inv.description,
      severity: severity,
      weakness: inv.weakness,
      scope: :invariant,
      dedup_window_s: inv.dedup_window_s,
      rate_per_minute: inv.rate_per_minute,
      source: inv.source
    }
  end

  def describe(%__MODULE__{} = inv) do
    %{
      id: inv.id,
      version: inv.version,
      kind: inv.kind,
      name: inv.name,
      description: inv.description,
      protocol: inv.protocol,
      weakness: inv.weakness,
      chain_id: inv.chain_id,
      enabled: inv.enabled,
      source: Path.basename(inv.source)
    }
  end
end
