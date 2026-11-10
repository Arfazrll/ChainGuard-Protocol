defmodule ChainGuard.Ingest.Pipeline do
  @moduledoc """
  Broadway pipeline consuming `chainguard-ingestd`'s stream.

  Sources (`config :chain_guard, :source`):

    * `{:kafka, hosts: ..., topics: [...], group_id: ...}`: Redpanda/Kafka
      via BroadwayKafka (production)
    * `{:jsonl, path: ..., mode: :replay | :tail}`: ingestd's JSONL output
      (incident replay, local demo)

  Ordering: messages are partitioned by the Kafka key (the chain id) onto
  processors, so one chain's messages are handled strictly in order. That
  matters: a retraction must never overtake the upsert it retracts.

  Per-message retry: a dispatch that fails is retried with backoff before the
  message is marked failed (counted, logged, kept in the dead-letter ring).
  """

  use Broadway
  require Logger

  alias Broadway.Message
  alias ChainGuard.{Chain, Stats}

  @retries 3

  def start_link(opts) do
    {producer, producer_opts} = producer(Keyword.fetch!(opts, :source))

    Broadway.start_link(__MODULE__,
      name: Keyword.get(opts, :name, __MODULE__),
      producer: [module: {producer, producer_opts}, concurrency: 1],
      processors: [
        default: [concurrency: Keyword.get(opts, :processors, 4), partition_by: &partition/1]
      ]
    )
  end

  defp producer({:kafka, opts}) do
    {BroadwayKafka.Producer,
     [
       hosts: Keyword.fetch!(opts, :hosts),
       group_id: Keyword.get(opts, :group_id, "chainguard-engine"),
       topics: Keyword.fetch!(opts, :topics),
       offset_reset_policy: Keyword.get(opts, :offset_reset_policy, :earliest)
     ]}
  end

  defp producer({:jsonl, opts}), do: {ChainGuard.Ingest.JsonlProducer, opts}
  defp producer({:dummy, opts}), do: {Broadway.DummyProducer, opts}

  # BroadwayKafka exposes the record key as metadata; ingestd keys by chain id.
  defp partition(%Message{metadata: %{key: key}}) when is_binary(key), do: :erlang.phash2(key)
  defp partition(_), do: 0

  @impl true
  def handle_message(_processor, %Message{data: data} = msg, _ctx) do
    with {:ok, decoded} <- decode(data),
         :ok <- validate(decoded),
         :ok <- dispatch(decoded, 1) do
      msg
    else
      {:error, reason} -> Message.failed(msg, reason)
    end
  end

  @impl true
  def handle_failed(messages, _ctx) do
    Stats.incr(:failed_messages, length(messages))

    for m <- messages do
      Logger.error("stream message failed: #{inspect(m.status)}")
      ChainGuard.Ingest.DeadLetter.put(m.data, m.status)
    end

    messages
  end

  defp decode(map) when is_map(map), do: {:ok, map}

  defp decode(bin) when is_binary(bin) do
    case Jason.decode(bin) do
      {:ok, m} when is_map(m) -> {:ok, m}
      {:ok, _} -> {:error, :not_an_object}
      {:error, e} -> {:error, {:invalid_json, Exception.message(e)}}
    end
  end

  defp validate(%{"type" => t, "seq" => s, "chain_id" => c})
       when is_binary(t) and is_integer(s) and is_integer(c), do: :ok

  defp validate(_), do: {:error, :missing_envelope_fields}

  defp dispatch(msg, attempt) do
    Chain.handle(msg)
    :ok
  catch
    kind, reason when attempt < @retries ->
      Logger.warning("dispatch failed (attempt #{attempt}): #{inspect({kind, reason})}")
      Process.sleep(100 * Integer.pow(4, attempt - 1))
      dispatch(msg, attempt + 1)

    kind, reason ->
      {:error, {:dispatch_failed, kind, reason}}
  end
end

defmodule ChainGuard.Ingest.DeadLetter do
  @moduledoc "Bounded in-memory ring of messages that failed after retries."
  use Agent

  @max 500

  def start_link(_), do: Agent.start_link(fn -> [] end, name: __MODULE__)

  def put(data, status),
    do: Agent.update(__MODULE__, &Enum.take([%{data: data, status: inspect(status)} | &1], @max))

  def list, do: Agent.get(__MODULE__, & &1)
end

defmodule ChainGuard.Ingest.JsonlProducer do
  @moduledoc """
  GenStage producer over ingestd's JSONL output.

    * `mode: :replay`: emit the whole file, then go idle
    * `mode: :tail`: emit, then keep following the file as ingestd appends
      (complete lines only; a partially written line waits for its newline)

  `from: :end` skips existing content when tailing (live only).
  """

  use GenStage
  @behaviour Broadway.Producer

  @poll_ms 250

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    mode = Keyword.get(opts, :mode, :replay)
    {:ok, dev} = File.open(path, [:read, :binary])

    if Keyword.get(opts, :from) == :end do
      {:ok, _} = :file.position(dev, :eof)
    end

    {:producer, %{dev: dev, mode: mode, partial: "", demand: 0, done: false}}
  end

  @impl true
  def handle_demand(n, s), do: emit(%{s | demand: s.demand + n})

  @impl true
  def handle_info(:poll, s), do: emit(s)

  defp emit(%{demand: 0} = s), do: {:noreply, [], s}

  defp emit(s) do
    {lines, s} = read(s, s.demand, [])
    s = %{s | demand: s.demand - length(lines)}

    cond do
      s.demand > 0 and s.mode == :tail -> Process.send_after(self(), :poll, @poll_ms)
      true -> :ok
    end

    {:noreply, Enum.map(lines, &message/1), s}
  end

  defp read(s, 0, acc), do: {Enum.reverse(acc), s}

  defp read(s, n, acc) do
    case IO.binread(s.dev, :line) do
      :eof ->
        {Enum.reverse(acc), s}

      {:error, _} ->
        {Enum.reverse(acc), s}

      chunk ->
        line = s.partial <> chunk

        if String.ends_with?(line, "\n") do
          case String.trim(line) do
            "" -> read(%{s | partial: ""}, n, acc)
            l -> read(%{s | partial: ""}, n - 1, [l | acc])
          end
        else
          # Incomplete line at EOF: keep it until the writer finishes it.
          {Enum.reverse(acc), %{s | partial: line}}
        end
    end
  end

  defp message(line) do
    key =
      case Regex.run(~r/"chain_id":(\d+)/, line) do
        [_, id] -> id
        _ -> "0"
      end

    %Broadway.Message{
      data: line,
      metadata: %{key: key},
      acknowledger: Broadway.NoopAcknowledger.init()
    }
  end
end
