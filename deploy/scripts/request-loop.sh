#!/usr/bin/env bash
# Sends a steady stream of requests and records every response, as evidence that a deploy or a rollback caused no failed request
# (assignment Part F). Exit status 1 if any request failed.
#   bash request-loop.sh --url <url> [--seconds 60] [--interval 0.1] [--log request-loop.log] [--max-time 3]
#                        [--version-url <url>] [--json summary.json]
# Start it in the background, run the deploy, then wait for it to finish and read the summary lines.
#
# Files written (the log is the evidence, keep it with the workflow run link):
#   <log>            one line per request:  <UTC timestamp> <HTTP status or 000> <seconds>   (a curl error text follows a 000)
#   <log>.failures   one block per failed request: timestamp, status, seconds and the first 200 bytes of the response body
#   <log>.versions   (only with --version-url) a line each time the answer of that URL changes: it shows WHEN the new release started serving
#   <json>           (only with --json) the same numbers as the STATS line, for the evidence folder
#
# Output (both lines are appended to the log):
#   SUMMARY url=... requests=N failed=F                      (unchanged format: demo-bluegreen-local.sh reads it)
#   STATS start=... end=... duration_s=... ok=... failed=... timeouts=... non200=... longest_failure_streak=...
#         latency_ms min=... avg=... p50=... p95=... p99=... max=...
# A "timeout" is a request that got no answer within --max-time (curl exit 28). Zero downtime may be claimed only if failed=0 over a
# window that covered the whole deploy: the log's first and last timestamps must enclose the workflow's start and end.
set -euo pipefail

URL=""
SECONDS_TO_RUN=60
INTERVAL=0.1
LOG="request-loop.log"
MAX_TIME=3
VERSION_URL=""
JSON=""
usage() { echo "usage: request-loop.sh --url <url> [--seconds N] [--interval S] [--log FILE] [--max-time S] [--version-url URL] [--json FILE]" >&2; exit 2; }
need_value() { [ "$#" -ge 2 ] || usage; }
while [ $# -gt 0 ]; do
  case "$1" in
    --url) need_value "$@"; URL="$2"; shift 2 ;;
    --seconds) need_value "$@"; SECONDS_TO_RUN="$2"; shift 2 ;;
    --interval) need_value "$@"; INTERVAL="$2"; shift 2 ;;
    --log) need_value "$@"; LOG="$2"; shift 2 ;;
    --max-time) need_value "$@"; MAX_TIME="$2"; shift 2 ;;
    --version-url) need_value "$@"; VERSION_URL="$2"; shift 2 ;;
    --json) need_value "$@"; JSON="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$URL" ] || { echo "--url is required" >&2; exit 2; }
command -v curl > /dev/null || { echo "curl is required" >&2; exit 2; }

BODY="$(mktemp)"
ERR="$(mktemp)"
trap 'rm -f "$BODY" "$ERR"' EXIT
: > "$LOG"
: > "$LOG.failures"
[ -z "$VERSION_URL" ] || : > "$LOG.versions"
now() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }

total=0
failed=0
timeouts=0
non200=0
streak=0
longest=0
last_version="<none>"
start="$(now)"
end_at=$((SECONDS + SECONDS_TO_RUN))
while [ "$SECONDS" -lt "$end_at" ]; do
  rc=0
  result="$(curl -sS -o "$BODY" -w '%{http_code} %{time_total}' --max-time "$MAX_TIME" "$URL" 2> "$ERR")" || rc=$?
  code="${result%% *}"
  err="$(tr '
' '  ' < "$ERR" | sed 's/  *$//')"
  [ -z "$err" ] || result="$result $err"
  total=$((total + 1))
  stamp="$(now)"
  if [ "$rc" -eq 0 ] && [ "$code" = "200" ]; then
    streak=0
  else
    failed=$((failed + 1))
    streak=$((streak + 1))
    [ "$streak" -le "$longest" ] || longest="$streak"
    if [ "$rc" -eq 28 ]; then timeouts=$((timeouts + 1)); else non200=$((non200 + 1)); fi
    {
      printf '%s status=%s curl_exit=%s %s\n' "$stamp" "$code" "$rc" "$result"
      head -c 200 "$BODY" 2> /dev/null | tr -d '\r' | sed 's/^/  body: /'
      echo
    } >> "$LOG.failures"
  fi
  printf '%s %s\n' "$stamp" "$result" >> "$LOG"
  if [ -n "$VERSION_URL" ]; then
    v="$(curl -sS --max-time "$MAX_TIME" "$VERSION_URL" 2> /dev/null | head -c 200 | tr -d '\r\n' || true)"
    if [ "$v" != "$last_version" ]; then printf '%s %s\n' "$stamp" "${v:-<no answer>}" >> "$LOG.versions"; last_version="$v"; fi
  fi
  sleep "$INTERVAL"
done
end="$(now)"

# Latency statistics from the log (only requests that got an answer carry a real time).
stats="$(awk '$2 != "000" && $3 ~ /^[0-9.]+$/ { printf "%d\n", $3 * 1000 + 0.5 }' "$LOG" | sort -n | awk '
  { v[NR] = $1; s += $1 }
  END {
    if (NR == 0) { print "min=n/a avg=n/a p50=n/a p95=n/a p99=n/a max=n/a"; exit }
    p50 = v[int((NR - 1) * 0.50) + 1]; p95 = v[int((NR - 1) * 0.95) + 1]; p99 = v[int((NR - 1) * 0.99) + 1]
    printf "min=%d avg=%.0f p50=%d p95=%d p99=%d max=%d", v[1], s / NR, p50, p95, p99, v[NR]
  }')"
ok=$((total - failed))
printf 'SUMMARY url=%s requests=%d failed=%d\n' "$URL" "$total" "$failed" | tee -a "$LOG"
printf 'STATS start=%s end=%s duration_s=%s ok=%d failed=%d timeouts=%d non200=%d longest_failure_streak=%d latency_ms %s\n' \
  "$start" "$end" "$SECONDS_TO_RUN" "$ok" "$failed" "$timeouts" "$non200" "$longest" "$stats" | tee -a "$LOG"
if [ -n "$JSON" ]; then
  # Plain bash on purpose: no dependency on a Python, and no path translation problem on Windows.
  lat_json="$(printf '%s' "$stats" | awk '{ out = ""; for (i = 1; i <= NF; i++) { split($i, kv, "="); v = (kv[2] ~ /^[0-9]+$/) ? kv[2] : "null"; out = out (i > 1 ? ", " : "") "\"" kv[1] "\": " v } print out }')"
  printf '{
  "url": "%s",
  "start": "%s",
  "end": "%s",
  "duration_s": %s,
  "requests": %d,
  "ok": %d,
  "failed": %d,
  "timeouts": %d,
  "non200": %d,
  "longest_failure_streak": %d,
  "latency_ms": { %s }
}
'     "$URL" "$start" "$end" "$SECONDS_TO_RUN" "$total" "$ok" "$failed" "$timeouts" "$non200" "$longest" "$lat_json" > "$JSON"
fi
[ "$failed" -eq 0 ]
