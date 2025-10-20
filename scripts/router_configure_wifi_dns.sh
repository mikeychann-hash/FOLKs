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
TWO_G_CHANNEL_EXPLICIT=false
FIVE_G_CHANNEL_EXPLICIT=false
AUTO_CHANNEL_SELECTION=true
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
SUPPORTS_ROAMING_FEATURES=true

SECURITY_PROFILE="wpa3-transition"
SECURITY_PROFILE_EXPLICIT=false
PASSPHRASE="mikelind"
PASSPHRASE_FILE=""
PASSPHRASE_EXPLICIT=false
EXISTING_TWO_G_ENCRYPTION=""
EXISTING_FIVE_G_ENCRYPTION=""
EXISTING_TWO_G_KEY=""
EXISTING_FIVE_G_KEY=""
FINAL_ENCRYPTION=""
FINAL_PASSPHRASE=""

BACKUP_DIR=""
BACKUP_ENABLED=true
BACKUP_PATH=""
REVERT_PATH=""
BACKUP_PERFORMED=false

DNS_PROFILE="cloudflare"
DNS_PROTOCOL="plain"
DNS_BOOTSTRAP=""
DNS_HEALTH_CHECK=true

TWO_G_RADIO=""
FIVE_G_RADIO=""
TWO_G_IFACE=""
FIVE_G_IFACE=""
TWO_G_PHY=""
FIVE_G_PHY=""
TWO_G_IFNAME=""
FIVE_G_IFNAME=""

DNS_SERVERS=()
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
      --no-auto-channel          Disable automatic channel selection scans
      --dns-server <address>      Upstream DNS server for AdGuard Home (repeatable)
      --dns-profile <name>        DNS preset (cloudflare, quad9, google, opendns)
      --dns-protocol <type>       DNS protocol for presets (plain, tls, https)
      --bootstrap-dns <address>   Bootstrap resolver when using DoH/DoT
      --skip-dns-health-check     Skip upstream DNS reachability validation
      --country <code>            Two-letter country code to apply to both radios
      --two-g-txpower <dBm>       Override 2.4 GHz transmit power (integer dBm)
      --five-g-txpower <dBm>      Override 5 GHz transmit power (integer dBm)
      --no-advanced-optimizations Skip latency-focused Wi-Fi tuning (leave radios as-is)
      --two-g-radio <name>        Override detected 2.4 GHz wifi-device section
      --five-g-radio <name>       Override detected 5 GHz wifi-device section
      --two-g-iface <name>        Override detected 2.4 GHz wifi-iface section
      --five-g-iface <name>       Override detected 5 GHz wifi-iface section
      --security-profile <mode>   Security mode: wpa2, wpa3, or wpa3-transition (default)
      --passphrase <value>        WPA2/WPA3 passphrase to apply to both SSIDs
      --passphrase-file <path>    Read passphrase from a local file
      --backup-dir <remote_path>  Directory on the router for config backups (default: /tmp)
      --no-backup                 Skip creating a pre-change configuration backup
      --revert <remote_archive>   Restore a previously created backup archive and exit
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
        TWO_G_CHANNEL="$2"; TWO_G_CHANNEL_EXPLICIT=true; shift 2 ;;
      --five-g-channel)
        [[ $# -ge 2 ]] || fail "--five-g-channel requires a value"
        FIVE_G_CHANNEL="$2"; FIVE_G_CHANNEL_EXPLICIT=true; shift 2 ;;
      --no-auto-channel)
        AUTO_CHANNEL_SELECTION=false; shift ;;
      --dns-server)
        [[ $# -ge 2 ]] || fail "--dns-server requires a value"
        DNS_SERVERS+=("$2"); shift 2 ;;
      --dns-profile)
        [[ $# -ge 2 ]] || fail "--dns-profile requires a value"
        DNS_PROFILE="$2"; shift 2 ;;
      --dns-protocol)
        [[ $# -ge 2 ]] || fail "--dns-protocol requires a value"
        DNS_PROTOCOL="$2"; shift 2 ;;
      --bootstrap-dns)
        [[ $# -ge 2 ]] || fail "--bootstrap-dns requires a value"
        DNS_BOOTSTRAP="$2"; shift 2 ;;
      --skip-dns-health-check)
        DNS_HEALTH_CHECK=false; shift ;;
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
      --security-profile)
        [[ $# -ge 2 ]] || fail "--security-profile requires a value"
        SECURITY_PROFILE="$2"; SECURITY_PROFILE_EXPLICIT=true; shift 2 ;;
      --passphrase)
        [[ $# -ge 2 ]] || fail "--passphrase requires a value"
        PASSPHRASE="$2"; PASSPHRASE_EXPLICIT=true; shift 2 ;;
      --passphrase-file)
        [[ $# -ge 2 ]] || fail "--passphrase-file requires a value"
        PASSPHRASE_FILE="$2"; PASSPHRASE_EXPLICIT=true; shift 2 ;;
      --backup-dir)
        [[ $# -ge 2 ]] || fail "--backup-dir requires a value"
        BACKUP_DIR="$2"; shift 2 ;;
      --no-backup)
        BACKUP_ENABLED=false; shift ;;
      --revert)
        [[ $# -ge 2 ]] || fail "--revert requires a value"
        REVERT_PATH="$2"; shift 2 ;;
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
  if [[ "$AUTO_CHANNEL_SELECTION" != true || "$TWO_G_CHANNEL_EXPLICIT" = true ]]; then
    case "$TWO_G_CHANNEL" in
      1|6|11) ;;
      *) fail "2.4 GHz channel must be one of 1, 6, or 11" ;;
    esac
  fi

  if [[ "$AUTO_CHANNEL_SELECTION" != true || "$FIVE_G_CHANNEL_EXPLICIT" = true ]]; then
    case "$FIVE_G_CHANNEL" in
      36|40|44|48|149|153|157|161|165) ;;
      *) fail "5 GHz channel must be a non-DFS value (36, 40, 44, 48, 149, 153, 157, 161, or 165)" ;;
    esac
  fi
}

declare -A DNS_PROFILE_PRESETS=(
  [cloudflare]="1.1.1.1 1.0.0.1"
  [quad9]="9.9.9.9 149.112.112.112"
  [google]="8.8.8.8 8.8.4.4"
  [opendns]="208.67.222.222 208.67.220.220"
)

declare -A DNS_PROFILE_DOH=(
  [cloudflare]="https://cloudflare-dns.com/dns-query https://1.1.1.1/dns-query"
  [quad9]="https://dns.quad9.net/dns-query https://9.9.9.9/dns-query"
  [google]="https://dns.google/dns-query https://dns.google/dns-query"
  [opendns]="https://doh.opendns.com/dns-query https://doh.opendns.com/dns-query"
)

declare -A DNS_PROFILE_DOT=(
  [cloudflare]="tls://1.1.1.1 tls://1.0.0.1"
  [quad9]="tls://dns.quad9.net tls://dns.quad9.net"
  [google]="tls://dns.google tls://dns.google"
  [opendns]="tls://208.67.222.222 tls://208.67.220.220"
)

prepare_dns_servers() {
  local profile_values
  if [[ ${#DNS_SERVERS[@]} -eq 0 ]]; then
    case "$DNS_PROTOCOL" in
      plain)
        profile_values="${DNS_PROFILE_PRESETS[$DNS_PROFILE]}" ;;
      tls)
        profile_values="${DNS_PROFILE_DOT[$DNS_PROFILE]}" ;;
      https)
        profile_values="${DNS_PROFILE_DOH[$DNS_PROFILE]}" ;;
      *)
        fail "Unsupported DNS protocol: $DNS_PROTOCOL" ;;
    esac

    if [[ -z "$profile_values" ]]; then
      fail "Unknown DNS profile '$DNS_PROFILE' for protocol '$DNS_PROTOCOL'"
    fi

    read -r -a DNS_SERVERS <<<"$profile_values"

    if [[ -z "$DNS_BOOTSTRAP" ]]; then
      local bootstrap_source="${DNS_PROFILE_PRESETS[$DNS_PROFILE]}"
      if [[ -n "$bootstrap_source" ]]; then
        read -r -a bootstrap_array <<<"$bootstrap_source"
        DNS_BOOTSTRAP="${bootstrap_array[0]}"
      fi
    fi
  fi

  local -a cleaned=()
  local value
  for value in "${DNS_SERVERS[@]}"; do
    if [[ -n "$value" ]]; then
      cleaned+=("$value")
    fi
  done
  DNS_SERVERS=("${cleaned[@]}")

  if [[ -z "$DNS_BOOTSTRAP" ]]; then
    for value in "${DNS_SERVERS[@]}"; do
      if [[ "$value" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
        DNS_BOOTSTRAP="$value"
        break
      fi
    done
  fi

  if [[ ${#DNS_SERVERS[@]} -eq 0 ]]; then
    fail "No DNS servers provided or resolved from profile"
  fi

  if [[ "$DNS_PROTOCOL" != "plain" && -z "$DNS_BOOTSTRAP" ]]; then
    warn "Bootstrap DNS was not provided and could not be inferred; AdGuard may need manual bootstrap configuration for $DNS_PROTOCOL upstreams"
  fi
}

validate_inputs() {
  [[ -n "$REMOTE_HOST" ]] || fail "--host is required"
  DNS_PROFILE="${DNS_PROFILE,,}"
  DNS_PROTOCOL="${DNS_PROTOCOL,,}"
  validate_channel_inputs
  prepare_dns_servers
  case "$DNS_PROTOCOL" in
    plain|tls|https) ;;
    *) fail "--dns-protocol must be plain, tls, or https" ;;
  esac
  if [[ -n "$PASSPHRASE_FILE" ]]; then
    [[ -r "$PASSPHRASE_FILE" ]] || fail "Passphrase file '$PASSPHRASE_FILE' is not readable"
    PASSPHRASE="$(<"$PASSPHRASE_FILE")"
    PASSPHRASE="${PASSPHRASE%%$'\r'}"
    PASSPHRASE_EXPLICIT=true
  fi
  if [[ -n "$PASSPHRASE" ]]; then
    local pass_len
    pass_len=${#PASSPHRASE}
    if (( pass_len < 8 || pass_len > 63 )); then
      fail "Passphrase must be between 8 and 63 characters"
    fi
  fi
  case "${SECURITY_PROFILE,,}" in
    wpa2|wpa3|wpa3-transition) ;;
    *) fail "--security-profile must be one of: wpa2, wpa3, wpa3-transition" ;;
  esac
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
  if [[ "$BACKUP_ENABLED" = true && "$DRY_RUN" != true ]]; then
    run_remote "command -v tar >/dev/null 2>&1 || { echo 'tar not found on router; required for backups' >&2; exit 1; }"
  fi
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

detect_existing_security() {
  if [ "$DRY_RUN" = true ]; then
    if [[ -n "$PASSPHRASE" ]]; then
      FINAL_PASSPHRASE="$PASSPHRASE"
    else
      FINAL_PASSPHRASE="DryRunPass123!"
      warn "Dry-run: using placeholder WPA key; provide --passphrase to preview custom credentials"
    fi
    return
  fi

  local two_enc
  local five_enc
  local two_key
  local five_key

  two_enc="$(run_remote_capture "uci -q get wireless.${TWO_G_IFACE}.encryption 2>/dev/null || true" | tr -d '\r')"
  five_enc="$(run_remote_capture "uci -q get wireless.${FIVE_G_IFACE}.encryption 2>/dev/null || true" | tr -d '\r')"
  two_key="$(run_remote_capture "uci -q get wireless.${TWO_G_IFACE}.key 2>/dev/null || true" | tr -d '\r')"
  five_key="$(run_remote_capture "uci -q get wireless.${FIVE_G_IFACE}.key 2>/dev/null || true" | tr -d '\r')"

  EXISTING_TWO_G_ENCRYPTION="$two_enc"
  EXISTING_FIVE_G_ENCRYPTION="$five_enc"
  EXISTING_TWO_G_KEY="$two_key"
  EXISTING_FIVE_G_KEY="$five_key"

  if [[ -n "$PASSPHRASE" ]]; then
    FINAL_PASSPHRASE="$PASSPHRASE"
  elif [[ -n "$two_key" && "$two_key" = "$five_key" ]]; then
    FINAL_PASSPHRASE="$two_key"
  elif [[ -n "$two_key" ]]; then
    FINAL_PASSPHRASE="$two_key"
  elif [[ -n "$five_key" ]]; then
    FINAL_PASSPHRASE="$five_key"
  fi
}

determine_security_settings() {
  local normalized_profile="${SECURITY_PROFILE,,}"
  if [[ "$SECURITY_PROFILE_EXPLICIT" != true ]]; then
    local existing_profile=""
    case "${EXISTING_FIVE_G_ENCRYPTION:-$EXISTING_TWO_G_ENCRYPTION}" in
      sae)
        existing_profile="wpa3" ;;
      sae-mixed)
        existing_profile="wpa3-transition" ;;
      psk2)
        existing_profile="wpa2" ;;
    esac
    if [[ -n "$existing_profile" ]]; then
      normalized_profile="$existing_profile"
      SECURITY_PROFILE="$existing_profile"
    fi
  fi

  case "$normalized_profile" in
    wpa2)
      FINAL_ENCRYPTION="psk2" ;;
    wpa3)
      FINAL_ENCRYPTION="sae" ;;
    wpa3-transition)
      FINAL_ENCRYPTION="sae-mixed" ;;
    *)
      fail "Unsupported security profile resolved at runtime: $normalized_profile" ;;
  esac

  if [[ -n "$PASSPHRASE" ]]; then
    FINAL_PASSPHRASE="$PASSPHRASE"
  fi

  if [[ -z "$FINAL_PASSPHRASE" ]]; then
    fail "No WPA2/WPA3 passphrase detected; supply --passphrase or ensure an existing key is configured"
  fi
}

auto_select_channels() {
  if [[ "$AUTO_CHANNEL_SELECTION" != true ]]; then
    return
  fi
  if [ "$DRY_RUN" = true ]; then
    warn "Dry-run: automatic channel selection skipped; using requested defaults"
    return
  fi
  local include_two=true
  local include_five=true
  if [[ "$TWO_G_CHANNEL_EXPLICIT" = true ]]; then
    include_two=false
  fi
  if [[ "$FIVE_G_CHANNEL_EXPLICIT" = true ]]; then
    include_five=false
  fi
  if [[ "$include_two" != true && "$include_five" != true ]]; then
    return
  fi
  if [[ -z "$TWO_G_IFNAME" && -z "$FIVE_G_IFNAME" ]]; then
    warn "Skipping channel scan: unable to determine radio interface names"
    return
  fi

  local channel_cmd
  read -r -d '' channel_cmd <<'SCAN'
two_iface=__TWO_IFACE__
five_iface=__FIVE_IFACE__
two_default=__TWO_DEFAULT__
five_default=__FIVE_DEFAULT__

choose_channel() {
  local iface="$1"
  local default_channel="$2"
  local candidates="$3"
  local label="$4"
  local scan_output=""
  local best="$default_channel"
  local best_score=999999
  local channel

  if [ -z "$iface" ] || ! command -v iwinfo >/dev/null 2>&1; then
    return
  fi

  scan_output=$(iwinfo "$iface" scan 2>/dev/null || true)
  if [ -z "$scan_output" ]; then
    return
  fi

  for channel in $candidates; do
    count=$(printf '%s\n' "$scan_output" | grep -c "Channel: $channel\b" || true)
    if [ "$count" -lt "$best_score" ]; then
      best="$channel"
      best_score="$count"
    fi
  done

  echo "${label}_channel=$best"
  echo "${label}_score=$best_score"
}

choose_channel "$two_iface" "$two_default" "1 6 11" "two"
choose_channel "$five_iface" "$five_default" "36 40 44 48 149 153 157 161 165" "five"
SCAN

  local two_iface_value="$TWO_G_IFNAME"
  local five_iface_value="$FIVE_G_IFNAME"
  if [[ "$include_two" != true ]]; then
    two_iface_value=""
  fi
  if [[ "$include_five" != true ]]; then
    five_iface_value=""
  fi

  channel_cmd=${channel_cmd//__TWO_IFACE__/$(printf '%q' "$two_iface_value")}
  channel_cmd=${channel_cmd//__FIVE_IFACE__/$(printf '%q' "$five_iface_value")}
  channel_cmd=${channel_cmd//__TWO_DEFAULT__/$(printf '%q' "$TWO_G_CHANNEL")}
  channel_cmd=${channel_cmd//__FIVE_DEFAULT__/$(printf '%q' "$FIVE_G_CHANNEL")}

  local result
  result="$(run_remote_capture "$channel_cmd")"

  local selected_two=""
  local selected_two_score=""
  local selected_five=""
  local selected_five_score=""

  while IFS='=' read -r key value; do
    case "$key" in
      two_channel) selected_two="$value" ;;
      two_score) selected_two_score="$value" ;;
      five_channel) selected_five="$value" ;;
      five_score) selected_five_score="$value" ;;
    esac
  done <<<"$result"

  if [[ -n "$selected_two" ]]; then
    TWO_G_CHANNEL="$selected_two"
    log "Auto-selected 2.4 GHz channel $selected_two (detected $selected_two_score competing APs)"
  fi
  if [[ -n "$selected_five" ]]; then
    FIVE_G_CHANNEL="$selected_five"
    log "Auto-selected 5 GHz channel $selected_five (detected $selected_five_score competing APs)"
  fi
}

assess_radio_capabilities() {
  if [ "$DRY_RUN" = true ]; then
    return
  fi

  local capability_cmd
  read -r -d '' capability_cmd <<'CAP'
set -e
five_radio=__FIVE_RADIO__
five_phy=__FIVE_PHY__
supports_five_80=0
supports_five_40=0
supports_kv=0
current_five_htmode=$(uci -q get wireless.${five_radio}.htmode 2>/dev/null || true)

if command -v iw >/dev/null 2>&1 && [ -n "$five_phy" ]; then
  info=$(iw phy "$five_phy" info 2>/dev/null || true)
  if printf '%s\n' "$info" | grep -q '80 MHz'; then
    supports_five_80=1
  fi
  if printf '%s\n' "$info" | grep -q '40 MHz'; then
    supports_five_40=1
  fi
fi

if command -v opkg >/dev/null 2>&1; then
  if opkg list-installed 2>/dev/null | grep -E '^(wpad|hostapd-full)' >/dev/null 2>&1; then
    supports_kv=1
  fi
fi

echo "supports_five_80=$supports_five_80"
echo "supports_five_40=$supports_five_40"
echo "supports_kv=$supports_kv"
echo "current_five_htmode=$current_five_htmode"
CAP

  capability_cmd=${capability_cmd//__FIVE_RADIO__/$(printf '%q' "$FIVE_G_RADIO")}
  capability_cmd=${capability_cmd//__FIVE_PHY__/$(printf '%q' "$FIVE_G_PHY")}

  local result
  result="$(run_remote_capture "$capability_cmd")"

  local supports_five_80="0"
  local supports_five_40="0"
  local current_five_htmode=""

  while IFS='=' read -r key value; do
    case "$key" in
      supports_five_80) supports_five_80="$value" ;;
      supports_five_40) supports_five_40="$value" ;;
      supports_kv)
        if [[ "$value" != "1" ]]; then
          SUPPORTS_ROAMING_FEATURES=false
        fi
        ;;
      current_five_htmode) current_five_htmode="$value" ;;
    esac
  done <<<"$result"

  if [[ "$SUPPORTS_ROAMING_FEATURES" != false ]]; then
    SUPPORTS_ROAMING_FEATURES=true
  fi

  if [[ "$FIVE_G_HTMODE" == "VHT80" && "$supports_five_80" != "1" ]]; then
    if [[ "$supports_five_40" == "1" ]]; then
      FIVE_G_HTMODE="VHT40"
    elif [[ -n "$current_five_htmode" ]]; then
      FIVE_G_HTMODE="$current_five_htmode"
    else
      FIVE_G_HTMODE="HT40"
    fi
    warn "5 GHz radio lacks reliable 80 MHz support; downgrading HT mode to $FIVE_G_HTMODE"
  fi
}

health_check_dns_servers() {
  if [[ "$DNS_HEALTH_CHECK" != true ]]; then
    return
  fi
  if [ "$HAS_ADGUARD" != true ]; then
    return
  fi
  if [ "$DRY_RUN" = true ]; then
    warn "Dry-run: skipping DNS health checks"
    return
  fi
  if [[ ${#DNS_SERVERS[@]} -eq 0 ]]; then
    return
  fi

  local server_list
  printf -v server_list '%s\n' "${DNS_SERVERS[@]}"
  server_list=${server_list%$'\n'}

  local check_cmd
  read -r -d '' check_cmd <<'CHECK'
set +e
failures=0
while IFS= read -r server; do
  [ -n "$server" ] || continue
  proto="$server"
  host="$server"
  port=""
  if echo "$server" | grep -q '://'; then
    proto="${server%%://*}"
    host="${server#*://}"
  else
    proto="plain"
  fi

  case "$proto" in
    plain)
      host="${host%%/*}"
      if command -v ping >/dev/null 2>&1; then
        if ping -c1 -W1 "$host" >/dev/null 2>&1; then
          echo "ok plain $host"
        else
          echo "warn plain $host"
          failures=1
        fi
      else
        echo "warn plain $host ping-missing"
      fi
      ;;
    tls)
      host="${host#//}"
      port="853"
      if echo "$host" | grep -q ':'; then
        port="${host##*:}"
        host="${host%%:*}"
      fi
      if command -v openssl >/dev/null 2>&1; then
        echo | openssl s_client -quiet -connect "$host:$port" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
          echo "ok tls $host:$port"
        else
          echo "warn tls $host:$port"
          failures=1
        fi
      else
        echo "warn tls $host:$port openssl-missing"
      fi
      ;;
    https)
      if command -v wget >/dev/null 2>&1; then
        wget -qO- --timeout=5 "$server" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
          echo "ok https $server"
        else
          echo "warn https $server"
          failures=1
        fi
      elif command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -O /dev/null -T 5 "$server" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
          echo "ok https $server"
        else
          echo "warn https $server"
          failures=1
        fi
      else
        echo "warn https $server fetch-missing"
      fi
      ;;
    *)
      echo "warn unknown $server"
      ;;
  esac
done <<'EOF'
__SERVER_LIST__
EOF

if [ "$failures" -ne 0 ]; then
  exit 1
fi
CHECK

  check_cmd=${check_cmd//__SERVER_LIST__/$(printf '%s' "$server_list")}

  local output
  local status=0
  output="$(run_remote_capture "$check_cmd" 2>&1)" || status=$?
  if (( status != 0 )); then
    while IFS= read -r line; do
      if [[ "$line" == warn* ]]; then
        warn "DNS health: ${line#warn }"
      fi
    done <<<"$output"
    fail "One or more DNS servers failed reachability checks"
  fi

  while IFS= read -r line; do
    case "$line" in
      warn*)
        warn "DNS health: ${line#warn }" ;;
      ok*)
        log "DNS health: ${line#ok } reachable" ;;
    esac
  done <<<"$output"
}

create_configuration_backup() {
  if [[ "$BACKUP_ENABLED" != true ]]; then
    warn "Skipping configuration backup at user request"
    return
  fi
  if [[ -n "$REVERT_PATH" ]]; then
    return
  fi
  if [ "$DRY_RUN" = true ]; then
    BACKUP_PATH="${BACKUP_DIR:-/tmp}/folks_wifi_dns_backup_DRYRUN.tar.gz"
    warn "Dry-run: not creating backup; would have stored at $BACKUP_PATH"
    return
  fi

  local base_dir="${BACKUP_DIR:-/tmp}"
  local backup_cmd
  read -r -d '' backup_cmd <<'BACKUP'
set -e
base_dir=__BASE_DIR__
timestamp=$(date +%Y%m%d%H%M%S)
archive="$base_dir/folks_wifi_dns_backup_${timestamp}.tar.gz"
mkdir -p "$base_dir"
targets="/etc/config/wireless"
if [ -f /etc/config/adguardhome ]; then
  targets="$targets /etc/config/adguardhome"
fi
tar -czf "$archive" $targets
echo "$archive"
BACKUP

  backup_cmd=${backup_cmd//__BASE_DIR__/$(printf '%q' "$base_dir")}

  local path_raw
  path_raw="$(run_remote_capture "$backup_cmd" | tr -d '\r')"
  BACKUP_PATH="$(printf '%s\n' "$path_raw" | tail -n 1)"
  BACKUP_PERFORMED=true
  log "Created router configuration backup at $BACKUP_PATH"
}

perform_revert_if_requested() {
  if [[ -z "$REVERT_PATH" ]]; then
    return
  fi

  log "Restoring router configuration from $REVERT_PATH"
  if [ "$DRY_RUN" = true ]; then
    log "Dry-run: would restore backup and reload Wi-Fi/AdGuard Home"
    exit 0
  fi

  local restore_cmd
  read -r -d '' restore_cmd <<'RESTORE'
set -e
archive=__ARCHIVE__
if [ ! -f "$archive" ]; then
  echo "Backup archive $archive not found" >&2
  exit 1
fi
tmpdir=$(mktemp -d /tmp/folks_wifi_restore.XXXXXX)
trap 'rm -rf "$tmpdir"' EXIT
tar -xzf "$archive" -C "$tmpdir"
if [ -f "$tmpdir/etc/config/wireless" ]; then
  cp "$tmpdir/etc/config/wireless" /etc/config/wireless
fi
if [ -f "$tmpdir/etc/config/adguardhome" ]; then
  cp "$tmpdir/etc/config/adguardhome" /etc/config/adguardhome
fi
uci commit wireless || true
if [ -f /etc/config/adguardhome ]; then
  uci commit adguardhome || true
fi
wifi reload
if [ -x /etc/init.d/AdGuardHome ]; then
  /etc/init.d/AdGuardHome restart || true
fi
RESTORE

  restore_cmd=${restore_cmd//__ARCHIVE__/$(printf '%q' "$REVERT_PATH")}

  run_remote "$restore_cmd"
  log "Restore complete"
  exit 0
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

resolve_ifname() {
  local iface="$1"
  local ifname
  ifname=$(uci -q get wireless.${iface}.ifname 2>/dev/null || true)
  if [ -n "$ifname" ]; then
    echo "$ifname"
    return
  fi
  if command -v ubus >/dev/null 2>&1 && command -v jsonfilter >/dev/null 2>&1; then
    local status
    status=$(ubus call network.wireless status 2>/dev/null || true)
    if [ -n "$status" ]; then
      echo "$status" | jsonfilter -e "@.*.interfaces[@.section=='${iface}'].ifname" 2>/dev/null | head -n1
    fi
  fi
}

two_iface=$(find_iface "$two_g")
five_iface=$(find_iface "$five_g")
two_phy=$(uci -q get wireless.${two_g}.phy 2>/dev/null || true)
five_phy=$(uci -q get wireless.${five_g}.phy 2>/dev/null || true)
two_ifname=$(resolve_ifname "$two_iface")
five_ifname=$(resolve_ifname "$five_iface")

echo "two_radio=$two_g"
echo "two_iface=$two_iface"
echo "two_phy=$two_phy"
echo "two_ifname=$two_ifname"
echo "five_radio=$five_g"
echo "five_iface=$five_iface"
echo "five_phy=$five_phy"
echo "five_ifname=$five_ifname"
DETECT

  local result
  result="$(run_remote_capture "$detection_cmd")"

  while IFS='=' read -r key value; do
    case "$key" in
      two_radio)
        if [[ -z "$TWO_G_RADIO" ]]; then
          TWO_G_RADIO="$value"
        fi
        ;;
      two_iface)
        if [[ -z "$TWO_G_IFACE" ]]; then
          TWO_G_IFACE="$value"
        fi
        ;;
      two_phy)
        TWO_G_PHY="$value"
        ;;
      two_ifname)
        TWO_G_IFNAME="$value"
        ;;
      five_radio)
        if [[ -z "$FIVE_G_RADIO" ]]; then
          FIVE_G_RADIO="$value"
        fi
        ;;
      five_iface)
        if [[ -z "$FIVE_G_IFACE" ]]; then
          FIVE_G_IFACE="$value"
        fi
        ;;
      five_phy)
        FIVE_G_PHY="$value"
        ;;
      five_ifname)
        FIVE_G_IFNAME="$value"
        ;;
    esac
  done <<<"$result"

  [[ -n "$TWO_G_RADIO" ]] || fail "Unable to detect 2.4 GHz wifi-device section; provide --two-g-radio"
  [[ -n "$TWO_G_IFACE" ]] || fail "Unable to detect 2.4 GHz wifi-iface section; provide --two-g-iface"
  [[ -n "$FIVE_G_RADIO" ]] || fail "Unable to detect 5 GHz wifi-device section; provide --five-g-radio"
  [[ -n "$FIVE_G_IFACE" ]] || fail "Unable to detect 5 GHz wifi-iface section; provide --five-g-iface"

  if [[ -z "$TWO_G_IFNAME" ]]; then
    warn "Failed to auto-detect 2.4 GHz interface name; channel scanning may be skipped"
  fi
  if [[ -z "$FIVE_G_IFNAME" ]]; then
    warn "Failed to auto-detect 5 GHz interface name; channel scanning may be skipped"
  fi
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
  commands+=("uci set wireless.${TWO_G_IFACE}.encryption='${FINAL_ENCRYPTION}'")
  commands+=("uci set wireless.${FIVE_G_IFACE}.encryption='${FINAL_ENCRYPTION}'")
  commands+=("uci set wireless.${TWO_G_IFACE}.key='${FINAL_PASSPHRASE}'")
  commands+=("uci set wireless.${FIVE_G_IFACE}.key='${FINAL_PASSPHRASE}'")
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
    if [ "$SUPPORTS_ROAMING_FEATURES" = true ]; then
      commands+=("uci set wireless.${TWO_G_IFACE}.ieee80211k='1'")
      commands+=("uci set wireless.${FIVE_G_IFACE}.ieee80211k='1'")
      commands+=("uci set wireless.${TWO_G_IFACE}.bss_transition='1'")
      commands+=("uci set wireless.${FIVE_G_IFACE}.bss_transition='1'")
    fi
  fi
  commands+=("uci commit wireless")

  local upstream_dns=""
  if [ "$HAS_ADGUARD" = true ] && [[ ${#DNS_SERVERS[@]} -gt 0 ]]; then
    printf -v upstream_dns '%s\n' "${DNS_SERVERS[@]}"
    upstream_dns=${upstream_dns%$'\n'}
    commands+=("uci set adguardhome.@adguardhome[0].upstream_dns='${upstream_dns}'")
    if [[ -n "$DNS_BOOTSTRAP" ]]; then
      commands+=("uci set adguardhome.@adguardhome[0].bootstrap_dns='${DNS_BOOTSTRAP}'")
    fi
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
  perform_revert_if_requested
  detect_radios_and_ifaces
  check_adguard_presence
  detect_existing_security
  detect_country_and_txpower
  assess_radio_capabilities
  auto_select_channels
  determine_security_settings
  health_check_dns_servers
  create_configuration_backup
  log "2.4 GHz SSID: $TWO_G_SSID on channel $TWO_G_CHANNEL ($TWO_G_RADIO/$TWO_G_IFACE)"
  log "5 GHz SSID: $FIVE_G_SSID on channel $FIVE_G_CHANNEL ($FIVE_G_RADIO/$FIVE_G_IFACE)"
  if [[ -n "$COUNTRY" ]]; then
    local country_note="unchanged"
    if [[ COUNTRY_EXPLICIT || -z "$EXISTING_TWO_G_COUNTRY" || -z "$EXISTING_FIVE_G_COUNTRY" ]]; then
      country_note="enforced"
    fi
    log "Regulatory domain: ${COUNTRY^^} (${country_note})"
  fi
  log "Security profile: ${SECURITY_PROFILE} (${FINAL_ENCRYPTION})"
  if [[ -n "$BACKUP_PATH" ]]; then
    log "Backup archive: $BACKUP_PATH"
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
    if [ "$SUPPORTS_ROAMING_FEATURES" = true ]; then
      log "Advanced optimizations: fast roaming, WMM QoS, and multicast-to-unicast enabled"
    else
      log "Advanced optimizations: WMM QoS and multicast-to-unicast enabled; 802.11k/v skipped (wpad-basic detected)"
    fi
  else
    log "Advanced Wi-Fi optimizations skipped"
  fi
  if [ "$HAS_ADGUARD" = true ]; then
    log "AdGuard Home upstream DNS servers: ${DNS_SERVERS[*]}"
    if [[ -n "$DNS_BOOTSTRAP" ]]; then
      log "AdGuard Home bootstrap DNS: $DNS_BOOTSTRAP"
    fi
  else
    log "AdGuard Home DNS adjustments will be skipped"
  fi
  apply_configuration
  log "Configuration complete"
}

main "$@"
