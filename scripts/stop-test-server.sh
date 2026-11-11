#!/bin/bash
# Stops the server started by scripts/start-test-server.sh.
set -euo pipefail

WORK="$(cd "$(dirname "$0")/.." && pwd)/.test-server"
if [[ ! -f "$WORK/server.pid" ]]; then
  echo "No test server is running"
  exit 0
fi
pid=$(cat "$WORK/server.pid")
if kill "$pid" 2> /dev/null; then
  # It stops the server and its database, then exits.
  for _ in $(seq 1 40); do
    kill -0 "$pid" 2> /dev/null || break
    sleep 0.25
  done
fi
rm -f "$WORK/server.pid" "$WORK/env"
echo "Stopped the test server"
