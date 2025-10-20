#!/usr/bin/env bash
set -euo pipefail

REMOTE_PORT=22
REMOTE_USER="root"
REMOTE_HOST=""
PACKAGE_NAME=""
SERVICE_NAME=""
LOG_PATH=""
DRY_RUN=false
SSH_OPTIONS="${FOLKS_SSH_OPTS:-}"
PING_TARGET=""
PING_COUNT=10
LATENCY_WARN_MS=0
LOSS_WARN_PERCENT=0

usage() {
  cat <<USAGE
Usage: $0 --host <router_ip> --package <name> [options]

Options:
  -h, --host <address>         Hostname or IP address of the router (required)
  -u, --user <username>        SSH username (default: root)
  -P, --port <port>            SSH port (default: 22)
  -p, --package <name>         Installed package name to verify (required)
  -s, --service <name>         Optional OpenWrt init.d service to check
  -l, --log-path <path>        Optional remote log path to tail (e.g. /var/log/messages)
  -t, --ping-target <host>     Optional host to ping from the router for latency checks
  -c, --ping-count <num>       Number of ping probes to send (default: 10)
      --latency-warn-ms <ms>   Warn if average latency exceeds this threshold (default: disabled)
      --loss-warn-percent <n>  Warn if packet loss percent exceeds this threshold (default: disabled)
      --dry-run                Print commands without executing them
      --help                   Show this message
USAGE
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  log "ERROR: $*" >&2
  exit 1
}

run_remote() {
  local command="$1"
  local -a ssh_cmd=(ssh -p "$REMOTE_PORT")
  if [[ -n "$SSH_OPTIONS" ]]; then
    # shellcheck disable=SC2206
    ssh_cmd+=($SSH_OPTIONS)
  fi
  ssh_cmd+=("$REMOTE_USER@$REMOTE_HOST" "$command")

  if [ "$DRY_RUN" = true ]; then
    printf 'DRY-RUN: '
    printf '%q ' "${ssh_cmd[@]}"
    printf '\n'
  else
    "${ssh_cmd[@]}"
  fi
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "Required command '$cmd' not found in PATH"
}

is_positive_integer() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] && (( value > 0 ))
}

is_non_negative_integer() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]]
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--host)
        if [[ $# -lt 2 ]]; then
          fail "--host requires a value"
        fi
        REMOTE_HOST="$2"; shift 2 ;;
      -u|--user)
        if [[ $# -lt 2 ]]; then
          fail "--user requires a value"
        fi
        REMOTE_USER="$2"; shift 2 ;;
      -P|--port)
        if [[ $# -lt 2 ]]; then
          fail "--port requires a value"
        fi
        REMOTE_PORT="$2"; shift 2 ;;
      -p|--package)
        if [[ $# -lt 2 ]]; then
          fail "--package requires a value"
        fi
        PACKAGE_NAME="$2"; shift 2 ;;
      -s|--service)
        if [[ $# -lt 2 ]]; then
          fail "--service requires a value"
        fi
        SERVICE_NAME="$2"; shift 2 ;;
      -l|--log-path)
        if [[ $# -lt 2 ]]; then
          fail "--log-path requires a value"
        fi
        LOG_PATH="$2"; shift 2 ;;
      -t|--ping-target)
        if [[ $# -lt 2 ]]; then
          fail "--ping-target requires a value"
        fi
        PING_TARGET="$2"; shift 2 ;;
      -c|--ping-count)
        if [[ $# -lt 2 ]]; then
          fail "--ping-count requires a value"
        fi
        PING_COUNT="$2"; shift 2 ;;
      --latency-warn-ms)
        if [[ $# -lt 2 ]]; then
          fail "--latency-warn-ms requires a value"
        fi
        LATENCY_WARN_MS="$2"; shift 2 ;;
      --loss-warn-percent)
        if [[ $# -lt 2 ]]; then
          fail "--loss-warn-percent requires a value"
        fi
        LOSS_WARN_PERCENT="$2"; shift 2 ;;
      --dry-run)
        DRY_RUN=true; shift ;;
      --help)
        usage; exit 0 ;;
      *)
        fail "Unknown option: $1" ;;
    esac
  done
}

validate_inputs() {
  [[ -n "$REMOTE_HOST" ]] || fail "--host is required"
  [[ -n "$PACKAGE_NAME" ]] || fail "--package is required"

  if [[ -n "$PING_TARGET" ]]; then
    is_positive_integer "$PING_COUNT" || fail "--ping-count must be a positive integer"
    is_non_negative_integer "$LATENCY_WARN_MS" || fail "--latency-warn-ms must be a non-negative integer"
    is_non_negative_integer "$LOSS_WARN_PERCENT" || fail "--loss-warn-percent must be a non-negative integer"
  fi
}

check_connectivity() {
  log "Checking SSH connectivity"
  run_remote "true"
}

check_storage() {
  log "Checking available storage in /overlay"
  run_remote "df -h /overlay"
}

check_package_installed() {
  log "Verifying that package '$PACKAGE_NAME' is installed"
  local remote_cmd
  printf -v remote_cmd 'package=%q; if ! command -v opkg >/dev/null 2>&1; then echo "opkg not found on router" >&2; exit 1; fi; if ! opkg list-installed | grep -F -w "$package" >/dev/null; then echo "Package $package is not installed" >&2; exit 1; fi' "$PACKAGE_NAME"
  run_remote "$remote_cmd"
}

check_service() {
  if [[ -z "$SERVICE_NAME" ]]; then
    return
  fi

  log "Checking status of service '$SERVICE_NAME'"
  local remote_cmd
  printf -v remote_cmd 'service=%q; if [ ! -x "/etc/init.d/$service" ]; then echo "Service script /etc/init.d/$service not found" >&2; exit 1; fi' "$SERVICE_NAME"
  run_remote "$remote_cmd"

  printf -v remote_cmd 'service=%q; if /etc/init.d/$service enabled; then echo "Service $service is enabled"; else echo "Service $service is not enabled" >&2; exit 1; fi' "$SERVICE_NAME"
  run_remote "$remote_cmd"

  printf -v remote_cmd 'service=%q; if /etc/init.d/$service status; then echo "Service $service is running"; else echo "Service $service is not running" >&2; exit 1; fi' "$SERVICE_NAME"
  run_remote "$remote_cmd"
}

fetch_logs() {
  if [[ -z "$LOG_PATH" ]]; then
    return
  fi

  log "Tailing last 50 lines from $LOG_PATH"
  local remote_cmd
  printf -v remote_cmd 'log_path=%q; if [ ! -f "$log_path" ]; then echo "Log file $log_path not found" >&2; exit 1; fi; tail -n 50 "$log_path"' "$LOG_PATH"
  run_remote "$remote_cmd"
}

run_remote_capture() {
  local command="$1"
  local -a ssh_cmd=(ssh -p "$REMOTE_PORT")
  if [[ -n "$SSH_OPTIONS" ]]; then
    # shellcheck disable=SC2206
    ssh_cmd+=($SSH_OPTIONS)
  fi
  ssh_cmd+=("$REMOTE_USER@$REMOTE_HOST" "$command")

  if [ "$DRY_RUN" = true ]; then
    printf 'DRY-RUN: '
    printf '%q ' "${ssh_cmd[@]}"
    printf '\n'
    return 0
  else
    "${ssh_cmd[@]}"
  fi
}

check_latency() {
  if [[ -z "$PING_TARGET" ]]; then
    return
  fi

  log "Measuring latency to $PING_TARGET ($PING_COUNT probes)"
  local remote_cmd
  printf -v remote_cmd 'target=%q; count=%q; if ! command -v ping >/dev/null 2>&1; then echo "ping command not available on router" >&2; exit 1; fi; ping -c "$count" -q "$target"' "$PING_TARGET" "$PING_COUNT"

  if [ "$DRY_RUN" = true ]; then
    run_remote "$remote_cmd"
    return
  fi

  local output
  if ! output="$(run_remote_capture "$remote_cmd")"; then
    fail "Latency check failed"
  fi

  printf '%s\n' "$output"

  local packet_line latency_line avg_latency="" packet_loss=""
  packet_line="$(printf '%s\n' "$output" | grep -E 'packet loss' || true)"
  latency_line="$(printf '%s\n' "$output" | grep -E 'round-trip|rtt' || true)"

  if [[ -n "$packet_line" && "$packet_line" =~ ([0-9]+\.?[0-9]*)% ]]; then
    packet_loss="${BASH_REMATCH[1]}"
    log "Packet loss to $PING_TARGET: ${packet_loss}%"
  fi

  if [[ -n "$latency_line" ]]; then
    local stats="${latency_line#*= }"
    stats="${stats% ms}"
    local IFS='/'
    read -r _ avg_latency _ _ <<< "$stats"
    if [[ -n "$avg_latency" ]]; then
      log "Average latency to $PING_TARGET: ${avg_latency} ms"
    fi
  fi

  if [[ -n "$avg_latency" ]] && (( LATENCY_WARN_MS > 0 )); then
    if awk "BEGIN { exit !($avg_latency > $LATENCY_WARN_MS) }"; then
      log "WARNING: average latency ${avg_latency} ms exceeds ${LATENCY_WARN_MS} ms"
    fi
  fi

  if [[ -n "$packet_loss" ]] && (( LOSS_WARN_PERCENT > 0 )); then
    if awk "BEGIN { exit !($packet_loss > $LOSS_WARN_PERCENT) }"; then
      log "WARNING: packet loss ${packet_loss}% exceeds ${LOSS_WARN_PERCENT}%"
    fi
  fi
}

main() {
  parse_args "$@"
  validate_inputs

  require_cmd ssh

  check_connectivity
  check_storage
  check_package_installed
  check_service
  fetch_logs
  check_latency

  log "Post-installation diagnostics completed"
}

main "$@"
