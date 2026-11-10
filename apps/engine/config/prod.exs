import Config

# HTTPS redirect and HSTS, for deployments behind a TLS-terminating proxy.
# Opt-in at build time (CHAINGUARD_FORCE_SSL=true): the self-hosted stack
# talks plain HTTP between containers (e.g. the report service calling
# http://engine:4000), which a forced redirect would break.
if System.get_env("CHAINGUARD_FORCE_SSL") == "true" do
  config :chain_guard, ChainGuardWeb.Endpoint,
    force_ssl: [rewrite_on: [:x_forwarded_proto], exclude: [hosts: ["localhost", "127.0.0.1"]]]
end

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
