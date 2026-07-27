#!/usr/bin/env bash
set -euo pipefail

last="${GT_REMOTE_APP_LOG_LAST:-15m}"
mode="${1:-show}"

usage() {
  cat <<'EOF'
Usage:
  pnpm qa:remote-app-logs
  GT_REMOTE_APP_LOG_LAST=30m pnpm qa:remote-app-logs
  scripts/remote-app-log-tail.sh stream

Shows privacy-safe Glasstunnel Mac remote-app control-plane logs from unified
logging. Use this around hosted mobile app-action tests to prove whether the
Mac received, accepted, handled, started, or failed a remote app action.

Environment:
  GT_REMOTE_APP_LOG_LAST  log window for show mode, default 15m
EOF
}

predicate='subsystem == "io.glasstunnel.host" && category == "RemoteApps"'

case "$mode" in
  -h|--help|help)
    usage
    ;;
  show)
    log show --info --style compact --predicate "$predicate" --last "$last"
    ;;
  stream)
    log stream --info --style compact --predicate "$predicate"
    ;;
  *)
    echo "Unknown mode: $mode" >&2
    usage >&2
    exit 2
    ;;
esac
