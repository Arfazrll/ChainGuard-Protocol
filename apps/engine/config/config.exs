# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :chain_guard,
  ecto_repos: [ChainGuard.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Configure the endpoint
config :chain_guard, ChainGuardWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: ChainGuardWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ChainGuard.PubSub,
  live_view: [signing_salt: "QdcEYCCG"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Detection engine. The stream source is set in runtime.exs (CHAINGUARD_SOURCE);
# with none set, the engine runs without a consumer.
config :chain_guard,
  connectors: [],
  anomaly: nil,
  # Dev servers: dashboard (apps/dashboard) on 4300, landing (apps/landing) on 4400.
  cors_origins: [
    "http://localhost:4300",
    "http://127.0.0.1:4300",
    "http://localhost:4400",
    "http://127.0.0.1:4400"
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
