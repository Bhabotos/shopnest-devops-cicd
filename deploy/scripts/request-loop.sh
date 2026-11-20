#!/usr/bin/env bash
# Sends a steady stream of requests and records every response, as evidence that a deploy or a
# rollback caused no failed request (assignment Part F). Exit status 1 if any request failed.
#   bash request-loop.sh --url <url> [--seconds 60] [--interval 0.1] [--log request-loop.log]
# Start it in the background, run the deploy, then wait for it to finish and read the summary line.
set -euo pipefail

URL=""
SECONDS_TO_RUN=60
INTERVAL=0.1
LOG="request-loop.log"
while [ $# -gt 0 ]; do
  case "$1" in
    --url) URL="${2:-}"; shift 2 ;;
    --seconds) SECONDS_TO_RUN="${2:-60}"; shift 2 ;;
    --interval) INTERVAL="${2:-0.1}"; shift 2 ;;
    --log) LOG="${2:-request-loop.log}"; shift 2 ;;
    *) echo "usage: request-loop.sh --url <url> [--seconds N] [--interval S] [--log FILE]" >&2; exit 2 ;;
  esac
done
[ -n "$URL" ] || { echo "--url is required" >&2; exit 2; }
command -v curl > /dev/null || { echo "curl is required" >&2; exit 2; }

: > "$LOG"
total=0
failed=0
end=$((SECONDS + SECONDS_TO_RUN))
while [ "$SECONDS" -lt "$end" ]; do
  result="$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' --max-time 3 "$URL" 2>&1 || true)"
  code="${result%% *}"
  total=$((total + 1))
  if [ "$code" != "200" ]; then failed=$((failed + 1)); fi
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$result" >> "$LOG"
  sleep "$INTERVAL"
done

printf 'SUMMARY url=%s requests=%d failed=%d\n' "$URL" "$total" "$failed" | tee -a "$LOG"
[ "$failed" -eq 0 ]
