# syntax=docker/dockerfile:1
# Detection engine (Elixir release). Built from the repository root:
#   docker build -f deploy/docker/engine.Dockerfile .
FROM elixir:1.20-otp-29 AS build
ENV MIX_ENV=prod
WORKDIR /src
RUN mix local.hex --force && mix local.rebar --force

COPY apps/engine/mix.exs apps/engine/mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY apps/engine/config config
COPY apps/engine/lib lib
COPY apps/engine/priv priv
RUN mix compile && mix release

# The bundled incident replay (USDC depeg, Euler exploit): the zero-config demo feed.
COPY apps/engine/test/fixtures/incidents /src/incidents
COPY scripts/replay-fixtures.exs /src/
RUN elixir /src/replay-fixtures.exs /src/replay/incidents.jsonl /src/incidents

FROM elixir:1.20-otp-29-slim
RUN useradd --system --uid 10001 --home /app chainguard
WORKDIR /app
COPY --from=build --chown=chainguard /src/_build/prod/rel/chain_guard ./
COPY --from=build --chown=chainguard /src/replay ./replay
USER chainguard
ENV PHX_SERVER=true PORT=4000
EXPOSE 4000
# Migrate (idempotent), then start. The audit log migration refuses rollback.
CMD ["sh", "-c", "bin/chain_guard eval 'ChainGuard.Release.migrate()' && exec bin/chain_guard start"]
