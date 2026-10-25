#!/usr/bin/env bash
set -Eeuo pipefail

XRAY_INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
DEFAULT_SNI="gateway.icloud.com"

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

validate_hostname() {
  local value="$1"
  local label="$2"
  local part
  [[ "${#value}" -le 253 && "$value" != .* && "$value" != *. && "$value" != *..* ]] \
    || fail "$label must be a DNS hostname without a scheme, port, or path."
  [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ || "$value" =~ ^[A-Za-z0-9]$ ]] \
    || fail "$label must be a DNS hostname without a scheme, port, or path."
  IFS=. read -r -a parts <<< "$value"
  for part in "${parts[@]}"; do
    [[ "$part" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] \
      || fail "$label contains an invalid DNS label."
  done
}

validate_host() {
  local value="$1"
  local label="$2"
  local unbracketed="$value"
  if [[ "$unbracketed" == \[*\] ]]; then
    unbracketed="${unbracketed:1:${#unbracketed}-2}"
  fi
  if [[ "$unbracketed" == *:* ]]; then
    [[ "$unbracketed" == *:*:* && "$unbracketed" =~ ^[A-Fa-f0-9:.]+$ ]] \
      || fail "$label must be a plain IPv6 address without a port."
  else
    validate_hostname "$unbracketed" "$label"
  fi
}

validate_port() {
  local value="$1"
  local label="$2"
  [[ "$value" =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$value <= 65535 )) \
    || fail "$label must be between 1 and 65535."
}

[[ "${EUID}" -eq 0 ]] || fail "Run this script as root."
[[ -f /etc/os-release ]] || fail "Cannot identify the operating system."
[[ -d /run/systemd/system ]] || fail "This script requires systemd."
command -v apt-get >/dev/null 2>&1 || fail "Only Debian/Ubuntu systems are supported."

if [[ -e "$XRAY_CONFIG" || -e "$XRAY_BIN" || -e /etc/systemd/system/xray.service ]]; then
  fail "Xray is already installed or configured; refusing to overwrite an existing setup."
fi

if ! exec 3</dev/tty; then
  fail "An interactive terminal is required for port mapping details."
fi
printf 'Node type:\n  1) VLESS + REALITY + TCP (direct)\n  2) VLESS + WebSocket (plain HTTP origin for external CDN)\n'
read -r -u 3 -p "Choose [1]: " node_type
node_type="${node_type:-1}"
[[ "$node_type" == 1 || "$node_type" == 2 ]] || fail "Choose node type 1 or 2."
read -r -u 3 -p "Public IP or hostname: " public_host
read -r -u 3 -p "Provider-mapped public TCP port: " public_port
read -r -u 3 -p "Local listen port [${public_port}]: " listen_port
listen_port="${listen_port:-$public_port}"
server_name=""
ws_path=""
cdn_domain=""
cdn_port="443"
default_name="NAT-VLESS"
if [[ "$node_type" == 1 ]]; then
  read -r -u 3 -p "REALITY SNI [${DEFAULT_SNI}]: " server_name
  server_name="${server_name:-$DEFAULT_SNI}"
else
  default_name="NAT-VLESS-WS"
  read -r -u 3 -p "CDN domain (SNI and WebSocket Host): " cdn_domain
fi
read -r -u 3 -p "Node name [${default_name}]: " node_name
node_name="${node_name:-$default_name}"
exec 3<&-

[[ -n "$public_host" ]] || fail "Public host is required."
validate_host "$public_host" "Origin public host"
validate_port "$public_port" "Provider-mapped public TCP port"
validate_port "$listen_port" "Local listen port"
if [[ "$node_type" == 1 ]]; then
  validate_hostname "$server_name" "REALITY SNI"
else
  validate_hostname "$cdn_domain" "CDN domain"
fi
listen_address="0.0.0.0"
if [[ "$public_host" == *:* ]]; then
  listen_address="::"
fi

if command -v ss >/dev/null 2>&1 && ss -Hltn "sport = :${listen_port}" | grep -q .; then
  fail "Local TCP port ${listen_port} is already in use."
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl openssl python3

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
curl -fsSL "$XRAY_INSTALL_URL" -o "$tmp_dir/install-release.sh"
bash "$tmp_dir/install-release.sh" install --without-geodata --without-logfiles

[[ -x "$XRAY_BIN" ]] || fail "Xray installer completed without installing the binary."
mkdir -p "$(dirname "$XRAY_CONFIG")"

uuid="$("$XRAY_BIN" uuid)"
private_key=""
public_key=""
short_id=""
if [[ "$node_type" == 1 ]]; then
  key_output="$("$XRAY_BIN" x25519)"
  private_key="$(printf '%s\n' "$key_output" | sed -nE 's/^Private ?[Kk]ey:[[:space:]]*//p' | head -n 1)"
  public_key="$(printf '%s\n' "$key_output" | sed -nE 's/^(Password( \(PublicKey\))?|Public ?[Kk]ey):[[:space:]]*//p' | head -n 1)"
  [[ -n "$private_key" && -n "$public_key" ]] || fail "Could not parse the Xray REALITY keypair."
  short_id="$(openssl rand -hex 8)"
else
  ws_path="/ws-$(openssl rand -hex 8)"
fi

export XRAY_NODE_TYPE="$node_type"
export XRAY_WS_PATH="$ws_path"
export XRAY_PRIVATE_KEY="$private_key"
export XRAY_UUID="$uuid"
export XRAY_SHORT_ID="$short_id"
export XRAY_LISTEN_PORT="$listen_port"
export XRAY_LISTEN_ADDRESS="$listen_address"
export XRAY_SERVER_NAME="$server_name"
export XRAY_CDN_DOMAIN="$cdn_domain"
export XRAY_CDN_PORT="$cdn_port"
python3 - "$tmp_dir/config.json" <<'PY'
import json
import os
import sys

reality = os.environ["XRAY_NODE_TYPE"] == "1"
client = {"id": os.environ["XRAY_UUID"]}
if reality:
    client["flow"] = "xtls-rprx-vision"
    stream_settings = {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
            "show": False,
            "target": os.environ["XRAY_SERVER_NAME"] + ":443",
            "xver": 0,
            "serverNames": [os.environ["XRAY_SERVER_NAME"]],
            "privateKey": os.environ["XRAY_PRIVATE_KEY"],
            "shortIds": [os.environ["XRAY_SHORT_ID"]],
        },
    }
else:
    stream_settings = {
        "network": "ws",
        "security": "none",
        "wsSettings": {"path": os.environ["XRAY_WS_PATH"]},
    }

config = {
    "log": {"loglevel": "warning"},
    "inbounds": [{
        "listen": os.environ["XRAY_LISTEN_ADDRESS"],
        "port": int(os.environ["XRAY_LISTEN_PORT"]),
        "protocol": "vless",
        "settings": {
            "clients": [client],
            "decryption": "none",
        },
        "streamSettings": stream_settings,
    }],
    "outbounds": [{"protocol": "freedom", "tag": "direct"}],
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
PY
"$XRAY_BIN" run -test -config "$tmp_dir/config.json"
if [[ -e "$XRAY_CONFIG" && "$(tr -d '[:space:]' < "$XRAY_CONFIG")" != '{}' ]]; then
  fail "The installer created an unexpected config; refusing to overwrite it."
fi
service_user="$(systemctl show -p User --value xray.service)"
[[ -n "$service_user" ]] && id "$service_user" >/dev/null 2>&1 \
  || fail "Could not determine the Xray systemd service user."
service_group="$(id -gn "$service_user")"
install -m 600 -o "$service_user" -g "$service_group" "$tmp_dir/config.json" "$XRAY_CONFIG"
systemctl enable xray.service
systemctl restart xray.service
systemctl is-active --quiet xray.service || fail "Xray did not start; inspect: journalctl -u xray -n 50"

export XRAY_PUBLIC_HOST="$public_host"
export XRAY_PUBLIC_PORT="$public_port"
export XRAY_PUBLIC_KEY="$public_key"
export XRAY_NODE_NAME="$node_name"
python3 <<'PY'
import os
from urllib.parse import quote, urlencode

def format_host(value):
    if ":" in value and not (value.startswith("[") and value.endswith("]")):
        return f"[{value}]"
    return value

origin_host = format_host(os.environ["XRAY_PUBLIC_HOST"])
host = origin_host
name = quote(os.environ["XRAY_NODE_NAME"], safe="-._~")
if os.environ["XRAY_NODE_TYPE"] == "1":
    params = urlencode({
        "encryption": "none",
        "flow": "xtls-rprx-vision",
        "security": "reality",
        "sni": os.environ["XRAY_SERVER_NAME"],
        "fp": "chrome",
        "pbk": os.environ["XRAY_PUBLIC_KEY"],
        "sid": os.environ["XRAY_SHORT_ID"],
        "type": "tcp",
    })
else:
    host = os.environ["XRAY_CDN_DOMAIN"]
    params = urlencode({
        "encryption": "none", "security": "tls",
        "sni": os.environ["XRAY_CDN_DOMAIN"],
        "fp": "chrome", "type": "ws",
        "host": os.environ["XRAY_CDN_DOMAIN"],
        "path": os.environ["XRAY_WS_PATH"],
    })
print("\nXray service is active.")
print("VLESS link (copy into your client):")
print(
    "vless://"
    + os.environ["XRAY_UUID"]
    + "@"
    + host
    + ":"
    + (
        os.environ["XRAY_PUBLIC_PORT"]
        if os.environ["XRAY_NODE_TYPE"] == "1"
        else os.environ["XRAY_CDN_PORT"]
    )
    + "?"
    + params
    + "#"
    + name
)
if os.environ["XRAY_NODE_TYPE"] == "2":
    print("\nWebSocket origin path: " + os.environ["XRAY_WS_PATH"])
    print("CDN-ready client endpoint: " + host + ":" + os.environ["XRAY_CDN_PORT"])
    print("CDN domain (SNI and WebSocket Host): " + os.environ["XRAY_CDN_DOMAIN"])
    print("Origin: forward HTTP WebSocket traffic to "
          + origin_host + ":" + os.environ["XRAY_PUBLIC_PORT"]
          + " -> local TCP " + os.environ["XRAY_LISTEN_PORT"] + ".")
    print("Enable CDN proxying and WebSocket support for this hostname externally.")
    print("No DNS, proxy status, origin rule, or preferred edge IP is changed by this script.")
    print("If you select a preferred CDN IP later, replace only the link address; keep SNI and WebSocket Host.")
    print("The CDN-to-origin leg remains plaintext HTTP WebSocket; Full (strict) origin TLS is not configured.")
    print("WARNING: CDN-to-origin traffic is plaintext; a random path is not encryption or a firewall.")
print("\nEnsure the provider maps the public TCP port to local TCP port "
      + os.environ["XRAY_LISTEN_PORT"]
      + ". This script does not change provider port mappings or firewall rules.")
PY
