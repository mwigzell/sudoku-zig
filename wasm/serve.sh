#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PUBLIC="$SCRIPT_DIR/public"
PORT=8901

# 1. Compile WASM
echo "▶ compiling hello.wasm"
cd "$PUBLIC" && zig build-exe "$SCRIPT_DIR/hello.zig" \
  -target wasm32-freestanding \
  -fno-entry \
  --export=greet

# 2. Kill any leftover server on this port
for pid in $(ss -tnp | grep ":${PORT} " | sed -n 's/.*pid=\([0-9]*\).*/\1/p'); do
  kill "$pid" 2>/dev/null && echo "  killed old server pid $pid" || true
done
sleep 0.3

# 3. Start HTTP server from public/
echo "▶ serving on http://127.0.0.1:$PORT"
cd "$PUBLIC" && python3 -m http.server "$PORT" > /dev/null 2>&1 &
SERVER_PID=$!

cleanup() {
  echo; kill "$SERVER_PID" 2>/dev/null && echo "stopped server (pid $SERVER_PID)" || true
  exit 0
}
trap cleanup INT TERM EXIT

# 4. Open browser
sleep 0.5
echo "▶ opening browser"
xdg-open "http://127.0.0.1:$PORT/" &>/dev/null || echo "browser didn't open — point to http://127.0.0.1:$PORT/"

# 5. Wait for server (Ctrl+C triggers cleanup)
wait "$SERVER_PID"
