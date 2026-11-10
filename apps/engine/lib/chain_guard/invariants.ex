defmodule ChainGuard.Invariants do
  @moduledoc """
  The invariant lane of the detection engine: per-protocol properties that
  must always hold (a stablecoin's peg, an oracle's sanity, a protocol's net
  outflow).

  One supervised `ChainGuard.Invariants.Monitor` per invariant. A monitor
  that crashes restarts alone with fresh state; the others keep running.
  """

  require Logger
  alias ChainGuard.Invariants.{Invariant, Monitor}

  @registry ChainGuard.Invariants.Registry

  @spec load_dir(Path.t()) :: {[Invariant.t()], [String.t()]}
  def load_dir(dir) do
    files = Path.wildcard(Path.join(dir, "*.{yaml,yml}")) |> Enum.sort()

    {invs, errors} =
      Enum.reduce(files, {[], []}, fn f, {ok, err} ->
        with {:ok, yaml} <- File.read(f),
             {:ok, inv} <- Invariant.from_yaml(yaml, f) do
          {[inv | ok], err}
        else
          {:error, msg} when is_binary(msg) -> {ok, [msg | err]}
          {:error, reason} -> {ok, ["#{f}: #{:file.format_error(reason)}" | err]}
        end
      end)

    invs = Enum.reverse(invs)
    dupes = invs |> Enum.frequencies_by(& &1.id) |> Enum.filter(fn {_, n} -> n > 1 end)

    errors =
      Enum.reverse(errors) ++ Enum.map(dupes, fn {id, _} -> "duplicate invariant id #{id}" end)

    {Enum.uniq_by(invs, & &1.id), errors}
  end

  def dir do
    Application.get_env(:chain_guard, :invariants_dir) ||
      Application.app_dir(:chain_guard, "priv/invariants")
  end

  def load_errors, do: :persistent_term.get({__MODULE__, :errors}, [])

  def list do
    monitors() |> Enum.map(fn {_pid, inv} -> inv end) |> Enum.sort_by(& &1.id)
  end

  @doc "Current status of every monitor (value, limit, ok / breached / warming up)."
  def statuses do
    monitors()
    |> Enum.flat_map(fn {pid, _} ->
      try do
        [Monitor.status(pid)]
      catch
        :exit, _ -> []
      end
    end)
    |> Enum.sort_by(& &1.id)
  end

  @doc "Evaluate one completed block against every monitor, concurrently."
  @spec evaluate_block(map()) :: [map()]
  def evaluate_block(ctx) do
    monitors()
    |> Task.async_stream(
      fn {pid, inv} ->
        try do
          {:ok, Monitor.evaluate(pid, ctx)}
        catch
          :exit, reason -> {:error, inv.id, reason}
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
        Logger.error("invariant #{id} failed on block #{ctx.block["number"]}: #{inspect(reason)}")
        :telemetry.execute([:chain_guard, :invariant, :error], %{count: 1}, %{invariant: id})
        []

      {:exit, reason} ->
        Logger.error("invariant evaluation timed out: #{inspect(reason)}")
        []
    end)
  end

  @doc "A reorg orphaned this block: every monitor rolls back to before it."
  def orphan_block(chain_id, block_hash) do
    for {pid, _} <- monitors(), do: Monitor.orphan(pid, chain_id, block_hash)
    :ok
  end

  @doc false
  def reset do
    for {pid, _} <- monitors(), do: Monitor.reset(pid)
    :ok
  end

  defp monitors,
    do: Registry.select(@registry, [{{:_, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}])
end

defmodule ChainGuard.Invariants.Monitor do
  @moduledoc """
  One supervised process per invariant.

  Reorg safety lives here, once, for every kind of invariant: before a block
  is evaluated, the state is snapshotted under that block's hash. When a
  block is orphaned, the monitor restores the snapshot taken before it and
  drops every later one (they were built on the orphaned block). Alerts
  raised on the orphaned block are retracted by the alert manager.
  """
  use GenServer

  alias ChainGuard.Invariants.Check

  # Deeper than the deepest reorg ingestion handles automatically (64).
  @history 128

  def start_link(inv), do: GenServer.start_link(__MODULE__, inv)

  def child_spec(inv), do: %{id: {__MODULE__, inv.id}, start: {__MODULE__, :start_link, [inv]}}

  def evaluate(pid, ctx), do: GenServer.call(pid, {:evaluate, ctx}, 10_000)
  def orphan(pid, chain_id, hash), do: GenServer.call(pid, {:orphan, chain_id, hash}, 10_000)
  def status(pid), do: GenServer.call(pid, :status, 2_000)
  def reset(pid), do: GenServer.call(pid, :reset)

  @impl true
  def init(inv) do
    {:ok, _} = Registry.register(ChainGuard.Invariants.Registry, inv.id, inv)
    {:ok, %{inv: inv, state: Check.init(inv), history: []}}
  end

  @impl true
  def handle_call({:evaluate, %{chain_id: c} = ctx}, _from, %{inv: %{chain_id: c}} = s) do
    snapshot = {ctx.block["hash"], s.state}
    {candidates, st} = Check.evaluate(s.inv, s.state, ctx)
    {:reply, candidates, %{s | state: st, history: Enum.take([snapshot | s.history], @history)}}
  end

  def handle_call({:evaluate, _ctx}, _from, s), do: {:reply, [], s}

  def handle_call({:orphan, c, hash}, _from, %{inv: %{chain_id: c}} = s) do
    case Enum.split_while(s.history, fn {h, _} -> h != hash end) do
      {_newer, [{^hash, before} | older]} ->
        {:reply, :rolled_back, %{s | state: before, history: older}}

      _ ->
        {:reply, :unknown_block, s}
    end
  end

  def handle_call({:orphan, _, _}, _from, s), do: {:reply, :other_chain, s}

  def handle_call(:status, _from, s), do: {:reply, Check.status(s.inv, s.state), s}

  def handle_call(:reset, _from, s),
    do: {:reply, :ok, %{s | state: Check.init(s.inv), history: []}}
end

defmodule ChainGuard.Invariants.Supervisor do
  @moduledoc false
  use Supervisor
  require Logger

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    dir = Keyword.get(opts, :dir, ChainGuard.Invariants.dir())
    {invs, errors} = ChainGuard.Invariants.load_dir(dir)
    :persistent_term.put({ChainGuard.Invariants, :errors}, errors)
    Enum.each(errors, &Logger.error("invariant not loaded: #{&1}"))
    Logger.info("loaded #{length(invs)} invariants from #{dir}")

    Supervisor.init(Enum.map(invs, &ChainGuard.Invariants.Monitor.child_spec/1),
      strategy: :one_for_one
    )
  end
end
