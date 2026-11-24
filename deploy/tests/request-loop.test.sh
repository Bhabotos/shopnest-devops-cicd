#!/usr/bin/env bash
# Offline test of deploy/scripts/request-loop.sh (the Part F evidence tool) against a throwaway HTTP server on the loopback address.
# It proves the tool counts what it claims to count, because a zero-downtime claim is only as good as this counter:
#   - a healthy server gives failed=0, exit 0, the SUMMARY line in its old format and a STATS line with real latency numbers
#   - a window of HTTP 503 answers is counted as failed (non200), exits 1, and the failed responses are kept with their body
#   - a server that is gone (connection refused) is counted as failed, not as a success
#   - a server slower than --max-time is counted as a timeout
#   - the version URL log shows WHEN the answer changed
#   - a valued option without a value is refused at once
#   bash deploy/tests/request-loop.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/request-loop.sh"
T="$(mktemp -d)"
SERVER_PID=""
cleanup() { [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2> /dev/null || true; rm -rf "$T"; }
trap cleanup EXIT
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS  $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $*"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got [$2] expected [$3]"; fi; }
has() { if grep -qE -- "$3" "$2" 2> /dev/null; then ok "$1"; else bad "$1: /$3/ not found in $2"; fi; }

command -v curl > /dev/null 2>&1 || { echo "SKIP  curl is not installed"; exit 0; }
command -v python3 > /dev/null 2>&1 && python3 -I -c 'import http.server' > /dev/null 2>&1 || { echo "SKIP  no working python3"; exit 0; }

# The server reads its mode from a file on every request, so the test can change it while the loop runs.
echo ok > "$T/mode"
echo "release-A" > "$T/version"
cat > "$T/server.py" << 'PY'
import http.server, sys, time
d = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        mode = open(d + "/mode").read().strip()
        if self.path == "/version":
            body = open(d + "/version").read().encode(); self.send_response(200); self.end_headers(); self.wfile.write(body); return
        if mode == "slow": time.sleep(2)
        if mode == "503":
            self.send_response(503); self.end_headers(); self.wfile.write(b'{"status":"unavailable"}'); return
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"status":"ok"}')
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(d + "/port", "w").write(str(s.server_address[1]))
s.serve_forever()
PY
python3 -I "$T/server.py" "$T" &
SERVER_PID=$!
for _ in $(seq 1 50); do [ -s "$T/port" ] && break; sleep 0.1; done
PORT="$(cat "$T/port" 2> /dev/null)"
[ -n "$PORT" ] || { echo "FAIL  the test server did not start"; exit 1; }
URL="http://127.0.0.1:$PORT/health"

echo "== a healthy server"
bash "$SCRIPT" --url "$URL" --seconds 2 --interval 0.05 --log "$T/a.log" --json "$T/a.json" > "$T/a.out" 2>&1
check "exit code 0 when nothing failed" "$?" 0
has "SUMMARY line keeps its old format" "$T/a.log" '^SUMMARY url=http://127\.0\.0\.1:[0-9]+/health requests=[0-9]+ failed=0$'
has "STATS line has the window, the counts and real latency numbers" "$T/a.log" '^STATS start=[0-9T:.Z-]+ end=[0-9T:.Z-]+ duration_s=2 ok=[0-9]+ failed=0 timeouts=0 non200=0 longest_failure_streak=0 latency_ms min=[0-9]+ avg=[0-9]+ p50=[0-9]+ p95=[0-9]+ p99=[0-9]+ max=[0-9]+$'
check "every logged request is a 200" "$(awk '$1 ~ /^20/ && $2 != "200"' "$T/a.log" | wc -l | tr -d ' ')" 0
check "the failures file is empty" "$(wc -c < "$T/a.log.failures" | tr -d ' ')" 0
jv() { awk -F': ' -v k="\"$1\"" '$1 ~ k { gsub(/[ ,]/, "", $2); print $2 }' "$T/a.json"; }
n="$(awk '/^SUMMARY /{ for (i = 1; i <= NF; i++) if ($i ~ /^requests=/) { sub("requests=", "", $i); print $i } }' "$T/a.log")"
check "the JSON summary agrees with the log (requests, ok, failed, timeouts)" "$(jv requests) $(jv ok) $(jv failed) $(jv timeouts)" "$n $n 0 0"
has "the JSON summary carries the latency percentiles" "$T/a.json" '"p95": [0-9]+'

echo "== a window of HTTP 503 answers"
echo ok > "$T/mode"
( sleep 1; echo 503 > "$T/mode"; sleep 1; echo ok > "$T/mode" ) &
FLIP=$!
bash "$SCRIPT" --url "$URL" --seconds 4 --interval 0.05 --log "$T/b.log" > "$T/b.out" 2>&1
check "exit code 1 when a request failed" "$?" 1
has "failures are counted as non200, not as timeouts" "$T/b.log" 'failed=[1-9][0-9]* timeouts=0 non200=[1-9][0-9]* longest_failure_streak=[1-9][0-9]*'
has "the failed response and its body are kept" "$T/b.log.failures" 'status=503'
has "the body of the failed response is kept" "$T/b.log.failures" 'body: .*unavailable'
check "requests before and after the window were counted as ok" "$(awk '$2 == "200"' "$T/b.log" | wc -l | tr -d ' ' | awk '{ print ($1 > 3) ? "many" : "few" }')" many
wait "$FLIP"

echo "== a server that is gone (connection refused)"
kill "$SERVER_PID" 2> /dev/null; wait "$SERVER_PID" 2> /dev/null; SERVER_PID=""
bash "$SCRIPT" --url "$URL" --seconds 2 --interval 0.1 --log "$T/c.log" > "$T/c.out" 2>&1
check "exit code 1" "$?" 1
has "every request failed and none is counted as ok" "$T/c.log" 'ok=0 failed=[1-9][0-9]* timeouts=0 non200=[1-9][0-9]*'
has "a refused connection is logged with status 000" "$T/c.log" ' 000 '

echo "== a server slower than --max-time"
python3 -I "$T/server.py" "$T" &
SERVER_PID=$!
rm -f "$T/port"; for _ in $(seq 1 50); do [ -s "$T/port" ] && break; sleep 0.1; done
URL="http://127.0.0.1:$(cat "$T/port")/health"
echo slow > "$T/mode"
bash "$SCRIPT" --url "$URL" --seconds 3 --interval 0.05 --max-time 1 --log "$T/d.log" > "$T/d.out" 2>&1
check "exit code 1" "$?" 1
has "slow answers are counted as timeouts" "$T/d.log" 'failed=[1-9][0-9]* timeouts=[1-9][0-9]*'

echo "== the version log shows when the answer changed"
echo ok > "$T/mode"; echo "release-A" > "$T/version"
( sleep 1; echo "release-B" > "$T/version" ) &
FLIP=$!
bash "$SCRIPT" --url "$URL" --seconds 3 --interval 0.1 --log "$T/e.log" --version-url "http://127.0.0.1:$(cat "$T/port")/version" > "$T/e.out" 2>&1
check "two entries: release-A then release-B" "$(awk '{print $2}' "$T/e.log.versions" | tr '\n' ' ')" "release-A release-B "
wait "$FLIP"

echo "== bad usage"
check "no --url" "$(bash "$SCRIPT" > /dev/null 2>&1; echo $?)" 2
check "a valued option without a value is refused at once" "$(timeout 10 bash "$SCRIPT" --url > /dev/null 2>&1; echo $?)" 2
check "an unknown option" "$(bash "$SCRIPT" --url "$URL" --nope > /dev/null 2>&1; echo $?)" 2

echo
echo "request-loop tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
