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

validate_route_domain() {
  local value="${1,,}"
  local label="$2"
  local part
  local -a route_labels
  case "$value" in
    domain:*) value="${value#domain:}" ;;
    full:*) value="${value#full:}" ;;
  esac
  validate_hostname "$value" "$label"
  [[ ! "$value" =~ ^[0-9.]+$ ]] || fail "$label 只能填写域名，不能填写 IP。"
  IFS=. read -r -a route_labels <<< "$value"
  for part in "${route_labels[@]}"; do
    [[ "${#part}" -le 63 ]] || fail "$label 的每段域名不能超过 63 字节。"
  done
}

normalize_route_domains() {
  local candidates rule normalized=""
  candidates="$(printf '%s' "$route_domains" | tr '[:upper:]' '[:lower:]' | tr ',[:space:]' '\n')"
  while IFS= read -r rule; do
    [[ -n "$rule" ]] || continue
    validate_route_domain "$rule" "分流域名"
    case "$rule" in
      domain:*|full:*) ;;
      *) rule="domain:$rule" ;;
    esac
    case $'\n'"$normalized"$'\n' in
      *$'\n'"$rule"$'\n'*) continue ;;
    esac
    if [[ -n "$normalized" ]]; then normalized+=$'\n'; fi
    normalized+="$rule"
  done <<< "$candidates"
  [[ -n "$normalized" ]] || fail "启用分流时，至少需要填写一个域名。"
  route_domains="$normalized"
}

validate_route_auth() {
  local user_bytes password_bytes
  if [[ -z "$route_user" ]]; then
    [[ -z "$route_password" ]] || fail "SOCKS5 密码必须与用户名一起填写。"
    return 0
  fi
  user_bytes="$(printf '%s' "$route_user" | wc -c)"
  password_bytes="$(printf '%s' "$route_password" | wc -c)"
  (( user_bytes >= 1 && user_bytes <= 255 && password_bytes >= 1 && password_bytes <= 255 )) \
    || fail "SOCKS5 用户名和密码各需 1 到 255 字节。"
}

select_routing_mode() {
  route_domains=""
  route_host=""
  route_port=""
  route_user=""
  route_password=""
  while :; do
    printf '域名分流：\n  1) 普通模式（全部使用所选出口）\n  2) 自定义域名走 SOCKS5\n'
    read -r -u 3 -p "请选择 [1]： " routing_mode || fail "无法读取分流模式。"
    routing_mode="${routing_mode:-1}"
    case "$routing_mode" in
      1) return 0 ;;
      2) break ;;
      *) printf '请输入 1 或 2。\n' ;;
    esac
  done
  set +x
  printf '未命中域名继续使用所选 IPv4/IPv6 出口；命中域名走 SOCKS5。\n'
  printf '普通域名包含子域名；只匹配完整域名可加 full: 前缀。\n'
  read -r -u 3 -p "分流域名（空格或英文逗号分隔）： " route_domains \
    || fail "无法读取分流域名。"
  normalize_route_domains
  read -r -u 3 -p "SOCKS5 服务器 IP 或域名： " route_host || fail "无法读取 SOCKS5 地址。"
  validate_host "$route_host" "SOCKS5 服务器地址"
  if [[ "$route_host" == \[*\] ]]; then route_host="${route_host:1:${#route_host}-2}"; fi
  read -r -u 3 -p "SOCKS5 端口 [1080]： " route_port || fail "无法读取 SOCKS5 端口。"
  route_port="${route_port:-1080}"
  validate_port "$route_port" "SOCKS5 端口"
  IFS= read -r -u 3 -p "SOCKS5 用户名（无需认证则留空）： " route_user || fail "无法读取 SOCKS5 用户名。"
  if [[ -n "$route_user" ]]; then
    printf 'SOCKS5 密码（输入不回显）： ' >/dev/tty
    IFS= read -r -s -u 3 route_password || fail "无法读取 SOCKS5 密码。"
    printf '\n' >/dev/tty
  fi
  validate_route_auth
  printf 'SOCKS5 本身不加密，HTTPS 内容仍由 TLS 加密；上游地址需能从本机连通。\n'
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

select_node_type() {
  while :; do
    printf '节点类型：\n  1) 仅直连 VLESS + REALITY\n  2) 仅 CDN VLESS + WebSocket\n  3) 直连 + CDN（同时运行）\n  4) 直连 + Argo 隧道（Cloudflare Tunnel，同时运行）\n'
    read -r -u 3 -p "请选择 [1]： " node_type || fail "无法读取节点类型。"
    node_type="${node_type:-1}"
    case "$node_type" in
      1|2|3|4) break ;;
      *) printf '请输入 1、2、3 或 4。\n' ;;
    esac
  done
}

probe_websocket() {
  ws_probe_exit=0
  ws_probe_status=$(curl --disable --noproxy '*' --proto '=http,https' --http1.1 \
    --connect-timeout 2 --max-time 3 --silent --output /dev/null \
    --write-out '%{http_code}' \
    --header "Host: $2" --header 'Connection: Upgrade' --header 'Upgrade: websocket' \
    --header 'Sec-WebSocket-Version: 13' \
    --header 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "$1" 2>/dev/null) \
    || ws_probe_exit=$?
  # An upgraded connection may time out; HTTP 101 still confirms the handshake.
  ws_probe_status=${ws_probe_status:-000}
}

print_tunnel_setup() {
  printf '\n========== Cloudflare Tunnel 填写清单 ==========\n'
  printf '1. 进入 Cloudflare 控制台 -> 网络（Networking）-> Tunnels -> 刚创建的隧道。\n'
  printf '   选择 路由（Routes）-> 添加路由 -> 已发布应用程序（Published application）。\n'
  printf '2. 主机名：选择你的域名并填写子域名，最终完整主机名必须是：\n'
  printf '%s\n' "$cdn_domain"
  printf '3. 路径（Path）：留空，不要把客户端的 WS 路径填在这里。\n'
  printf '4. 服务地址（Service URL）：使用 HTTP，完整地址整行复制：\n'
  printf 'http://127.0.0.1:%s\n' "$ws_listen_port"
  printf '   如果界面分成“类型”和“URL”两栏：类型选 HTTP，URL 只填下面这一行：\n'
  printf '127.0.0.1:%s\n' "$ws_listen_port"
  printf '5. 保存路由。DNS 应自动生成指向该隧道的 CNAME，不用添加指向 VPS 的 A 记录。\n'
  printf '6. 将上方 -Tunnel 节点导入客户端；以下参数已在链接中填好：\n'
  printf '   端口：443；传输：WebSocket；TLS：开启。\n'
  printf '   地址、SNI 和 Host：\n%s\n' "$cdn_domain"
  printf '   仅用于客户端的 WS 路径：\n%s\n' "$ws_path"
  printf '证书：客户端使用 Cloudflare 边缘证书；Tunnel 已加密，本机 HTTP 不需要源站证书。\n'
  printf '本机回源协议由上面的 http:// 地址决定，无须为 Tunnel 强制将整个域名改为灵活模式。\n'
  printf '服务器需允许出站 TCP 或 UDP 7844；不需要为 WS 开公网入站端口。\n'
  printf 'Token 已保存在 root/服务组可读文件中，不会在此清单或节点链接中回显。\n'
  printf '================================================\n'
}

check_websocket_setup() {
  [[ "$node_type" != 1 ]] || return 0
  ws_probe_address=127.0.0.1
  if [[ "$node_type" != 4 && "$listen_address" == "::" ]]; then
    ws_probe_address='[::1]'
  fi
  printf '正在检查本机 WebSocket 握手...\n'
  for ws_probe_attempt in 1 2 3; do
    probe_websocket "http://$ws_probe_address:$ws_listen_port$ws_path" "$cdn_domain"
    [[ "$ws_probe_status" == 101 ]] && break
    if [[ "$ws_probe_attempt" != 3 ]]; then sleep 1; fi
  done
  if [[ "$ws_probe_status" == 101 ]]; then
    printf '本机 WebSocket 握手通过（HTTP 101）。\n'
  else
    printf '警告：本机 WS 检查未通过（HTTP %s，curl 状态 %s），请检查 Xray 服务、监听端口和路径。\n' \
      "$ws_probe_status" "$ws_probe_exit"
  fi
  [[ "$node_type" == 4 ]] || return 0
  printf '正在检查 Tunnel 域名的 TLS 和 WebSocket 回源...\n'
  probe_websocket "https://$cdn_domain$ws_path" "$cdn_domain"
  if [[ "$ws_probe_status" == 101 ]]; then
    printf 'Tunnel 公网 TLS 和 WS 握手通过（HTTP 101）；VLESS 认证和上网仍需客户端实测。\n'
  else
    printf '提示：Tunnel 公网 WS 尚未通过（HTTP %s，curl 状态 %s），节点链接仍会输出。\n' \
      "$ws_probe_status" "$ws_probe_exit"
    case "$ws_probe_exit" in
      6) printf '域名暂时无法解析，请检查公开主机名的 Tunnel CNAME 记录。\n' ;;
      35|51|60) printf '公网 TLS 握手或证书校验失败，请检查该域名的 Cloudflare 边缘证书。\n' ;;
      *) printf '请确认 Tunnel 已连接，并将公开路由设为 http://127.0.0.1:%s；尚未配置的可在连接器上线后添加。\n' "$ws_listen_port" ;;
    esac
    printf '进程启动不代表隧道和公开路由已经可用；不必因此重复安装。\n'
  fi
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
select_node_type
select_routing_mode
read -r -u 3 -p "公网 IP 或域名（客户端/CDN 入口，与出站方式无关）： " public_host
direct_public_port=""
direct_listen_port=""
ws_public_port=""
ws_listen_port=""
if [[ "$node_type" != 2 ]]; then
  read -r -u 3 -p "直连服务商映射的公网 TCP 端口： " direct_public_port
  read -r -u 3 -p "直连本机监听端口 [${direct_public_port}]： " direct_listen_port
  direct_listen_port="${direct_listen_port:-$direct_public_port}"
fi
server_name=""
ws_path=""
cdn_domain=""
cdn_port="443"
argo_token=""
default_name="NAT-VLESS"
if [[ "$node_type" == 1 || "$node_type" == 3 || "$node_type" == 4 ]]; then
  read -r -u 3 -p "REALITY SNI [${DEFAULT_SNI}]： " server_name
  server_name="${server_name:-$DEFAULT_SNI}"
fi
if [[ "$node_type" == 2 || "$node_type" == 3 ]]; then
  if [[ "$node_type" == 2 ]]; then default_name="NAT-VLESS-WS"; fi
  read -r -u 3 -p "CDN 域名（SNI 和 WebSocket Host）： " cdn_domain
fi
if [[ "$node_type" == 2 ]]; then
  read -r -u 3 -p "CDN 回源服务商映射的公网 TCP 端口： " ws_public_port
  read -r -u 3 -p "CDN 回源本机监听端口 [${ws_public_port}]： " ws_listen_port
  ws_listen_port="${ws_listen_port:-$ws_public_port}"
fi
if [[ "$node_type" == 3 ]]; then
  read -r -u 3 -p "CDN 回源服务商映射的公网 TCP 端口： " ws_public_port
  read -r -u 3 -p "CDN 回源本机监听端口 [${ws_public_port}]： " ws_listen_port
  ws_listen_port="${ws_listen_port:-$ws_public_port}"
fi
if [[ "$node_type" == 4 ]]; then
  default_name="NAT-VLESS"
  printf '提示：Argo 隧道会额外运行 cloudflared，128 MB 机器尚未验证内存余量。\n'
  read -r -u 3 -p "Tunnel 域名（公开主机名，可在连接器上线后添加路由）： " cdn_domain
  printf '粘贴 Cloudflare Tunnel Token（输入不回显）： ' >/dev/tty
  IFS= read -r -s -u 3 argo_token || fail "Could not read Cloudflare Tunnel token."
  printf '\n' >/dev/tty
  ws_listen_port="2096"
  read -r -u 3 -p "Tunnel 回源本机监听端口 [${ws_listen_port}]： " input_ws_port
  ws_listen_port="${input_ws_port:-$ws_listen_port}"
fi
read -r -u 3 -p "节点名称 [${default_name}]： " node_name
node_name="${node_name:-$default_name}"
exec 3<&-

[[ -n "$public_host" ]] || fail "公网 IP 或域名不能为空。"
validate_host "$public_host" "公网 IP 或域名"
if [[ "$node_type" != 2 ]]; then
  validate_port "$direct_public_port" "直连服务商映射的公网 TCP 端口"
  validate_port "$direct_listen_port" "直连本机监听端口"
fi
if [[ "$node_type" == 1 || "$node_type" == 3 || "$node_type" == 4 ]]; then
  validate_hostname "$server_name" "REALITY SNI"
fi
if [[ "$node_type" == 2 || "$node_type" == 3 || "$node_type" == 4 ]]; then
  validate_hostname "$cdn_domain" "CDN 域名"
fi
if [[ "$node_type" == 2 || "$node_type" == 3 ]]; then
  validate_port "$ws_public_port" "CDN 回源服务商映射的公网 TCP 端口"
  validate_port "$ws_listen_port" "CDN 回源本机监听端口"
  if [[ "$node_type" == 3 ]]; then
    [[ "$ws_public_port" != "$direct_public_port" ]] \
      || fail "直连和 CDN 回源不能使用同一个公网映射端口。"
    [[ "$ws_listen_port" != "$direct_listen_port" ]] \
      || fail "直连和 WebSocket 不能监听同一个本机端口。"
  fi
fi
if [[ "$node_type" == 4 ]]; then
  validate_port "$ws_listen_port" "Tunnel 回源本机监听端口"
  [[ "$ws_listen_port" != "$direct_listen_port" ]] \
    || fail "直连和 Tunnel WebSocket 不能监听同一个本机端口。"
  [[ -n "$argo_token" && "$argo_token" != *[[:space:]]* ]] \
    || fail "Cloudflare Tunnel Token 不能为空或包含空白字符。"
  [[ ! -e /etc/nat-vless && ! -L /etc/nat-vless \
      && ! -e /etc/systemd/system/cloudflared-nat-vless.service \
      && ! -L /etc/systemd/system/cloudflared-nat-vless.service ]] \
    || fail "已有 NAT VLESS 隧道配置或服务，拒绝覆盖。"
fi
listen_address="0.0.0.0"
if [[ "$public_host" == *:* ]]; then
  listen_address="::"
fi

check_ports=()
if [[ "$node_type" != 2 ]]; then check_ports+=("$direct_listen_port"); fi
if [[ "$node_type" != 1 ]]; then check_ports+=("$ws_listen_port"); fi
for check_port in "${check_ports[@]}"; do
  if command -v ss >/dev/null 2>&1 && ss -Hltn "sport = :${check_port}" | grep -q .; then
    fail "Local TCP port ${check_port} is already in use."
  fi
done

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
direct_enabled=0
ws_enabled=0
if [[ "$node_type" == 1 || "$node_type" == 3 || "$node_type" == 4 ]]; then
  direct_enabled=1
  key_output="$("$XRAY_BIN" x25519)"
  private_key="$(printf '%s\n' "$key_output" | sed -nE 's/^Private ?[Kk]ey:[[:space:]]*//p' | head -n 1)"
  public_key="$(printf '%s\n' "$key_output" | sed -nE 's/^(Password( \(PublicKey\))?|Public ?[Kk]ey):[[:space:]]*//p' | head -n 1)"
  [[ -n "$private_key" && -n "$public_key" ]] || fail "Could not parse the Xray REALITY keypair."
  short_id="$(openssl rand -hex 8)"
fi
if [[ "$node_type" == 2 || "$node_type" == 3 || "$node_type" == 4 ]]; then
  ws_enabled=1
  ws_path="/ws-$(openssl rand -hex 8)"
fi

export XRAY_NODE_TYPE="$node_type"
export XRAY_DIRECT_ENABLED="$direct_enabled"
export XRAY_WS_ENABLED="$ws_enabled"
export XRAY_ADDRESS_FAMILY="$address_family"
export XRAY_WS_PATH="$ws_path"
export XRAY_PRIVATE_KEY="$private_key"
export XRAY_UUID="$uuid"
export XRAY_SHORT_ID="$short_id"
export XRAY_DIRECT_LISTEN_PORT="$direct_listen_port"
export XRAY_WS_LISTEN_PORT="$ws_listen_port"
export XRAY_LISTEN_ADDRESS="$listen_address"
export XRAY_SERVER_NAME="$server_name"
export XRAY_CDN_DOMAIN="$cdn_domain"
export XRAY_CDN_PORT="$cdn_port"
export XRAY_WS_PUBLIC_PORT="$ws_public_port"
export XRAY_ROUTING_MODE="$routing_mode"
export XRAY_ROUTE_DOMAINS="$route_domains"
export XRAY_ROUTE_HOST="$route_host"
export XRAY_ROUTE_PORT="$route_port"
export XRAY_ROUTE_USER="$route_user"
export XRAY_ROUTE_PASSWORD="$route_password"
python3 - "$tmp_dir/config.json" <<'PY'
import json
import os
import sys

direct_enabled = os.environ["XRAY_DIRECT_ENABLED"] == "1"
ws_enabled = os.environ["XRAY_WS_ENABLED"] == "1"
inbounds = []
if direct_enabled:
    inbounds.append({
        "listen": os.environ["XRAY_LISTEN_ADDRESS"],
        "port": int(os.environ["XRAY_DIRECT_LISTEN_PORT"]),
        "protocol": "vless",
        "settings": {
            "clients": [{"id": os.environ["XRAY_UUID"], "flow": "xtls-rprx-vision"}],
            "decryption": "none",
        },
        "streamSettings": {
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
        },
    })
if ws_enabled:
    ws_listen_address = (
        "127.0.0.1" if os.environ["XRAY_NODE_TYPE"] == "4"
        else os.environ["XRAY_LISTEN_ADDRESS"]
    )
    inbounds.append({
        "listen": ws_listen_address,
        "port": int(os.environ["XRAY_WS_LISTEN_PORT"]),
        "protocol": "vless",
        "settings": {
            "clients": [{"id": os.environ["XRAY_UUID"]}],
            "decryption": "none",
        },
        "streamSettings": {
            "network": "ws",
            "security": "none",
            "wsSettings": {"path": os.environ["XRAY_WS_PATH"]},
        },
    })

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
    "inbounds": inbounds,
    "outbounds": [{
        "protocol": "freedom", "tag": "direct", "settings": outbound_settings,
        "streamSettings": {"sockopt": sockopt},
    }],
}
if os.environ.get("XRAY_ROUTING_MODE", "1") == "2":
    server = {
        "address": os.environ["XRAY_ROUTE_HOST"],
        "port": int(os.environ["XRAY_ROUTE_PORT"]),
    }
    if os.environ.get("XRAY_ROUTE_USER"):
        server["users"] = [{
            "user": os.environ["XRAY_ROUTE_USER"],
            "pass": os.environ["XRAY_ROUTE_PASSWORD"],
        }]
    config["outbounds"].append({
        "protocol": "socks", "tag": "custom-upstream",
        "settings": {"servers": [server]},
    })
    config["routing"] = {
        "domainStrategy": "AsIs",
        "rules": [{
            "type": "field",
            "domain": os.environ["XRAY_ROUTE_DOMAINS"].splitlines(),
            "outboundTag": "custom-upstream",
        }],
    }
    for inbound in inbounds:
        inbound["sniffing"] = {
            "enabled": True, "destOverride": ["http", "tls", "quic"],
            "routeOnly": False,
        }
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
PY
unset XRAY_ROUTE_USER XRAY_ROUTE_PASSWORD route_user route_password
"$XRAY_BIN" run -test -config "$tmp_dir/config.json"
if [[ -e "$XRAY_CONFIG" && "$(tr -d '[:space:]' < "$XRAY_CONFIG")" != '{}' ]]; then
  fail "The installer created an unexpected config; refusing to overwrite it."
fi
cloudflared_bin=""
if [[ "$node_type" == 4 ]]; then
  if ! command -v cloudflared >/dev/null 2>&1; then
    install -d -m 755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
      -o /usr/share/keyrings/cloudflare-main.gpg
    printf 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main\n' \
      > /etc/apt/sources.list.d/cloudflared.list
    apt-get update
    apt-get install -y --no-install-recommends cloudflared
  fi
  cloudflared_bin="$(command -v cloudflared)" || fail "cloudflared was not installed."
  "$cloudflared_bin" tunnel run --help | grep -F -- '--token-file' >/dev/null \
    || fail "现有 cloudflared 不支持 --token-file，请先升级后重试。"
  if ! getent group cloudflared >/dev/null 2>&1; then
    addgroup --system cloudflared
  fi
  if ! getent passwd cloudflared >/dev/null 2>&1; then
    adduser --system --no-create-home --ingroup cloudflared \
      --home /nonexistent --shell /usr/sbin/nologin cloudflared
  fi
  install -d -m 750 -o root -g cloudflared /etc/nat-vless
  printf '%s' "$argo_token" > "$tmp_dir/cloudflared-token"
  install -m 640 -o root -g cloudflared \
    "$tmp_dir/cloudflared-token" /etc/nat-vless/cloudflared.token
  unset argo_token
fi
service_user="$(systemctl show -p User --value xray.service)"
[[ -n "$service_user" ]] && id "$service_user" >/dev/null 2>&1 \
  || fail "Could not determine the Xray systemd service user."
service_group="$(id -gn "$service_user")"
install -m 600 -o "$service_user" -g "$service_group" "$tmp_dir/config.json" "$XRAY_CONFIG"
printf 'nat-vless-reality-v1\n' > /usr/local/etc/xray/.nat-vless-installer
chmod 600 /usr/local/etc/xray/.nat-vless-installer
systemctl enable xray.service
systemctl restart xray.service
systemctl is-active --quiet xray.service || fail "Xray did not start; inspect: journalctl -u xray -n 50"
if [[ "$node_type" == 4 ]]; then
  cat > /etc/systemd/system/cloudflared-nat-vless.service <<UNIT
[Unit]
Description=Cloudflare Tunnel for NAT VLESS WebSocket
After=network-online.target xray.service
Wants=network-online.target

[Service]
Type=simple
User=cloudflared
Group=cloudflared
ExecStart=${cloudflared_bin} tunnel --edge-ip-version auto --no-autoupdate run --token-file /etc/nat-vless/cloudflared.token
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
UNIT
  chmod 644 /etc/systemd/system/cloudflared-nat-vless.service
  systemctl daemon-reload
  systemctl enable --now cloudflared-nat-vless.service
  systemctl is-active --quiet cloudflared-nat-vless.service \
    || fail "Cloudflare Tunnel did not start; inspect journalctl -u cloudflared-nat-vless."
fi

check_websocket_setup

export XRAY_PUBLIC_HOST="$public_host"
export XRAY_DIRECT_PUBLIC_PORT="$direct_public_port"
export XRAY_WS_PUBLIC_PORT="$ws_public_port"
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
node_type = os.environ["XRAY_NODE_TYPE"]
base_name = os.environ["XRAY_NODE_NAME"]
direct_enabled = os.environ["XRAY_DIRECT_ENABLED"] == "1"
ws_enabled = os.environ["XRAY_WS_ENABLED"] == "1"

def make_link(host, port, params, label):
    name = quote(label, safe="-._~")
    return "vless://" + os.environ["XRAY_UUID"] + "@" + host + ":" + port + "?" + params + "#" + name

print("\nXray 服务已启动。")
print("节点出站方式：" + {
    "1": "仅 IPv4", "2": "仅 IPv6", "3": "双栈（TCP 优先 IPv6，IPv4 回退）",
}[os.environ["XRAY_ADDRESS_FAMILY"]])
if os.environ.get("XRAY_ROUTING_MODE", "1") == "2":
    print("域名分流：已启用，仅自填域名走 SOCKS5；其他流量使用上述出口。")
    print("分流规则：\n" + os.environ["XRAY_ROUTE_DOMAINS"])
    print("SOCKS5 故障时，命中请求失败，不回退普通出口。")
    print("SOCKS5 地址需本机可达，其连接不受上述普通出口的地址族限制。")
else:
    print("域名分流：普通模式。")
if direct_enabled:
    direct_params = urlencode({
        "encryption": "none",
        "flow": "xtls-rprx-vision",
        "security": "reality",
        "sni": os.environ["XRAY_SERVER_NAME"],
        "fp": "chrome",
        "pbk": os.environ["XRAY_PUBLIC_KEY"],
        "sid": os.environ["XRAY_SHORT_ID"],
        "type": "tcp",
    })
    direct_label = base_name if not ws_enabled else base_name + "-Direct"
    print("\n直连 VLESS 链接：")
    print(make_link(
        origin_host, os.environ["XRAY_DIRECT_PUBLIC_PORT"], direct_params, direct_label
    ))
if ws_enabled:
    tunnel_domain = os.environ["XRAY_CDN_DOMAIN"]
    ws_params = urlencode({
        "encryption": "none", "security": "tls",
        "sni": tunnel_domain,
        "fp": "chrome", "type": "ws",
        "host": tunnel_domain,
        "path": os.environ["XRAY_WS_PATH"],
    })
    ws_label = base_name if not direct_enabled else base_name + (
        "-Tunnel" if node_type == "4" else "-CDN"
    )
    print("\nWebSocket VLESS 链接：")
    print(make_link(tunnel_domain, os.environ["XRAY_CDN_PORT"], ws_params, ws_label))
    print("WebSocket 回源路径：" + os.environ["XRAY_WS_PATH"])
if node_type in ("2", "3"):
    print("CDN 域名（SNI 和 WebSocket Host）：" + os.environ["XRAY_CDN_DOMAIN"])
    print("回源：将 HTTP WebSocket 转发到 "
          + origin_host + ":" + os.environ["XRAY_WS_PUBLIC_PORT"]
          + " -> 本机 TCP " + os.environ["XRAY_WS_LISTEN_PORT"] + "。")
    print("请在外部开启该域名的 CDN 代理和 WebSocket。")
    print("本脚本不会修改 DNS、代理状态、回源规则或优选 IP。")
    print("如果之后使用优选 CDN IP，只替换链接中的地址，SNI 和 WebSocket Host 保持不变。")
    print("普通 CDN 回源是 HTTP，未配置源站证书；Cloudflare 需为该主机名设置灵活（Flexible）模式。")
    print("其他网站需要完全/严格模式时，请用仅匹配此主机名的配置规则，避免改动整个域名。")
    print("警告：CDN 到源站的链路是明文，随机路径不是加密或防火墙。")
if node_type != "2":
    print("\n直连映射：公网 TCP " + os.environ["XRAY_DIRECT_PUBLIC_PORT"]
          + " -> 本机 TCP " + os.environ["XRAY_DIRECT_LISTEN_PORT"] + "。")
if node_type == "2":
    print("\nCDN 映射：公网 TCP " + os.environ["XRAY_WS_PUBLIC_PORT"]
          + " -> 本机 TCP " + os.environ["XRAY_WS_LISTEN_PORT"] + "。")
elif node_type == "3":
    print("CDN 映射：公网 TCP " + os.environ["XRAY_WS_PUBLIC_PORT"]
          + " -> 本机 TCP " + os.environ["XRAY_WS_LISTEN_PORT"] + "。")
print("本脚本不会修改服务商端口映射、DNS 或 Cloudflare 外部路由。")
PY
if [[ "$node_type" == 4 ]]; then
  print_tunnel_setup
fi
