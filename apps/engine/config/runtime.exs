import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/chain_guard start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :chain_guard, ChainGuardWeb.Endpoint, server: true
end

config :chain_guard, ChainGuardWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# --- ChainGuard detection engine ----------------------------------------------
if config_env() != :test do
  source =
    case System.get_env("CHAINGUARD_SOURCE", "none") do
      "kafka" ->
        {:kafka,
         hosts: System.get_env("CHAINGUARD_KAFKA_HOSTS", "localhost:19092"),
         topics:
           String.split(
             System.get_env("CHAINGUARD_KAFKA_TOPICS", "chainguard.ingest.v1.ethereum-mainnet"),
             ","
           ),
         group_id: System.get_env("CHAINGUARD_KAFKA_GROUP", "chainguard-engine")}

      "jsonl" ->
        {:jsonl,
         path: System.fetch_env!("CHAINGUARD_JSONL_PATH"),
         mode: if(System.get_env("CHAINGUARD_JSONL_MODE") == "replay", do: :replay, else: :tail),
         from: if(System.get_env("CHAINGUARD_JSONL_FROM") == "end", do: :end, else: :start)}

      "none" ->
        nil
    end

  config :chain_guard, :source, source

  severity = fn var, default ->
    value = System.get_env(var, default)

    Enum.find(~w(info low medium high critical)a, &(Atom.to_string(&1) == value)) ||
      raise "#{var}: bad severity #{value}"
  end

  connectors =
    [
      System.get_env("CHAINGUARD_WEBHOOK_URL") &&
        {ChainGuard.Alerts.Webhook,
         url: System.get_env("CHAINGUARD_WEBHOOK_URL"),
         secret: System.fetch_env!("CHAINGUARD_WEBHOOK_SECRET"),
         min_severity: severity.("CHAINGUARD_WEBHOOK_MIN_SEVERITY", "medium")},
      System.get_env("CHAINGUARD_PAGERDUTY_ROUTING_KEY") &&
        {ChainGuard.Alerts.PagerDuty,
         routing_key: System.get_env("CHAINGUARD_PAGERDUTY_ROUTING_KEY"),
         min_severity: severity.("CHAINGUARD_PAGERDUTY_MIN_SEVERITY", "high")},
      System.get_env("CHAINGUARD_TELEGRAM_BOT_TOKEN") &&
        {ChainGuard.Alerts.Telegram,
         bot_token: System.get_env("CHAINGUARD_TELEGRAM_BOT_TOKEN"),
         chat_id: System.fetch_env!("CHAINGUARD_TELEGRAM_CHAT_ID"),
         min_severity: severity.("CHAINGUARD_TELEGRAM_MIN_SEVERITY", "high")}
    ]
    |> Enum.filter(& &1)

  config :chain_guard, :connectors, connectors

  if origins = System.get_env("CHAINGUARD_CORS_ORIGINS") do
    config :chain_guard, :cors_origins, String.split(origins, ",")
  end
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :chain_guard, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :chain_guard, ChainGuardWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :chain_guard, ChainGuardWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :chain_guard, ChainGuardWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
