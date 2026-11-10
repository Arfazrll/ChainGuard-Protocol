#!/usr/bin/env bash
# Stop everything scripts/up.sh started (process trees, on Linux, macOS and Windows/Git Bash).
set -uo pipefail
cd "$(dirname "$0")/.."

shopt -s nullglob
pids=(var/run/*.pid)
if [ ${#pids[@]} -eq 0 ]; then
  echo "nothing to stop"
  exit 0
fi

for f in "${pids[@]}"; do
  name=$(basename "$f" .pid)
  pid=$(cat "$f")
  if [ -r "/proc/$pid/winpid" ] && command -v taskkill >/dev/null 2>&1; then
    # Git Bash: kill the Windows process tree (mix -> erl, npx -> node, uv -> python).
    taskkill //F //T //PID "$(cat "/proc/$pid/winpid")" >/dev/null 2>&1 || true
  else
    pkill -TERM -P "$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
  fi
  rm -f "$f"
  echo "stopped $name"
done
