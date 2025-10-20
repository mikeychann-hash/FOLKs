#!/usr/bin/env bash
set -euo pipefail

REMOTE_PORT=22
REMOTE_USER="root"
PACKAGE_PATH=""
REMOTE_HOST=""
SERVICE_NAME=""
DRY_RUN=false
KEEP_REMOTE_PACKAGE=false
SSH_OPTIONS="${FOLKS_SSH_OPTS:-}"
REMOTE_TMP=""

usage() {
  cat <<USAGE
Usage: $0 --host <router_ip> --package <file.ipk> [options]

Options:
  -h, --host <address>         Hostname or IP address of the router (required)
  -u, --user <username>        SSH username (default: root)
  -P, --port <port>            SSH port (default: 22)
  -p, --package <path>         Path to the local .ipk package to deploy (required)
  -s, --service <name>         Optional OpenWrt init.d service to restart after install
      --keep-remote            Leave the uploaded package in /tmp on the router
      --dry-run                Print the commands that would be executed without running them
      --help                   Show this message

Examples:
  $0 --host 192.168.1.1 --package folkd.ipk --service folkd
  $0 --host router.local --package build/output.ipk --user admin --port 2222
USAGE
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  log "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "Required command '$cmd' not found in PATH"
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

copy_remote() {
  local src="$1"
  local dest="$2"
  local -a scp_cmd=(scp -P "$REMOTE_PORT")
  if [[ -n "$SSH_OPTIONS" ]]; then
    # shellcheck disable=SC2206
    scp_cmd+=($SSH_OPTIONS)
  fi
  scp_cmd+=("$src" "$REMOTE_USER@$REMOTE_HOST:$dest")

  if [ "$DRY_RUN" = true ]; then
    printf 'DRY-RUN: '
    printf '%q ' "${scp_cmd[@]}"
    printf '\n'
  else
    "${scp_cmd[@]}"
  fi
}

cleanup_remote_package() {
  local remote_path="$1"
  if [ "$KEEP_REMOTE_PACKAGE" = true ]; then
    log "Leaving package on router at $remote_path"
    return
  fi

  local remote_cmd
  printf -v remote_cmd 'remote_path=%q; rm -f "$remote_path"' "$remote_path"
  local -a ssh_cmd=(ssh -p "$REMOTE_PORT")
  if [[ -n "$SSH_OPTIONS" ]]; then
    # shellcheck disable=SC2206
    ssh_cmd+=($SSH_OPTIONS)
  fi
  ssh_cmd+=("$REMOTE_USER@$REMOTE_HOST" "$remote_cmd")

  if [ "$DRY_RUN" = true ]; then
    printf 'DRY-RUN: '
    printf '%q ' "${ssh_cmd[@]}"
    printf '\n'
  else
    "${ssh_cmd[@]}" || log "Warning: unable to remove $remote_path"
  fi
}

on_exit() {
  if [[ -n "$REMOTE_TMP" ]]; then
    cleanup_remote_package "$REMOTE_TMP"
  fi
}

check_remote_prerequisites() {
  log "Verifying router prerequisites"
  run_remote "command -v opkg >/dev/null 2>&1 || { echo 'opkg not found on router' >&2; exit 1; }"
  run_remote "[ -w /tmp ] || { echo '/tmp is not writable on router' >&2; exit 1; }"
}

validate_service() {
  if [[ -z "$SERVICE_NAME" ]]; then
    return
  fi

  log "Validating service script for $SERVICE_NAME"
  local remote_cmd
  printf -v remote_cmd 'service=%q; if [ ! -x "/etc/init.d/$service" ]; then echo "Service script /etc/init.d/$service not found or not executable" >&2; exit 1; fi' "$SERVICE_NAME"
  run_remote "$remote_cmd"
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
        PACKAGE_PATH="$2"; shift 2 ;;
      -s|--service)
        if [[ $# -lt 2 ]]; then
          fail "--service requires a value"
        fi
        SERVICE_NAME="$2"; shift 2 ;;
      --dry-run)
        DRY_RUN=true; shift ;;
      --keep-remote)
        KEEP_REMOTE_PACKAGE=true; shift ;;
      --help)
        usage; exit 0 ;;
      *)
        fail "Unknown option: $1" ;;
    esac
  done
}

validate_inputs() {
  [[ -n "$REMOTE_HOST" ]] || fail "--host is required"
  [[ -n "$PACKAGE_PATH" ]] || fail "--package is required"
  [[ -f "$PACKAGE_PATH" ]] || fail "Package '$PACKAGE_PATH' does not exist"
}

main() {
  parse_args "$@"
  validate_inputs

  require_cmd ssh
  require_cmd scp

  log "Checking SSH connectivity"
  run_remote "true"

  check_remote_prerequisites
  validate_service

  local package_name
  package_name="$(basename "$PACKAGE_PATH")"
  REMOTE_TMP="/tmp/${package_name}.$(date '+%Y%m%d%H%M%S')"
  trap on_exit EXIT

  log "Deploying $package_name to $REMOTE_HOST"
  copy_remote "$PACKAGE_PATH" "$REMOTE_TMP"

  log "Installing package via opkg"
  local install_cmd
  printf -v install_cmd 'remote_path=%q; opkg install --force-reinstall "$remote_path"' "$REMOTE_TMP"
  run_remote "$install_cmd"

  if [[ -n "$SERVICE_NAME" ]]; then
    log "Enabling service $SERVICE_NAME"
    local remote_cmd
    printf -v remote_cmd 'service=%q; /etc/init.d/$service enable' "$SERVICE_NAME"
    run_remote "$remote_cmd"
    log "Restarting service $SERVICE_NAME"
    printf -v remote_cmd 'service=%q; /etc/init.d/$service restart' "$SERVICE_NAME"
    run_remote "$remote_cmd"
  fi

  log "Installation finished"
}

main "$@"
