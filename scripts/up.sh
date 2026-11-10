#!/usr/bin/env bash
# ChainGuard on one machine, in one command.
#
#   scripts/up.sh            live: Ethereum mainnet via two public RPCs
#   scripts/up.sh --replay   replay real incidents (USDC depeg, Euler exploit):
#                            alerts within seconds, no RPC needed
#   scripts/down.sh          stop everything
#
# Needs: Rust (cargo), Elixir/OTP (mix), Python + uv, Node + npm, and a
# PostgreSQL that accepts CHAINGUARD_DATABASE_URL (default
# postgres://chainguard:chainguard@localhost/chain_guard_dev).
# For containers instead, see deploy/compose/docker-compose.yml.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

MODE=live
for arg in "$@"; do
  case "$arg" in
    --replay) MODE=replay ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

RUN="$ROOT/var/run"
LOGS="$ROOT/var/logs"
mkdir -p "$RUN" "$LOGS"
export CHAINGUARD_DATABASE_URL="${CHAINGUARD_DATABASE_URL:-postgres://chainguard:chainguard@localhost/chain_guard_dev}"
export MIX_ENV="${MIX_ENV:-dev}"

say() { printf '\n== %s\n' "$*"; }
need() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing: $1 ($2)" >&2; exit 1; }
}

say "checking prerequisites"
need cargo "https://rustup.rs"
need mix "Elixir 1.20 / OTP 29: https://elixir-lang.org/install.html"
need uv "https://docs.astral.sh/uv/"
need npm "Node 24: https://nodejs.org"
need curl "curl"

if ls "$RUN"/*.pid >/dev/null 2>&1; then
  echo "ChainGuard seems to be running already (var/run/*.pid). Run scripts/down.sh first." >&2
  exit 1
fi

# start NAME LOGFILE CMD...: run in the background, remember the PID.
start() {
  local name=$1 log=$2
  shift 2
  ( nohup "$@" >"$log" 2>&1 & echo $! >"$RUN/$name.pid" )
}

wait_for() {
  local name=$1 url=$2 tries=${3:-120}
  for _ in $(seq 1 "$tries"); do
    if curl -sf -m 3 -o /dev/null "$url"; then echo "  $name ready"; return 0; fi
    sleep 1
  done
  echo "  $name did not come up; see var/logs/$name.log" >&2
  return 1
}

say "database: $(echo "$CHAINGUARD_DATABASE_URL" | sed -E 's#//([^:]+):[^@]*@#//\1:***@#')"
(cd apps/engine && mix deps.get >/dev/null && mix ecto.create --quiet && mix ecto.migrate --quiet) || {
  echo "could not prepare the database. Is PostgreSQL running and does CHAINGUARD_DATABASE_URL work?" >&2
  exit 1
}

say "building"
(cd services/anomaly && uv sync --locked --quiet)
(cd services/report && uv sync --locked --quiet)
[ -d apps/dashboard/node_modules ] || (cd apps/dashboard && npm ci --silent)
(cd apps/engine && mix compile >/dev/null)

if [ "$MODE" = live ]; then
  cargo build --release --locked -p chainguard-ingestd >/dev/null 2>&1 || cargo build --release --locked -p chainguard-ingestd
  STREAM="$ROOT/var/stream.jsonl"
  # The example config, writing to var/ and checkpointing there.
  sed -e 's#^path = "-"#path = "var/stream.jsonl"#' \
      -e 's#^checkpoint = .*#checkpoint = "var/ingestd.checkpoint.json"#' \
      config/ingestd.example.toml >var/ingestd.local.toml
  touch "$STREAM"
  start ingestd "$LOGS/ingestd.log" target/release/chainguard-ingestd -c var/ingestd.local.toml
  export CHAINGUARD_SOURCE=jsonl CHAINGUARD_JSONL_PATH="$STREAM" CHAINGUARD_JSONL_MODE=tail
else
  STREAM="$ROOT/var/replay.jsonl"
  elixir scripts/replay-fixtures.exs "$STREAM"
  export CHAINGUARD_SOURCE=jsonl CHAINGUARD_JSONL_PATH="$STREAM" CHAINGUARD_JSONL_MODE=replay
fi

# A demo organization the first time, watching Euler's main contract, so the
# replay also shows a tenant-scoped alert. Created before the engine starts:
# a replay is over within seconds.
if [ ! -f var/demo-org.txt ]; then
  say "creating demo organization"
  if (cd apps/engine && mix chain_guard.org.create "Demo Risk Team" \
       --watch "0x27182842e098f60e3d576794a5bffb0777e025d3:Euler Finance (demo)") >var/demo-org.tmp 2>&1; then
    mv var/demo-org.tmp var/demo-org.txt
    grep -v "API key" var/demo-org.txt
  else
    echo "  demo org not created (it may exist from an earlier run without var/demo-org.txt):" >&2
    sed 's/^/    /' var/demo-org.tmp >&2
    rm -f var/demo-org.tmp
  fi
fi

say "starting services"
start anomaly "$LOGS/anomaly.log" bash -c "cd services/anomaly && exec uv run --locked chainguard-anomaly serve --port 8700"
wait_for anomaly http://127.0.0.1:8700/healthz 60
export CHAINGUARD_ANOMALY_URL=http://127.0.0.1:8700
start engine "$LOGS/engine.log" bash -c "cd apps/engine && exec mix phx.server"
wait_for engine http://127.0.0.1:4000/api/health 180
start report "$LOGS/report.log" bash -c "cd services/report && exec uv run --locked chainguard-report --engine http://127.0.0.1:4000 serve --port 8800"
start dashboard "$LOGS/dashboard.log" bash -c "cd apps/dashboard && exec npx ng serve --host 127.0.0.1 --port 4300"
wait_for report http://127.0.0.1:8800/healthz 60
wait_for dashboard http://127.0.0.1:4300/ 240

cat <<EOF

ChainGuard is up ($MODE).

  Dashboard        http://localhost:4300
  Engine API       http://localhost:4000/api/health   (alerts, scores, audit/verify)
  Report service   http://localhost:8800/reports/alerts/<alert-id>.pdf
  ML service       http://localhost:8700/v1/model
  Landing page     cd apps/landing && npm ci && npm run dev   -> http://localhost:4400

  Demo org key     stored in var/demo-org.txt (keep it private)
    curl -H "authorization: Bearer \$KEY" http://localhost:4000/api/org/alerts

  Logs in var/logs/. Stop with scripts/down.sh
EOF
