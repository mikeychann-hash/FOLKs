#!/usr/bin/env bash
set -euo pipefail

REMOTE_PORT=22
REMOTE_USER="root"
REMOTE_HOST=""
LAN_IP=""
LAN_INTERFACE="lan"
DRY_RUN=false
SSH_OPTIONS="${FOLKS_SSH_OPTS:-}"
PROFILES=()

usage() {
  cat <<USAGE
Usage: $0 --host <router_ip> --lan-ip <device_ip> --profile <name> [options]

Options:
  -h, --host <address>         Hostname or IP address of the router (required)
  -u, --user <username>        SSH username (default: root)
  -P, --port <port>            SSH port (default: 22)
  -l, --lan-ip <address>       LAN IP of the gaming device or server (required)
  -i, --lan-interface <name>   LAN interface name for the forward (default: lan)
  -p, --profile <name>         Port-forwarding profile to apply (can be repeated)
                               Supported profiles: xbox, minecraft-java, minecraft-bedrock
      --dry-run                Print the commands without executing them
      --help                   Show this message

Examples:
  $0 --host 192.168.1.1 --lan-ip 192.168.1.50 --profile xbox
  $0 --host router.local --lan-ip 192.168.1.60 --profile minecraft-java --profile minecraft-bedrock
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
      -l|--lan-ip)
        if [[ $# -lt 2 ]]; then
          fail "--lan-ip requires a value"
        fi
        LAN_IP="$2"; shift 2 ;;
      -i|--lan-interface)
        if [[ $# -lt 2 ]]; then
          fail "--lan-interface requires a value"
        fi
        LAN_INTERFACE="$2"; shift 2 ;;
      -p|--profile)
        if [[ $# -lt 2 ]]; then
          fail "--profile requires a value"
        fi
        PROFILES+=("$2"); shift 2 ;;
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
  [[ -n "$LAN_IP" ]] || fail "--lan-ip is required"
  [[ ${#PROFILES[@]} -gt 0 ]] || fail "At least one --profile must be provided"

  for profile in "${PROFILES[@]}"; do
    case "$profile" in
      xbox|minecraft-java|minecraft-bedrock) ;;
      *) fail "Unsupported profile: $profile" ;;
    esac
  done
}

require_remote_prerequisites() {
  log "Checking router prerequisites"
  run_remote "command -v uci >/dev/null 2>&1 || { echo 'uci not found on router' >&2; exit 1; }"
  run_remote "[ -x /etc/init.d/firewall ] || { echo 'firewall service not found' >&2; exit 1; }"
}

build_uci_batch() {
  local profile rule_name proto src_port dest_port description
  local -a batch_commands=()

  for profile in "${PROFILES[@]}"; do
    local -a rules=()
    case "$profile" in
      xbox)
        rules=(
          "xbox_live_udp_88|udp|88|88|Xbox Live UDP 88"
          "xbox_live_udp_500|udp|500|500|Xbox Live UDP 500"
          "xbox_live_udp_3544|udp|3544|3544|Xbox Live UDP 3544"
          "xbox_live_udp_4500|udp|4500|4500|Xbox Live UDP 4500"
          "xbox_live_udp_3074|udp|3074|3074|Xbox Live UDP 3074"
          "xbox_live_tcp_3074|tcp|3074|3074|Xbox Live TCP 3074"
          "xbox_live_tcp_80|tcp|80|80|Xbox Live TCP 80"
          "xbox_live_tcp_53|tcp|53|53|Xbox Live TCP 53"
          "xbox_live_udp_53|udp|53|53|Xbox Live UDP 53"
        )
        ;;
      minecraft-java)
        rules=(
          "minecraft_java_tcp_25565|tcp|25565|25565|Minecraft Java TCP 25565"
        )
        ;;
      minecraft-bedrock)
        rules=(
          "minecraft_bedrock_udp_19132|udp|19132|19132|Minecraft Bedrock UDP 19132"
          "minecraft_bedrock_udp_19133|udp|19133|19133|Minecraft Bedrock UDP 19133"
        )
        ;;
      *)
        fail "Unsupported profile: $profile"
        ;;
    esac

    local entry
    for entry in "${rules[@]}"; do
      IFS='|' read -r rule_name proto src_port dest_port description <<<"$entry"
      local redirect_id="pf_${rule_name}"
      batch_commands+=("uci -q get firewall.${redirect_id} >/dev/null 2>&1 || uci set firewall.${redirect_id}=redirect")
      batch_commands+=("uci set firewall.${redirect_id}.name='${description}'")
      batch_commands+=("uci set firewall.${redirect_id}.src='wan'")
      batch_commands+=("uci set firewall.${redirect_id}.dest='${LAN_INTERFACE}'")
      batch_commands+=("uci set firewall.${redirect_id}.dest_ip='${LAN_IP}'")
      batch_commands+=("uci set firewall.${redirect_id}.proto='${proto}'")
      batch_commands+=("uci set firewall.${redirect_id}.src_dport='${src_port}'")
      batch_commands+=("uci set firewall.${redirect_id}.dest_port='${dest_port}'")
      batch_commands+=("uci set firewall.${redirect_id}.target='DNAT'")
    done
  done

  batch_commands+=("uci commit firewall")
  batch_commands+=("/etc/init.d/firewall reload")

  local command="uci batch <<'EOF'\n"
  for line in "${batch_commands[@]}"; do
    command+="$line\n"
  done
  command+="EOF\n"

  printf '%s' "$command"
}

apply_port_forwards() {
  log "Applying port forwarding rules for: ${PROFILES[*]}"
  local batch
  batch=$(build_uci_batch)
  run_remote "$batch"
}

main() {
  parse_args "$@"
  validate_inputs
  require_remote_prerequisites
  apply_port_forwards
  log "Port forwarding complete"
}

main "$@"
