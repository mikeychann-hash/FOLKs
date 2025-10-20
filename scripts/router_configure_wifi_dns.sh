#!/usr/bin/env bash
set -euo pipefail

REMOTE_PORT=22
REMOTE_USER="root"
REMOTE_HOST=""
DRY_RUN=false
SSH_OPTIONS="${FOLKS_SSH_OPTS:-}"

TWO_G_SSID="FolksG"
FIVE_G_SSID="FolksG-5G"
TWO_G_CHANNEL="1"
FIVE_G_CHANNEL="36"
TWO_G_HTMODE="HT20"
FIVE_G_HTMODE="VHT80"

COUNTRY=""
COUNTRY_EXPLICIT=false
TWO_G_TXPOWER=""
TWO_G_TXPOWER_EXPLICIT=false
FIVE_G_TXPOWER=""
FIVE_G_TXPOWER_EXPLICIT=false
EXISTING_TWO_G_COUNTRY=""
EXISTING_FIVE_G_COUNTRY=""
EXISTING_TWO_G_TXPOWER=""
EXISTING_FIVE_G_TXPOWER=""
ENABLE_OPTIMIZATIONS=true

TWO_G_RADIO=""
FIVE_G_RADIO=""
TWO_G_IFACE=""
FIVE_G_IFACE=""

DNS_SERVERS=("1.1.1.1" "1.0.0.1")
HAS_ADGUARD=false

usage() {
  cat <<USAGE
Usage: $0 --host <router_ip> [options]

Options:
  -h, --host <address>            Hostname or IP address of the router (required)
  -u, --user <username>           SSH username (default: root)
  -P, --port <port>               SSH port (default: 22)
      --two-g-ssid <name>         SSID for the 2.4 GHz network (default: FolksG)
      --five-g-ssid <name>        SSID for the 5 GHz network (default: FolksG-5G)
      --two-g-channel <number>    Non-DFS channel for the 2.4 GHz radio (default: 1)
      --five-g-channel <number>   Non-DFS channel for the 5 GHz radio (default: 36)
      --dns-server <address>      Upstream DNS server for AdGuard Home (repeatable)
      --country <code>            Two-letter country code to apply to both radios
      --two-g-txpower <dBm>       Override 2.4 GHz transmit power (integer dBm)
      --five-g-txpower <dBm>      Override 5 GHz transmit power (integer dBm)
      --no-advanced-optimizations Skip latency-focused Wi-Fi tuning (leave radios as-is)
      --two-g-radio <name>        Override detected 2.4 GHz wifi-device section
      --five-g-radio <name>       Override detected 5 GHz wifi-device section
      --two-g-iface <name>        Override detected 2.4 GHz wifi-iface section
      --five-g-iface <name>       Override detected 5 GHz wifi-iface section
      --dry-run                   Print the commands without executing them
      --help                      Show this message

Examples:
  $0 --host 192.168.1.1
  $0 --host router.local --dns-server 1.1.1.1 --dns-server 1.0.0.1
USAGE
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
  log "WARNING: $*"
}

fail() {
  log "ERROR: $*" >&2
  exit 1
}

build_ssh_command() {
  local -a cmd=(ssh -p "$REMOTE_PORT")
  if [[ -n "$SSH_OPTIONS" ]]; then
    # shellcheck disable=SC2206
    cmd+=($SSH_OPTIONS)
  fi
  cmd+=("$REMOTE_USER@$REMOTE_HOST")
  printf '%s\0' "${cmd[@]}"
}

run_remote() {
  local command="$1"
  local -a ssh_cmd
  IFS=$'\0' read -r -d '' -a ssh_cmd < <(build_ssh_command)
  ssh_cmd+=("$command")

  if [ "$DRY_RUN" = true ]; then
    printf 'DRY-RUN: '
    printf '%q ' "${ssh_cmd[@]}"
    printf '\n'
  else
    "${ssh_cmd[@]}"
  fi
}

run_remote_capture() {
  local command="$1"
  local -a ssh_cmd
  IFS=$'\0' read -r -d '' -a ssh_cmd < <(build_ssh_command)
  ssh_cmd+=("$command")

  if [ "$DRY_RUN" = true ]; then
    printf 'DRY-RUN (capture skipped): '
    printf '%q ' "${ssh_cmd[@]}"
    printf '\n'
    return 0
  fi

  "${ssh_cmd[@]}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--host)
        [[ $# -ge 2 ]] || fail "--host requires a value"
        REMOTE_HOST="$2"; shift 2 ;;
      -u|--user)
        [[ $# -ge 2 ]] || fail "--user requires a value"
        REMOTE_USER="$2"; shift 2 ;;
      -P|--port)
        [[ $# -ge 2 ]] || fail "--port requires a value"
        REMOTE_PORT="$2"; shift 2 ;;
      --two-g-ssid)
        [[ $# -ge 2 ]] || fail "--two-g-ssid requires a value"
        TWO_G_SSID="$2"; shift 2 ;;
      --five-g-ssid)
        [[ $# -ge 2 ]] || fail "--five-g-ssid requires a value"
        FIVE_G_SSID="$2"; shift 2 ;;
      --two-g-channel)
        [[ $# -ge 2 ]] || fail "--two-g-channel requires a value"
        TWO_G_CHANNEL="$2"; shift 2 ;;
      --five-g-channel)
        [[ $# -ge 2 ]] || fail "--five-g-channel requires a value"
        FIVE_G_CHANNEL="$2"; shift 2 ;;
      --dns-server)
        [[ $# -ge 2 ]] || fail "--dns-server requires a value"
        DNS_SERVERS+=("$2"); shift 2 ;;
      --country)
        [[ $# -ge 2 ]] || fail "--country requires a value"
        COUNTRY="$2"; COUNTRY_EXPLICIT=true; shift 2 ;;
      --two-g-txpower)
        [[ $# -ge 2 ]] || fail "--two-g-txpower requires a value"
        TWO_G_TXPOWER="$2"; TWO_G_TXPOWER_EXPLICIT=true; shift 2 ;;
      --five-g-txpower)
        [[ $# -ge 2 ]] || fail "--five-g-txpower requires a value"
        FIVE_G_TXPOWER="$2"; FIVE_G_TXPOWER_EXPLICIT=true; shift 2 ;;
      --no-advanced-optimizations)
        ENABLE_OPTIMIZATIONS=false; shift ;;
      --two-g-radio)
        [[ $# -ge 2 ]] || fail "--two-g-radio requires a value"
        TWO_G_RADIO="$2"; shift 2 ;;
      --five-g-radio)
        [[ $# -ge 2 ]] || fail "--five-g-radio requires a value"
        FIVE_G_RADIO="$2"; shift 2 ;;
      --two-g-iface)
        [[ $# -ge 2 ]] || fail "--two-g-iface requires a value"
        TWO_G_IFACE="$2"; shift 2 ;;
      --five-g-iface)
        [[ $# -ge 2 ]] || fail "--five-g-iface requires a value"
        FIVE_G_IFACE="$2"; shift 2 ;;
      --dry-run)
        DRY_RUN=true; shift ;;
      --help)
        usage; exit 0 ;;
      *)
        fail "Unknown option: $1" ;;
    esac
  done
}

validate_channel_inputs() {
  case "$TWO_G_CHANNEL" in
    1|6|11) ;;
    *) fail "2.4 GHz channel must be one of 1, 6, or 11" ;;
  esac

  case "$FIVE_G_CHANNEL" in
    36|40|44|48|149|153|157|161|165) ;;
    *) fail "5 GHz channel must be a non-DFS value (36, 40, 44, 48, 149, 153, 157, 161, or 165)" ;;
  esac
}

normalize_dns_servers() {
  local -a filtered=()
  local value
  for value in "${DNS_SERVERS[@]}"; do
    if [[ "$value" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
      filtered+=("$value")
    fi
  done

  DNS_SERVERS=()
  if [[ ${#filtered[@]} -gt 0 ]]; then
    DNS_SERVERS=("${filtered[@]}")
  else
    DNS_SERVERS=("1.1.1.1" "1.0.0.1")
  fi
}

validate_inputs() {
  [[ -n "$REMOTE_HOST" ]] || fail "--host is required"
  validate_channel_inputs
  normalize_dns_servers
  if [[ -n "$COUNTRY" && ! "$COUNTRY" =~ ^[A-Za-z]{2}$ ]]; then
    fail "Country code must be a two-letter ISO value"
  fi
  if [[ -n "$TWO_G_TXPOWER" && ! "$TWO_G_TXPOWER" =~ ^-?[0-9]+$ ]]; then
    fail "--two-g-txpower must be an integer"
  fi
  if [[ -n "$FIVE_G_TXPOWER" && ! "$FIVE_G_TXPOWER" =~ ^-?[0-9]+$ ]]; then
    fail "--five-g-txpower must be an integer"
  fi
}

require_remote_prerequisites() {
  log "Checking router prerequisites"
  run_remote "command -v uci >/dev/null 2>&1 || { echo 'uci not found on router' >&2; exit 1; }"
  run_remote "command -v wifi >/dev/null 2>&1 || { echo 'wifi helper not found on router' >&2; exit 1; }"
}

detect_country_and_txpower() {
  if [ "$DRY_RUN" = true ]; then
    return
  fi

  local two_country
  local five_country
  local two_power
  local five_power

  two_country="$(run_remote_capture "uci -q get wireless.${TWO_G_RADIO}.country 2>/dev/null || true" | tr -d '\r')"
  five_country="$(run_remote_capture "uci -q get wireless.${FIVE_G_RADIO}.country 2>/dev/null || true" | tr -d '\r')"
  two_power="$(run_remote_capture "uci -q get wireless.${TWO_G_RADIO}.txpower 2>/dev/null || true" | tr -d '\r')"
  five_power="$(run_remote_capture "uci -q get wireless.${FIVE_G_RADIO}.txpower 2>/dev/null || true" | tr -d '\r')"

  EXISTING_TWO_G_COUNTRY="$two_country"
  EXISTING_FIVE_G_COUNTRY="$five_country"
  EXISTING_TWO_G_TXPOWER="$two_power"
  EXISTING_FIVE_G_TXPOWER="$five_power"

  if [[ -z "$COUNTRY" ]]; then
    if [[ -n "$two_country" ]]; then
      COUNTRY="$two_country"
    elif [[ -n "$five_country" ]]; then
      COUNTRY="$five_country"
    fi
  fi
  if [[ -z "$TWO_G_TXPOWER" ]]; then
    TWO_G_TXPOWER="$two_power"
  fi
  if [[ -z "$FIVE_G_TXPOWER" ]]; then
    FIVE_G_TXPOWER="$five_power"
  fi
}

detect_radios_and_ifaces() {
  if [ "$DRY_RUN" = true ]; then
    if [[ -z "$TWO_G_RADIO" ]]; then
      TWO_G_RADIO="radio1"
      warn "Dry-run: assuming 2.4 GHz radio section is '$TWO_G_RADIO'. Override with --two-g-radio if different."
    fi
    if [[ -z "$FIVE_G_RADIO" ]]; then
      FIVE_G_RADIO="radio0"
      warn "Dry-run: assuming 5 GHz radio section is '$FIVE_G_RADIO'. Override with --five-g-radio if different."
    fi
    if [[ -z "$TWO_G_IFACE" ]]; then
      TWO_G_IFACE="default_${TWO_G_RADIO}"
      warn "Dry-run: assuming 2.4 GHz interface section is '$TWO_G_IFACE'. Override with --two-g-iface if different."
    fi
    if [[ -z "$FIVE_G_IFACE" ]]; then
      FIVE_G_IFACE="default_${FIVE_G_RADIO}"
      warn "Dry-run: assuming 5 GHz interface section is '$FIVE_G_IFACE'. Override with --five-g-iface if different."
    fi
    return
  fi

  read -r -d '' detection_cmd <<'DETECT'
set -e
find_devices() {
  local target_band="$1"
  for section in $(uci -q show wireless | awk -F. '/=wifi-device/ {print $2}' | cut -d= -f1); do
    band=$(uci -q get wireless.${section}.band 2>/dev/null || true)
    hwmode=$(uci -q get wireless.${section}.hwmode 2>/dev/null || true)
    if [ -z "$band" ] && [ -n "$hwmode" ]; then
      case "$hwmode" in
        *11b*|*11g*|*11ng*) band="2g" ;;
        *11a*|*11na*|*11ac*|*11nac*|*11ax*) band="5g" ;;
      esac
    fi
    if [ "$target_band" = "$band" ]; then
      echo "$section"
      return
    fi
  done
}

two_g=$(find_devices "2g")
five_g=$(find_devices "5g")

find_iface() {
  local target_device="$1"
  for iface in $(uci -q show wireless | awk -F. '/=wifi-iface/ {print $2}' | cut -d= -f1); do
    device=$(uci -q get wireless.${iface}.device 2>/dev/null || true)
    if [ "$device" = "$target_device" ]; then
      echo "$iface"
      return
    fi
  done
}

two_iface=$(find_iface "$two_g")
five_iface=$(find_iface "$five_g")

echo "$two_g $two_iface $five_g $five_iface"
DETECT

  local result
  result="$(run_remote_capture "$detection_cmd")"

  if [[ -z "$TWO_G_RADIO" ]]; then
    TWO_G_RADIO="$(awk '{print $1}' <<<"$result")"
  fi
  if [[ -z "$TWO_G_IFACE" ]]; then
    TWO_G_IFACE="$(awk '{print $2}' <<<"$result")"
  fi
  if [[ -z "$FIVE_G_RADIO" ]]; then
    FIVE_G_RADIO="$(awk '{print $3}' <<<"$result")"
  fi
  if [[ -z "$FIVE_G_IFACE" ]]; then
    FIVE_G_IFACE="$(awk '{print $4}' <<<"$result")"
  fi

  [[ -n "$TWO_G_RADIO" ]] || fail "Unable to detect 2.4 GHz wifi-device section; provide --two-g-radio"
  [[ -n "$TWO_G_IFACE" ]] || fail "Unable to detect 2.4 GHz wifi-iface section; provide --two-g-iface"
  [[ -n "$FIVE_G_RADIO" ]] || fail "Unable to detect 5 GHz wifi-device section; provide --five-g-radio"
  [[ -n "$FIVE_G_IFACE" ]] || fail "Unable to detect 5 GHz wifi-iface section; provide --five-g-iface"
}

check_adguard_presence() {
  if [ "$DRY_RUN" = true ]; then
    HAS_ADGUARD=true
    warn "Dry-run: assuming AdGuard Home UCI config exists so DNS changes can be previewed."
    return
  fi

  local status
  status="$(run_remote_capture 'if uci -q show adguardhome >/dev/null 2>&1; then echo present; fi')"
  if [[ "$status" == "present" ]]; then
    HAS_ADGUARD=true
  else
    warn "AdGuard Home config not found via UCI; skipping DNS upstream updates."
    HAS_ADGUARD=false
  fi
}

build_configuration_script() {
  local -a commands=()
  commands+=("uci set wireless.${TWO_G_RADIO}.channel='${TWO_G_CHANNEL}'")
  commands+=("uci set wireless.${TWO_G_RADIO}.htmode='${TWO_G_HTMODE}'")
  commands+=("uci set wireless.${FIVE_G_RADIO}.channel='${FIVE_G_CHANNEL}'")
  commands+=("uci set wireless.${FIVE_G_RADIO}.htmode='${FIVE_G_HTMODE}'")
  if [[ -n "$COUNTRY" && (COUNTRY_EXPLICIT || -z "$EXISTING_TWO_G_COUNTRY" || -z "$EXISTING_FIVE_G_COUNTRY") ]]; then
    local upper_country="${COUNTRY^^}"
    commands+=("uci set wireless.${TWO_G_RADIO}.country='${upper_country}'")
    commands+=("uci set wireless.${FIVE_G_RADIO}.country='${upper_country}'")
  fi
  if [[ -n "$TWO_G_TXPOWER" && (TWO_G_TXPOWER_EXPLICIT || -z "$EXISTING_TWO_G_TXPOWER") ]]; then
    commands+=("uci set wireless.${TWO_G_RADIO}.txpower='${TWO_G_TXPOWER}'")
  fi
  if [[ -n "$FIVE_G_TXPOWER" && (FIVE_G_TXPOWER_EXPLICIT || -z "$EXISTING_FIVE_G_TXPOWER") ]]; then
    commands+=("uci set wireless.${FIVE_G_RADIO}.txpower='${FIVE_G_TXPOWER}'")
  fi
  commands+=("uci set wireless.${TWO_G_IFACE}.ssid='${TWO_G_SSID}'")
  commands+=("uci set wireless.${FIVE_G_IFACE}.ssid='${FIVE_G_SSID}'")
  if [ "$ENABLE_OPTIMIZATIONS" = true ]; then
    commands+=("uci set wireless.${TWO_G_RADIO}.noscan='1'")
    commands+=("uci set wireless.${FIVE_G_RADIO}.noscan='1'")
    commands+=("uci set wireless.${TWO_G_RADIO}.distance='0'")
    commands+=("uci set wireless.${FIVE_G_RADIO}.distance='0'")
    commands+=("uci set wireless.${TWO_G_IFACE}.wmm='1'")
    commands+=("uci set wireless.${FIVE_G_IFACE}.wmm='1'")
    commands+=("uci set wireless.${TWO_G_IFACE}.disassoc_low_ack='0'")
    commands+=("uci set wireless.${FIVE_G_IFACE}.disassoc_low_ack='0'")
    commands+=("uci set wireless.${TWO_G_IFACE}.multicast_to_unicast='1'")
    commands+=("uci set wireless.${FIVE_G_IFACE}.multicast_to_unicast='1'")
    commands+=("uci set wireless.${TWO_G_IFACE}.ieee80211k='1'")
    commands+=("uci set wireless.${FIVE_G_IFACE}.ieee80211k='1'")
    commands+=("uci set wireless.${TWO_G_IFACE}.bss_transition='1'")
    commands+=("uci set wireless.${FIVE_G_IFACE}.bss_transition='1'")
  fi
  commands+=("uci commit wireless")

  local upstream_dns=""
  if [ "$HAS_ADGUARD" = true ] && [[ ${#DNS_SERVERS[@]} -gt 0 ]]; then
    printf -v upstream_dns '%s\n' "${DNS_SERVERS[@]}"
    upstream_dns=${upstream_dns%$'\n'}
    commands+=("uci set adguardhome.@adguardhome[0].upstream_dns='${upstream_dns}'")
    commands+=("uci set adguardhome.@adguardhome[0].bootstrap_dns='${DNS_SERVERS[0]}'")
    commands+=("uci commit adguardhome")
  fi

  local script="uci batch <<'EOF'\n"
  local line
  for line in "${commands[@]}"; do
    script+="$line\n"
  done
  script+="EOF\n"
  script+="wifi reload\n"
  if [ "$HAS_ADGUARD" = true ] && [[ ${#DNS_SERVERS[@]} -gt 0 ]]; then
    script+="[ -x /etc/init.d/AdGuardHome ] && /etc/init.d/AdGuardHome restart || true\n"
  fi

  printf '%s' "$script"
}

apply_configuration() {
  log "Applying Wi-Fi and DNS configuration"
  local script
  script="$(build_configuration_script)"
  run_remote "$script"
}

main() {
  parse_args "$@"
  validate_inputs
  require_remote_prerequisites
  detect_radios_and_ifaces
  check_adguard_presence
  detect_country_and_txpower
  log "2.4 GHz SSID: $TWO_G_SSID on channel $TWO_G_CHANNEL ($TWO_G_RADIO/$TWO_G_IFACE)"
  log "5 GHz SSID: $FIVE_G_SSID on channel $FIVE_G_CHANNEL ($FIVE_G_RADIO/$FIVE_G_IFACE)"
  if [[ -n "$COUNTRY" ]]; then
    local country_note="unchanged"
    if [[ COUNTRY_EXPLICIT || -z "$EXISTING_TWO_G_COUNTRY" || -z "$EXISTING_FIVE_G_COUNTRY" ]]; then
      country_note="enforced"
    fi
    log "Regulatory domain: ${COUNTRY^^} (${country_note})"
  fi
  if [[ -n "$TWO_G_TXPOWER" || -n "$FIVE_G_TXPOWER" ]]; then
    local two_label="${TWO_G_TXPOWER:-current}"
    local five_label="${FIVE_G_TXPOWER:-current}"
    local two_note="unchanged"
    local five_note="unchanged"
    if [[ -z "$TWO_G_TXPOWER" ]]; then
      two_note="current"
    elif [[ TWO_G_TXPOWER_EXPLICIT || -z "$EXISTING_TWO_G_TXPOWER" ]]; then
      two_note="set"
    fi
    if [[ -z "$FIVE_G_TXPOWER" ]]; then
      five_note="current"
    elif [[ FIVE_G_TXPOWER_EXPLICIT || -z "$EXISTING_FIVE_G_TXPOWER" ]]; then
      five_note="set"
    fi
    log "Transmit power - 2.4 GHz: ${two_label} (${two_note}), 5 GHz: ${five_label} (${five_note})"
  fi
  if [ "$ENABLE_OPTIMIZATIONS" = true ]; then
    log "Advanced optimizations: fast roaming, WMM QoS, and multicast-to-unicast enabled"
  else
    log "Advanced Wi-Fi optimizations skipped"
  fi
  if [ "$HAS_ADGUARD" = true ]; then
    log "AdGuard Home upstream DNS servers: ${DNS_SERVERS[*]}"
  else
    log "AdGuard Home DNS adjustments will be skipped"
  fi
  apply_configuration
  log "Configuration complete"
}

main "$@"
