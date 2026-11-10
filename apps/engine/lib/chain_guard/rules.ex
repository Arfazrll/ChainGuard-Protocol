defmodule ChainGuard.Rules do
  @moduledoc """
  The rule lane of the detection engine.

  Each loaded rule runs in its own supervised `ChainGuard.Rules.Worker`. A
  rule that crashes (bad data, a bug in a community rule) is restarted on its
  own, its window state is reset, and every other rule keeps running.
  """

  require Logger
  alias ChainGuard.Rules.{Rule, Worker}

  @registry ChainGuard.Rules.Registry

  @doc "Load and validate every `*.yaml` / `*.yml` rule in `dir`."
  @spec load_dir(Path.t()) :: {[Rule.t()], [String.t()]}
  def load_dir(dir) do
    files = Path.wildcard(Path.join(dir, "*.{yaml,yml}")) |> Enum.sort()

    {rules, errors} =
      Enum.reduce(files, {[], []}, fn f, {ok, err} ->
        case File.read(f) do
          {:ok, yaml} ->
            case Rule.from_yaml(yaml, f) do
              {:ok, rule} -> {[rule | ok], err}
              {:error, msg} -> {ok, [msg | err]}
            end

          {:error, reason} ->
            {ok, ["#{f}: #{:file.format_error(reason)}" | err]}
        end
      end)

    rules = Enum.reverse(rules)
    dupes = rules |> Enum.frequencies_by(& &1.id) |> Enum.filter(fn {_, n} -> n > 1 end)
    errors = Enum.reverse(errors) ++ Enum.map(dupes, fn {id, _} -> "duplicate rule id #{id}" end)
    rules = Enum.uniq_by(rules, & &1.id)
    {rules, errors}
  end

  def rules_dir do
    Application.get_env(:chain_guard, :rules_dir) ||
      Application.app_dir(:chain_guard, "priv/rules")
  end

  @doc "All running rules."
  def list do
    @registry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.map(fn {_id, _pid, rule} -> rule end)
    |> Enum.sort_by(& &1.id)
  end

  def load_errors, do: :persistent_term.get({__MODULE__, :errors}, [])

  @doc """
  Evaluate one completed block against every rule, concurrently. A rule that
  crashes or times out is logged and skipped for this block.
  """
  @spec evaluate_block(map()) :: [map()]
  def evaluate_block(ctx) do
    @registry
    |> Registry.select([{{:_, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}])
    |> Task.async_stream(
      fn {pid, rule} ->
        try do
          {:ok, Worker.evaluate(pid, ctx)}
        catch
          :exit, reason -> {:error, rule.id, reason}
        end
      end,
      ordered: false,
      timeout: 15_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, {:ok, candidates}} ->
        candidates

      {:ok, {:error, id, reason}} ->
        Logger.error("rule #{id} failed on block #{ctx.block["number"]}: #{inspect(reason)}")
        :telemetry.execute([:chain_guard, :rule, :error], %{count: 1}, %{rule: id})
        []

      {:exit, reason} ->
        Logger.error("rule evaluation timed out: #{inspect(reason)}")
        []
    end)
  end

  @doc "A reorg orphaned this block; drop its contributions from rule state."
  def orphan_block(chain_id, block_hash) do
    for {pid, _} <- Registry.select(@registry, [{{:_, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}]) do
      Worker.orphan(pid, chain_id, block_hash)
    end

    :ok
  end
end

defmodule ChainGuard.Rules.Worker do
  @moduledoc "One supervised process per rule, holding that rule's window state."
  use GenServer

  alias ChainGuard.Rules.Evaluator

  def start_link(rule), do: GenServer.start_link(__MODULE__, rule)

  def child_spec(rule), do: %{id: {__MODULE__, rule.id}, start: {__MODULE__, :start_link, [rule]}}

  def evaluate(pid, ctx), do: GenServer.call(pid, {:evaluate, ctx}, 10_000)
  def orphan(pid, chain_id, block_hash), do: GenServer.cast(pid, {:orphan, chain_id, block_hash})

  @impl true
  def init(rule) do
    {:ok, _} = Registry.register(ChainGuard.Rules.Registry, rule.id, rule)
    {:ok, %{rule: rule, state: Evaluator.initial_state()}}
  end

  @impl true
  def handle_call({:evaluate, ctx}, _from, %{rule: rule, state: st} = s) do
    {candidates, st} = Evaluator.evaluate(rule, st, ctx)
    {:reply, candidates, %{s | state: st}}
  end

  @impl true
  def handle_cast({:orphan, chain_id, hash}, %{rule: rule, state: st} = s) do
    {:noreply, %{s | state: Evaluator.orphan(rule, st, {chain_id, hash})}}
  end
end

defmodule ChainGuard.Rules.Supervisor do
  @moduledoc false
  use Supervisor
  require Logger

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    dir = Keyword.get(opts, :dir, ChainGuard.Rules.rules_dir())
    {rules, errors} = ChainGuard.Rules.load_dir(dir)
    :persistent_term.put({ChainGuard.Rules, :errors}, errors)
    Enum.each(errors, &Logger.error("rule not loaded: #{&1}"))
    Logger.info("loaded #{length(rules)} rules from #{dir}")

    Supervisor.init(Enum.map(rules, &ChainGuard.Rules.Worker.child_spec/1),
      strategy: :one_for_one
    )
  end
end
