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
default_name="NAT-VLESS"
if [[ "$node_type" == 1 ]]; then
  read -r -u 3 -p "REALITY SNI [${DEFAULT_SNI}]: " server_name
  server_name="${server_name:-$DEFAULT_SNI}"
else
  default_name="NAT-VLESS-WS"
  printf 'CDN mode: no domain/certificate setup; an HTTP WebSocket path will be generated.\n'
fi
read -r -u 3 -p "Node name [${default_name}]: " node_name
node_name="${node_name:-$default_name}"
exec 3<&-

[[ -n "$public_host" ]] || fail "Public host is required."
[[ "$public_host" =~ ^[A-Za-z0-9.:-]+$ || "$public_host" =~ ^\[[A-Fa-f0-9:]+\]$ ]] \
  || fail "Public host must be an IP address or DNS hostname (without a scheme or port)."
[[ "$public_port" =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$public_port <= 65535 )) \
  || fail "Public TCP port must be between 1 and 65535."
[[ "$listen_port" =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$listen_port <= 65535 )) \
  || fail "Local listen port must be between 1 and 65535."
if [[ "$node_type" == 1 ]]; then
  [[ "$server_name" =~ ^[A-Za-z0-9.-]+$ ]] || fail "Invalid SNI hostname."
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

host = os.environ["XRAY_PUBLIC_HOST"]
if ":" in host and not (host.startswith("[") and host.endswith("]")):
    host = f"[{host}]"
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
    params = urlencode({
        "encryption": "none", "security": "none", "type": "ws",
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
    + os.environ["XRAY_PUBLIC_PORT"]
    + "?"
    + params
    + "#"
    + name
)
if os.environ["XRAY_NODE_TYPE"] == "2":
    print("\nWebSocket origin path: " + os.environ["XRAY_WS_PATH"])
    print("CDN setup is external. This link is an origin template, NOT a TLS/CDN-ready node.")
    print("Client: set CDN address/edge port, enable TLS, set your domain as SNI and WS Host; keep UUID and path.")
    print("Origin: forward HTTP WebSocket traffic to the mapped public TCP port; no TLS certificate is installed.")
    print("WARNING: CDN-to-origin traffic is plaintext; a random path is not encryption or a firewall.")
print("\nEnsure the provider maps the public TCP port to local TCP port "
      + os.environ["XRAY_LISTEN_PORT"]
      + ". This script does not change provider port mappings or firewall rules.")
PY
