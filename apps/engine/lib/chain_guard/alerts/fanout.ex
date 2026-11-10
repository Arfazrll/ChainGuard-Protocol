defmodule ChainGuard.Alerts.Connector do
  @moduledoc """
  An alert destination. `deliver/3` receives the lifecycle event
  (`:raised | :updated | :retracted | :finalized`), the alert, and the
  connector's own options. Return `:ok` or `{:error, reason}` (retried).
  """
  @callback deliver(event :: atom(), alert :: ChainGuard.Alerts.Alert.t(), opts :: keyword()) ::
              :ok | {:error, term()}
end

defmodule ChainGuard.Alerts.Fanout do
  @moduledoc """
  Delivers alert lifecycle events to the configured connectors, each in its
  own supervised task with exponential-backoff retries, so a slow or down
  destination never blocks detection.

      config :chain_guard, :connectors, [
        {ChainGuard.Alerts.Webhook, url: "...", secret: "...", min_severity: :medium},
        {ChainGuard.Alerts.PagerDuty, routing_key: "...", min_severity: :high}
      ]

  By default connectors receive `:raised` and `:retracted` (and never
  `:updated`, so dedup merges do not page anyone again). Override per
  connector with `events: [...]`.
  """

  require Logger
  alias ChainGuard.Rules.Rule

  @default_events [:raised, :retracted]

  @doc "Deliver to the global connectors, or to an explicit list (an org's routes)."
  def dispatch(event, alert, connectors \\ connectors()) do
    for {mod, opts} <- connectors, wants?(event, alert, opts) do
      Task.Supervisor.start_child(ChainGuard.TaskSupervisor, fn ->
        deliver(mod, event, alert, opts)
      end)
    end

    :ok
  end

  def connectors, do: Application.get_env(:chain_guard, :connectors, [])

  defp wants?(event, alert, opts) do
    min = Keyword.get(opts, :min_severity, :low)

    event in Keyword.get(opts, :events, @default_events) and
      Rule.severity_rank(alert.severity) >= Rule.severity_rank(min)
  end

  @doc false
  def deliver(mod, event, alert, opts, attempt \\ 1) do
    attempts = Keyword.get(opts, :attempts, 4)

    base =
      Keyword.get(opts, :backoff_ms, Application.get_env(:chain_guard, :fanout_backoff_ms, 500))

    result =
      try do
        mod.deliver(event, alert, opts)
      rescue
        e -> {:error, Exception.message(e)}
      end

    case result do
      :ok ->
        :telemetry.execute([:chain_guard, :connector, :delivered], %{count: 1}, %{connector: mod})
        :ok

      {:error, _reason} when attempt < attempts ->
        Process.sleep(base * Integer.pow(4, attempt - 1))
        deliver(mod, event, alert, opts, attempt + 1)

      {:error, reason} ->
        Logger.error(
          "#{inspect(mod)} gave up on alert #{alert.id} (#{event}) after #{attempt} attempts: #{inspect(reason)}"
        )

        :telemetry.execute([:chain_guard, :connector, :failed], %{count: 1}, %{connector: mod})
        {:error, reason}
    end
  end

  @doc "JSON payload shared by HTTP connectors."
  def payload(event, alert) do
    %{event: "alert.#{event}", alert: alert, delivered_at_ms: System.system_time(:millisecond)}
  end
end

defmodule ChainGuard.Alerts.Webhook do
  @moduledoc """
  Generic signed webhook. The body is JSON; the signature header is

      x-chainguard-signature: t=<unix seconds>,v1=<hex HMAC-SHA256(secret, "<t>.<body>")>

  Receivers recompute the HMAC over the raw body and reject stale timestamps,
  which prevents forgery and replay.
  """
  @behaviour ChainGuard.Alerts.Connector

  @impl true
  def deliver(event, alert, opts) do
    body = Jason.encode!(ChainGuard.Alerts.Fanout.payload(event, alert))
    ts = Integer.to_string(System.system_time(:second))

    headers = [
      {"content-type", "application/json"},
      {"user-agent", "chainguard-engine"},
      {"x-chainguard-event", "alert.#{event}"},
      {"x-chainguard-alert-id", alert.id},
      {"x-chainguard-signature", "t=#{ts},v1=#{sign(Keyword.fetch!(opts, :secret), ts, body)}"}
    ]

    req_opts = [
      url: Keyword.fetch!(opts, :url),
      body: body,
      headers: headers,
      retry: false,
      receive_timeout: 5_000
    ]

    case Req.post(Keyword.merge(req_opts, Keyword.take(opts, [:plug]))) do
      {:ok, %{status: s}} when s in 200..299 -> :ok
      {:ok, %{status: s}} -> {:error, {:http_status, s}}
      {:error, e} -> {:error, e}
    end
  end

  def sign(secret, ts, body),
    do: :crypto.mac(:hmac, :sha256, secret, ts <> "." <> body) |> Base.encode16(case: :lower)
end

defmodule ChainGuard.Alerts.PagerDuty do
  @moduledoc """
  PagerDuty Events API v2. A raised alert triggers an incident, and a
  retraction (reorg) resolves it, keyed by the alert id as `dedup_key`.
  """
  @behaviour ChainGuard.Alerts.Connector

  @url "https://events.pagerduty.com/v2/enqueue"

  @impl true
  def deliver(event, alert, opts) when event in [:raised, :retracted] do
    action = if event == :raised, do: "trigger", else: "resolve"

    body = %{
      routing_key: Keyword.fetch!(opts, :routing_key),
      event_action: action,
      dedup_key: alert.id,
      payload: %{
        summary: String.slice(alert.title, 0, 1024),
        severity: severity(alert.severity),
        source: "chainguard/chain-#{alert.chain_id}",
        component: alert.rule_id,
        class: alert.weakness[:class],
        custom_details: %{
          block_number: alert.block_number,
          tx_hashes: alert.tx_hashes,
          sources: alert.sources,
          status: alert.status,
          notes: alert.notes
        }
      }
    }

    req = [url: Keyword.get(opts, :url, @url), json: body, retry: false, receive_timeout: 5_000]

    case Req.post(Keyword.merge(req, Keyword.take(opts, [:plug]))) do
      {:ok, %{status: s}} when s in 200..299 -> :ok
      {:ok, %{status: s, body: b}} -> {:error, {:http_status, s, b}}
      {:error, e} -> {:error, e}
    end
  end

  def deliver(_event, _alert, _opts), do: :ok

  def severity(:critical), do: "critical"
  def severity(:high), do: "error"
  def severity(:medium), do: "warning"
  def severity(_), do: "info"
end

defmodule ChainGuard.Alerts.Telegram do
  @moduledoc "Telegram Bot API `sendMessage` (plain text, so no markup injection from on-chain names)."
  @behaviour ChainGuard.Alerts.Connector

  @impl true
  def deliver(event, alert, opts) when event in [:raised, :retracted, :finalized] do
    token = Keyword.fetch!(opts, :bot_token)
    base = Keyword.get(opts, :base_url, "https://api.telegram.org")

    req = [
      url: "#{base}/bot#{token}/sendMessage",
      json: %{
        chat_id: Keyword.fetch!(opts, :chat_id),
        text: text(event, alert),
        disable_web_page_preview: true
      },
      retry: false,
      receive_timeout: 5_000
    ]

    case Req.post(Keyword.merge(req, Keyword.take(opts, [:plug]))) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: s}} -> {:error, {:http_status, s}}
      {:error, e} -> {:error, e}
    end
  end

  def deliver(_event, _alert, _opts), do: :ok

  def text(:retracted, a), do: "RETRACTED (chain reorg) - #{a.title}\nalert #{a.id}"
  def text(:finalized, a), do: "FINAL - #{a.title}\nalert #{a.id}"

  def text(:raised, a) do
    lines = [
      "[#{a.severity |> to_string() |> String.upcase()}] #{a.title}",
      "rule: #{a.rule_id} · class: #{a.weakness[:class]}",
      if(a.block_number, do: "block #{a.block_number} · #{a.status}"),
      Enum.map_join(a.tx_hashes |> Enum.take(3), "\n", &"tx #{&1}"),
      "sources: #{Enum.join(a.sources, ", ")}"
      | a.notes
    ]

    lines |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("\n")
  end
end
