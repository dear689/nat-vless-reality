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

probe_address_family() {
  local family_flag="$1"
  local endpoint
  for endpoint in https://www.cloudflare.com/cdn-cgi/trace https://www.google.com/generate_204; do
    if curl --disable --noproxy '*' --proto '=https' "$family_flag" \
      --connect-timeout 3 --max-time 5 --fail --silent --show-error \
      --output /dev/null "$endpoint" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

detect_address_families() {
  detected_v4=0
  detected_v6=0
  if probe_address_family -4; then detected_v4=1; fi
  if probe_address_family -6; then detected_v6=1; fi
}

select_address_family() {
  local default_family
  if (( detected_v4 == 1 && detected_v6 == 1 )); then
    default_family=3
  elif (( detected_v4 == 1 )); then
    default_family=1
  elif (( detected_v6 == 1 )); then
    default_family=2
  else
    fail "No working IPv4 or IPv6 HTTPS egress. Check DNS, connectivity, and system time."
  fi
  printf '检测到的外网出口：\n  IPv4：%s\n  IPv6：%s\n' \
    "$([[ "$detected_v4" == 1 ]] && printf 可用 || printf 不可用)" \
    "$([[ "$detected_v6" == 1 ]] && printf 可用 || printf 不可用)"
  while :; do
    printf '节点出站方式：\n  1) 仅 IPv4\n  2) 仅 IPv6\n  3) 双栈（TCP 优先 IPv6，IPv4 回退）\n请选择 [%s]：' "$default_family"
    read -r -u 3 address_family || fail "Could not read address family."
    address_family="${address_family:-$default_family}"
    case "$address_family" in
      1) [[ "$detected_v4" == 1 ]] && break ;;
      2) [[ "$detected_v6" == 1 ]] && break ;;
      3) [[ "$detected_v4" == 1 && "$detected_v6" == 1 ]] && break ;;
      *) printf '请输入 1、2 或 3。\n'; continue ;;
    esac
    printf '该选项需要对应的外网连接可用，请重新选择。\n'
  done
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
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl
printf '正在检测 IPv4 和 IPv6 的外网 HTTPS 连通性（最长约 20 秒）...\n'
detect_address_families
select_address_family
printf '节点类型：\n  1) VLESS + REALITY + TCP（直连）\n  2) VLESS + WebSocket（供外部 CDN 回源的明文 HTTP）\n'
read -r -u 3 -p "请选择 [1]： " node_type
node_type="${node_type:-1}"
[[ "$node_type" == 1 || "$node_type" == 2 ]] || fail "节点类型只能选择 1 或 2。"
read -r -u 3 -p "公网 IP 或域名（客户端/CDN 入口，与出站方式无关）： " public_host
read -r -u 3 -p "服务商映射的公网 TCP 端口： " public_port
read -r -u 3 -p "本机监听端口 [${public_port}]： " listen_port
listen_port="${listen_port:-$public_port}"
server_name=""
ws_path=""
cdn_domain=""
cdn_port="443"
default_name="NAT-VLESS"
if [[ "$node_type" == 1 ]]; then
  read -r -u 3 -p "REALITY SNI [${DEFAULT_SNI}]： " server_name
  server_name="${server_name:-$DEFAULT_SNI}"
else
  default_name="NAT-VLESS-WS"
  read -r -u 3 -p "CDN 域名（SNI 和 WebSocket Host）： " cdn_domain
fi
read -r -u 3 -p "节点名称 [${default_name}]： " node_name
node_name="${node_name:-$default_name}"
exec 3<&-

[[ -n "$public_host" ]] || fail "公网 IP 或域名不能为空。"
validate_host "$public_host" "公网 IP 或域名"
validate_port "$public_port" "服务商映射的公网 TCP 端口"
validate_port "$listen_port" "本机监听端口"
if [[ "$node_type" == 1 ]]; then
  validate_hostname "$server_name" "REALITY SNI"
else
  validate_hostname "$cdn_domain" "CDN 域名"
fi
listen_address="0.0.0.0"
if [[ "$public_host" == *:* ]]; then
  listen_address="::"
fi

if command -v ss >/dev/null 2>&1 && ss -Hltn "sport = :${listen_port}" | grep -q .; then
  fail "Local TCP port ${listen_port} is already in use."
fi

apt-get install -y --no-install-recommends openssl python3

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
export XRAY_ADDRESS_FAMILY="$address_family"
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

family = os.environ["XRAY_ADDRESS_FAMILY"]
sockopt = {"domainStrategy": {"1": "ForceIPv4", "2": "ForceIPv6", "3": "UseIP"}[family]}
outbound_settings = {}
if family == "3":
    sockopt["happyEyeballs"] = {
        "tryDelayMs": 250, "prioritizeIPv6": True, "interleave": 1, "maxConcurrentTry": 2,
    }
else:
    # ForceIPv* resolves domains; finalRules also restrict literal and UDP targets.
    outbound_settings["finalRules"] = [{
        "action": "block", "ip": ["::/0" if family == "1" else "0.0.0.0/0"],
        "blockDelay": "0",
    }]

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
    "outbounds": [{
        "protocol": "freedom", "tag": "direct", "settings": outbound_settings,
        "streamSettings": {"sockopt": sockopt},
    }],
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
print("\nXray 服务已启动。")
print("节点出站方式：" + {
    "1": "仅 IPv4", "2": "仅 IPv6", "3": "双栈（TCP 优先 IPv6，IPv4 回退）",
}[os.environ["XRAY_ADDRESS_FAMILY"]])
print("VLESS 链接（复制到客户端）：")
print(
    "vless://" + os.environ["XRAY_UUID"] + "@" + host + ":"
    + (os.environ["XRAY_PUBLIC_PORT"] if os.environ["XRAY_NODE_TYPE"] == "1"
       else os.environ["XRAY_CDN_PORT"])
    + "?" + params + "#" + name
)
if os.environ["XRAY_NODE_TYPE"] == "2":
    print("\nWebSocket 回源路径：" + os.environ["XRAY_WS_PATH"])
    print("CDN 客户端入口：" + host + ":" + os.environ["XRAY_CDN_PORT"])
    print("CDN 域名（SNI 和 WebSocket Host）：" + os.environ["XRAY_CDN_DOMAIN"])
    print("回源：将 HTTP WebSocket 转发到 "
          + origin_host + ":" + os.environ["XRAY_PUBLIC_PORT"]
          + " -> 本机 TCP " + os.environ["XRAY_LISTEN_PORT"] + "。")
    print("请在外部开启该域名的 CDN 代理和 WebSocket。")
    print("本脚本不会修改 DNS、代理状态、回源规则或优选 IP。")
    print("如果之后使用优选 CDN IP，只替换链接中的地址，SNI 和 WebSocket Host 保持不变。")
    print("CDN 到源站仍是明文 HTTP WebSocket；本脚本没有配置源站证书或 Full（严格）模式。")
    print("警告：CDN 到源站的链路是明文，随机路径不是加密或防火墙。")
print("\n请确认服务商已将公网 TCP 端口映射到本机 TCP 端口 "
      + os.environ["XRAY_LISTEN_PORT"]
      + "。本脚本不会修改服务商端口映射或防火墙规则。")
PY
