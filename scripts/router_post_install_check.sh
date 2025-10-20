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

main() {
  parse_args "$@"
  validate_inputs

  require_cmd ssh

  check_connectivity
  check_storage
  check_package_installed
  check_service
  fetch_logs

  log "Post-installation diagnostics completed"
}

main "$@"
