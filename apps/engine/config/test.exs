import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :chain_guard, ChainGuardWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "bOZ50OHrfcArL5OWYK9inyjtNk1HQvxrg4IUkOykflJN4CkxlPOoSP9/gatkoM/c",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

config :chain_guard, fanout_backoff_ms: 0

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
