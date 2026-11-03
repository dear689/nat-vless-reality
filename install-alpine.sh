#!/bin/sh
set -eu

XRAY_BIN=/usr/local/bin/xray
XRAY_CONFIG=/usr/local/etc/xray/config.json
XRAY_SERVICE=/etc/init.d/xray
DEFAULT_SNI=gateway.icloud.com

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

validate_hostname() {
  value=$1
  label=$2
  case "$value" in
    ''|.*|*.|*..*) fail "$label must be a DNS hostname without a scheme, port, or path." ;;
  esac
  [ "${#value}" -le 253 ] \
    || fail "$label must be a DNS hostname without a scheme, port, or path."
  printf '%s' "$value" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$|^[A-Za-z0-9]$' \
    || fail "$label must be a DNS hostname without a scheme, port, or path."
  old_ifs=$IFS
  IFS=.
  set -- $value
  IFS=$old_ifs
  for part do
    printf '%s' "$part" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$' \
      || fail "$label contains an invalid DNS label."
  done
}

validate_host() {
  value=$1
  label=$2
  unbracketed=$value
  case "$unbracketed" in
    \[*\])
      unbracketed=${unbracketed#\[}
      unbracketed=${unbracketed%\]}
      ;;
  esac
  case "$unbracketed" in
    *:*)
      printf '%s' "$unbracketed" | grep -Eq '.*:.*:' \
        && printf '%s' "$unbracketed" | grep -Eq '^[A-Fa-f0-9:.]+$' \
        || fail "$label must be a plain IPv6 address without a port."
      ;;
    *)
      validate_hostname "$unbracketed" "$label"
      ;;
  esac
}

validate_port() {
  value=$1
  label=$2
  printf '%s' "$value" | grep -Eq '^[1-9][0-9]{0,4}$' \
    || fail "$label must be between 1 and 65535."
  [ "$value" -le 65535 ] || fail "$label must be between 1 and 65535."
}

probe_address_family() {
  family_flag=$1
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
  if [ "$detected_v4" -eq 1 ] && [ "$detected_v6" -eq 1 ]; then
    default_family=3
  elif [ "$detected_v4" -eq 1 ]; then
    default_family=1
  elif [ "$detected_v6" -eq 1 ]; then
    default_family=2
  else
    fail 'No working IPv4 or IPv6 HTTPS egress. Check DNS, connectivity, and system time.'
  fi
  printf '检测到的外网出口：\n  IPv4：%s\n  IPv6：%s\n' \
    "$( [ "$detected_v4" -eq 1 ] && printf 可用 || printf 不可用 )" \
    "$( [ "$detected_v6" -eq 1 ] && printf 可用 || printf 不可用 )"
  while :; do
    printf '节点出站方式：\n  1) 仅 IPv4\n  2) 仅 IPv6\n  3) 双栈（TCP 优先 IPv6，IPv4 回退）\n请选择 [%s]：' "$default_family"
    IFS= read -r address_family <&3 || fail 'Could not read address family.'
    address_family=${address_family:-$default_family}
    case "$address_family" in
      1) [ "$detected_v4" -eq 1 ] && break ;;
      2) [ "$detected_v6" -eq 1 ] && break ;;
      3) [ "$detected_v4" -eq 1 ] && [ "$detected_v6" -eq 1 ] && break ;;
      *) printf '请输入 1、2 或 3。\n'; continue ;;
    esac
    printf '该选项需要对应的外网连接可用，请重新选择。\n'
  done
}

select_node_type() {
  while :; do
    printf '节点类型：\n  1) 仅直连 VLESS + REALITY\n  2) 仅 CDN VLESS + WebSocket\n  3) 直连 + CDN（同时运行）\n  4) 直连 + Argo 隧道（Cloudflare Tunnel，同时运行）\n请选择 [1]：' >/dev/tty
    IFS= read -r node_type <&3 || fail '无法读取节点类型。'
    node_type=${node_type:-1}
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
  [ "$node_type" != 1 ] || return 0
  ws_probe_address=127.0.0.1
  if [ "$node_type" != 4 ] && [ "$listen_address" = '::' ]; then
    ws_probe_address='[::1]'
  fi
  printf '正在检查本机 WebSocket 握手...\n'
  for ws_probe_attempt in 1 2 3; do
    probe_websocket "http://$ws_probe_address:$ws_listen_port$ws_path" "$cdn_domain"
    [ "$ws_probe_status" = 101 ] && break
    if [ "$ws_probe_attempt" != 3 ]; then sleep 1; fi
  done
  if [ "$ws_probe_status" = 101 ]; then
    printf '本机 WebSocket 握手通过（HTTP 101）。\n'
  else
    printf '警告：本机 WS 检查未通过（HTTP %s，curl 状态 %s），请检查 Xray 服务、监听端口和路径。\n' \
      "$ws_probe_status" "$ws_probe_exit"
  fi
  [ "$node_type" = 4 ] || return 0
  printf '正在检查 Tunnel 域名的 TLS 和 WebSocket 回源...\n'
  probe_websocket "https://$cdn_domain$ws_path" "$cdn_domain"
  if [ "$ws_probe_status" = 101 ]; then
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

[ "$(id -u)" -eq 0 ] || fail 'Run as root.'
[ -f /etc/alpine-release ] || fail 'This installer supports Alpine Linux only.'
command -v apk >/dev/null 2>&1 || fail 'apk is required.'
command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1 \
  || fail 'OpenRC is required; the container must support OpenRC services.'
command -v supervise-daemon >/dev/null 2>&1 \
  || fail 'OpenRC supervise-daemon is required.'
[ -e /run/openrc/softlevel ] \
  || fail 'OpenRC did not boot this container; cannot guarantee service startup or persistence.'
[ ! -e "$XRAY_BIN" ] && [ ! -e "$XRAY_CONFIG" ] && [ ! -e "$XRAY_SERVICE" ] \
  || fail 'An Xray installation already exists; refusing to overwrite it.'
if ! exec 3</dev/tty; then
  fail 'An interactive terminal is required.'
fi
apk add --no-cache ca-certificates
apk add --no-cache --virtual .nat-vless-build-deps curl jq unzip
printf '正在检测 IPv4 和 IPv6 的外网 HTTPS 连通性（最长约 20 秒）...\n'
detect_address_families
select_address_family
select_node_type
printf '公网 IP 或域名（客户端/CDN 入口，与出站方式无关）：' >/dev/tty
IFS= read -r public_host <&3 || fail 'Could not read public host.'
direct_public_port=
direct_listen_port=
ws_public_port=
ws_listen_port=
if [ "$node_type" != 2 ]; then
  printf '直连服务商映射的公网 TCP 端口：' >/dev/tty
  IFS= read -r direct_public_port <&3 || fail 'Could not read direct public port.'
  printf '直连本机监听端口 [%s]：' "$direct_public_port" >/dev/tty
  IFS= read -r direct_listen_port <&3 || fail 'Could not read direct listen port.'
  direct_listen_port=${direct_listen_port:-$direct_public_port}
fi
server_name=
ws_path=
cdn_domain=
cdn_port=443
argo_token=
default_name=NAT-VLESS
if [ "$node_type" = 1 ] || [ "$node_type" = 3 ] || [ "$node_type" = 4 ]; then
  printf 'REALITY SNI [%s]：' "$DEFAULT_SNI" >/dev/tty
  IFS= read -r server_name <&3 || fail 'Could not read SNI.'
  server_name=${server_name:-$DEFAULT_SNI}
fi
if [ "$node_type" = 2 ] || [ "$node_type" = 3 ]; then
  if [ "$node_type" = 2 ]; then default_name=NAT-VLESS-WS; fi
  printf 'CDN 域名（SNI 和 WebSocket Host）：' >/dev/tty
  IFS= read -r cdn_domain <&3 || fail 'Could not read CDN domain.'
fi
if [ "$node_type" = 2 ] || [ "$node_type" = 3 ]; then
  printf 'CDN 回源服务商映射的公网 TCP 端口：' >/dev/tty
  IFS= read -r ws_public_port <&3 || fail 'Could not read CDN origin public port.'
  printf 'CDN 回源本机监听端口 [%s]：' "$ws_public_port" >/dev/tty
  IFS= read -r ws_listen_port <&3 || fail 'Could not read CDN origin listen port.'
  ws_listen_port=${ws_listen_port:-$ws_public_port}
fi
if [ "$node_type" = 4 ]; then
  printf '提示：Argo 隧道会额外运行 cloudflared，128 MB 机器尚未验证内存余量。\n'
  printf 'Tunnel 域名（公开主机名，可在连接器上线后添加路由）：' >/dev/tty
  IFS= read -r cdn_domain <&3 || fail 'Could not read Tunnel hostname.'
  printf '粘贴 Cloudflare Tunnel Token（输入不回显）：' >/dev/tty
  IFS= read -r -s argo_token <&3 || fail 'Could not read Cloudflare Tunnel token.'
  printf '\n' >/dev/tty
  ws_listen_port=2096
  printf 'Tunnel 回源本机监听端口 [%s]：' "$ws_listen_port" >/dev/tty
  IFS= read -r input_ws_port <&3 || fail 'Could not read Tunnel listen port.'
  ws_listen_port=${input_ws_port:-$ws_listen_port}
fi
printf '节点名称 [%s]：' "$default_name" >/dev/tty
IFS= read -r node_name <&3 || fail 'Could not read node name.'
node_name=${node_name:-$default_name}
exec 3<&-

[ -n "$public_host" ] || fail '公网 IP 或域名不能为空。'
validate_host "$public_host" '公网 IP 或域名'
if [ "$node_type" != 2 ]; then
  validate_port "$direct_public_port" '直连服务商映射的公网 TCP 端口'
  validate_port "$direct_listen_port" '直连本机监听端口'
  [ "$direct_listen_port" -ge 1024 ] || fail '本机监听端口必须不小于 1024（服务以 nobody 用户运行）。'
fi
if [ "$node_type" = 1 ] || [ "$node_type" = 3 ] || [ "$node_type" = 4 ]; then
  validate_hostname "$server_name" 'REALITY SNI'
fi
if [ "$node_type" = 2 ] || [ "$node_type" = 3 ] || [ "$node_type" = 4 ]; then
  validate_hostname "$cdn_domain" 'CDN 域名'
fi
if [ "$node_type" = 2 ] || [ "$node_type" = 3 ]; then
  validate_port "$ws_public_port" 'CDN 回源服务商映射的公网 TCP 端口'
  validate_port "$ws_listen_port" 'CDN 回源本机监听端口'
  [ "$ws_listen_port" -ge 1024 ] || fail 'WebSocket 本机监听端口必须不小于 1024。'
  if [ "$node_type" = 3 ]; then
    [ "$ws_public_port" != "$direct_public_port" ] \
      || fail '直连和 CDN 回源不能使用同一个公网映射端口。'
    [ "$ws_listen_port" != "$direct_listen_port" ] \
      || fail '直连和 WebSocket 不能监听同一个本机端口。'
  fi
fi
if [ "$node_type" = 4 ]; then
  validate_port "$ws_listen_port" 'Tunnel 回源本机监听端口'
  [ "$ws_listen_port" -ge 1024 ] || fail 'Tunnel 本机监听端口必须不小于 1024。'
  [ "$ws_listen_port" != "$direct_listen_port" ] \
    || fail '直连和 Tunnel WebSocket 不能监听同一个本机端口。'
  [ -n "$argo_token" ] || fail 'Cloudflare Tunnel Token 不能为空。'
  case "$argo_token" in *[[:space:]]*) fail 'Cloudflare Tunnel Token 不能包含空白字符.' ;; esac
  [ ! -e /etc/nat-vless ] && [ ! -L /etc/nat-vless ] \
    && [ ! -e /etc/init.d/cloudflared-nat-vless ] && [ ! -L /etc/init.d/cloudflared-nat-vless ] \
    || fail '已有 NAT VLESS 隧道配置或服务，拒绝覆盖。'
fi

listen_address=0.0.0.0
case "$public_host" in *:*) listen_address='::' ;; esac
if [ "$node_type" != 2 ] && command -v ss >/dev/null 2>&1 \
  && ss -Hltn "sport = :$direct_listen_port" | grep -q .; then
  fail "Local TCP port $direct_listen_port is already in use."
fi
if [ "$node_type" != 1 ] && command -v ss >/dev/null 2>&1 \
  && ss -Hltn "sport = :$ws_listen_port" | grep -q .; then
  fail "Local TCP port $ws_listen_port is already in use."
fi

case "$(uname -m)" in
  x86_64 | amd64) machine=64 ;;
  aarch64 | arm64) machine=arm64-v8a ;;
  armv7l | armv7) machine=arm32-v7a ;;
  *) fail "Unsupported architecture: $(uname -m)." ;;
esac

# Keep the archive and extracted binary on disk, not in a possible /tmp tmpfs.
install -d -m 755 /usr/local
tmp_dir=$(mktemp -d /usr/local/.nat-vless-install.XXXXXX) || fail 'Not enough disk space for installation.'
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
release="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$machine.zip"
curl -fsSL "$release" -o "$tmp_dir/xray.zip"
curl -fsSL "$release.dgst" -o "$tmp_dir/xray.zip.dgst"
expected=$(awk -F '= ' '/^SHA2-256=/ {print $2; exit}' "$tmp_dir/xray.zip.dgst")
actual=$(sha256sum "$tmp_dir/xray.zip" | awk '{print $1}')
[ -n "$expected" ] && [ "$actual" = "$expected" ] || fail 'Xray archive SHA256 mismatch.'
unzip -p "$tmp_dir/xray.zip" xray > "$tmp_dir/xray"
chmod 755 "$tmp_dir/xray"

uuid=$("$tmp_dir/xray" uuid)
random_id=$(dd if=/dev/urandom bs=8 count=1 2>/dev/null | od -An -tx1 | tr -d '[:space:]')
[ "${#random_id}" -eq 16 ] || fail 'Could not generate a random ID.'
private_key=
public_key=
short_id=
direct_enabled=0
ws_enabled=0
if [ "$node_type" = 1 ] || [ "$node_type" = 3 ] || [ "$node_type" = 4 ]; then
  direct_enabled=1
  key_output=$("$tmp_dir/xray" x25519)
  private_key=$(printf '%s\n' "$key_output" | sed -nE 's/^Private ?[Kk]ey:[[:space:]]*//p' | head -n 1)
  public_key=$(printf '%s\n' "$key_output" | sed -nE 's/^(Password( \(PublicKey\))?|Public ?[Kk]ey):[[:space:]]*//p' | head -n 1)
  [ -n "$private_key" ] && [ -n "$public_key" ] || fail 'Could not parse REALITY keypair.'
  short_id=$random_id
fi
if [ "$node_type" != 1 ]; then
  ws_enabled=1
  ws_path="/ws-$random_id"
fi

jq -n \
  --arg mode "$node_type" --arg family "$address_family" --arg path "$ws_path" \
  --arg address "$listen_address" --arg direct_port "$direct_listen_port" \
  --arg ws_port "$ws_listen_port" \
  --arg uuid "$uuid" --arg sni "$server_name" \
  --arg private_key "$private_key" --arg sid "$short_id" '
  {
    log: {loglevel: "warning"},
    inbounds: [
      (if $mode == "1" or $mode == "3" or $mode == "4" then {
        listen: $address, port: ($direct_port | tonumber), protocol: "vless",
        settings: {
          clients: [{id: $uuid, flow: "xtls-rprx-vision"}],
          decryption: "none"
        },
        streamSettings: {
        network: "raw", security: "reality",
        realitySettings: {
          show: false, target: ($sni + ":443"), xver: 0,
          serverNames: [$sni], privateKey: $private_key, shortIds: [$sid]
        }
        }
      } else empty end),
      (if $mode == "2" or $mode == "3" or $mode == "4" then {
        listen: (if $mode == "4" then "127.0.0.1" else $address end),
        port: ($ws_port | tonumber), protocol: "vless",
        settings: {clients: [{id: $uuid}], decryption: "none"},
        streamSettings: {
          network: "ws", security: "none", wsSettings: {path: $path}
        }
      } else empty end)
    ],
    outbounds: [{
      protocol: "freedom", tag: "direct",
      settings: (if $family == "3" then {} else {
        finalRules: [{
          action: "block",
          ip: [(if $family == "1" then "::/0" else "0.0.0.0/0" end)],
          blockDelay: "0"
        }]
      } end),
      streamSettings: {sockopt: ({
        domainStrategy: ({"1": "ForceIPv4", "2": "ForceIPv6", "3": "UseIP"}[$family])
      } + (if $family == "3" then {
        happyEyeballs: {
          tryDelayMs: 250, prioritizeIPv6: true, interleave: 1, maxConcurrentTry: 2
        }
      } else {} end))}
    }]
  }' > "$tmp_dir/config.json"
"$tmp_dir/xray" run -test -config "$tmp_dir/config.json"
id nobody >/dev/null 2>&1 || fail 'The nobody service user is missing.'
service_group=$(id -gn nobody)
cloudflared_bin=
if [ "$node_type" = 4 ]; then
  if command -v cloudflared >/dev/null 2>&1; then
    cloudflared_bin=$(command -v cloudflared)
    "$cloudflared_bin" tunnel run --help | grep -F -- '--token-file' >/dev/null \
      || fail '现有 cloudflared 不支持 --token-file，请先升级后重试。'
  else
    [ ! -e /usr/local/bin/cloudflared ] && [ ! -L /usr/local/bin/cloudflared ] \
      || fail '已有 cloudflared 文件，拒绝覆盖。'
    case "$(uname -m)" in
      x86_64 | amd64) cloudflare_arch=amd64 ;;
      aarch64 | arm64) cloudflare_arch=arm64 ;;
      armv7l | armv7) cloudflare_arch=armhf ;;
      *) fail "Cloudflare Tunnel does not support this architecture: $(uname -m)." ;;
    esac
    asset_name="cloudflared-linux-$cloudflare_arch"
    curl -fsSL https://api.github.com/repos/cloudflare/cloudflared/releases/latest \
      -o "$tmp_dir/cloudflared-release.json"
    cloudflared_url=$(jq -er --arg name "$asset_name" \
      '.assets[] | select(.name == $name) | .browser_download_url' \
      "$tmp_dir/cloudflared-release.json") \
      || fail 'Could not find the Cloudflare Tunnel binary for this architecture.'
    cloudflared_digest=$(jq -er --arg name "$asset_name" \
      '.assets[] | select(.name == $name) | .digest | sub("^sha256:"; "")' \
      "$tmp_dir/cloudflared-release.json") \
      || fail 'The Cloudflare Tunnel release did not provide a SHA-256 digest.'
    curl -fsSL "$cloudflared_url" -o "$tmp_dir/cloudflared"
    cloudflared_actual=$(sha256sum "$tmp_dir/cloudflared" | awk '{print $1}')
    [ "$cloudflared_actual" = "$cloudflared_digest" ] \
      || fail 'Cloudflare Tunnel binary SHA256 mismatch.'
    chmod 755 "$tmp_dir/cloudflared"
  fi
fi

# Refuse to replace files created by another process while downloading.
[ ! -e "$XRAY_BIN" ] && [ ! -e "$XRAY_CONFIG" ] && [ ! -e "$XRAY_SERVICE" ] \
  || fail 'An Xray installation appeared during setup; refusing to overwrite it.'
install -d -m 755 /usr/local/bin /usr/local/etc/xray
install -m 755 "$tmp_dir/xray" "$XRAY_BIN"
if [ "$node_type" = 4 ]; then
  if [ -z "$cloudflared_bin" ]; then
    install -m 755 "$tmp_dir/cloudflared" /usr/local/bin/cloudflared
    cloudflared_bin=/usr/local/bin/cloudflared
  fi
  addgroup -S cloudflared >/dev/null 2>&1 || true
  if ! id cloudflared >/dev/null 2>&1; then
    adduser -S -D -H -G cloudflared -s /sbin/nologin cloudflared
  fi
  install -d -m 750 -o root -g cloudflared /etc/nat-vless
  printf '%s' "$argo_token" > "$tmp_dir/cloudflared-token"
  install -m 640 -o root -g cloudflared "$tmp_dir/cloudflared-token" \
    /etc/nat-vless/cloudflared.token
  unset argo_token
fi
install -m 640 -o root -g "$service_group" "$tmp_dir/config.json" "$XRAY_CONFIG"
printf 'nat-vless-reality-v1\n' > /usr/local/etc/xray/.nat-vless-installer
chmod 600 /usr/local/etc/xray/.nat-vless-installer
cat > "$XRAY_SERVICE" <<OPENRC
#!/sbin/openrc-run
name="Xray"
description="VLESS server"
# Lower the Go heap target to trade some CPU for memory on tiny hosts.
export GOGC=50
supervisor=supervise-daemon
command=/usr/local/bin/xray
command_args="run -config /usr/local/etc/xray/config.json"
command_user=nobody:$service_group
pidfile=/run/xray.pid
required_files=/usr/local/etc/xray/config.json
OPENRC
chmod 755 "$XRAY_SERVICE"
rc-update add xray default
rc-service xray start
rc-service xray status || fail 'Xray did not start; inspect rc-service xray status.'
if [ "$node_type" = 4 ]; then
  cat > /etc/init.d/cloudflared-nat-vless <<OPENRC
#!/sbin/openrc-run
name="Cloudflare Tunnel"
description="Cloudflare Tunnel for NAT VLESS WebSocket"
supervisor=supervise-daemon
command=$cloudflared_bin
command_args="tunnel --edge-ip-version auto --no-autoupdate run --token-file /etc/nat-vless/cloudflared.token"
command_user=cloudflared:cloudflared
pidfile=/run/cloudflared-nat-vless.pid
required_files=/etc/nat-vless/cloudflared.token
OPENRC
  chmod 755 /etc/init.d/cloudflared-nat-vless
  rc-update add cloudflared-nat-vless default
  rc-service cloudflared-nat-vless start
  rc-service cloudflared-nat-vless status \
    || fail 'Cloudflare Tunnel did not start; inspect rc-service cloudflared-nat-vless status.'
fi

check_websocket_setup

case "$public_host" in
  *:*) case "$public_host" in \[*\]) ;; *) public_host="[$public_host]" ;; esac ;;
esac
encoded_name=$(jq -nr --arg value "$node_name" '$value | @uri')
encoded_direct_name=$encoded_name
encoded_ws_name=$encoded_name
direct_enabled=0
ws_enabled=0
if [ "$node_type" = 1 ] || [ "$node_type" = 3 ] || [ "$node_type" = 4 ]; then
  direct_enabled=1
fi
if [ "$node_type" != 1 ]; then
  ws_enabled=1
  encoded_path=$(jq -nr --arg value "$ws_path" '$value | @uri')
  encoded_domain=$(jq -nr --arg value "$cdn_domain" '$value | @uri')
fi
if [ "$direct_enabled" -eq 1 ] && [ "$ws_enabled" -eq 1 ]; then
  encoded_direct_name=$(jq -nr --arg value "$node_name-Direct" '$value | @uri')
  if [ "$node_type" = 4 ]; then ws_name="$node_name-Tunnel"; else ws_name="$node_name-CDN"; fi
  encoded_ws_name=$(jq -nr --arg value "$ws_name" '$value | @uri')
fi
# Clean both the release archive and temporary packages after successful start.
rm -rf "$tmp_dir"
trap - EXIT HUP INT TERM
apk del .nat-vless-build-deps || printf 'Warning: installer-only packages could not be removed.\n' >&2
printf '\nXray 服务已启动。VLESS 链接（请妥善保管）：\n'
case "$address_family" in
  1) printf '节点出站方式：仅 IPv4\n' ;;
  2) printf '节点出站方式：仅 IPv6\n' ;;
  3) printf '节点出站方式：双栈（TCP 优先 IPv6，IPv4 回退）\n' ;;
esac
if [ "$direct_enabled" -eq 1 ]; then
  printf '\n直连 VLESS 链接：\n'
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s\n' \
    "$uuid" "$public_host" "$direct_public_port" "$server_name" "$public_key" "$short_id" "$encoded_direct_name"
fi
if [ "$ws_enabled" -eq 1 ]; then
  printf '\nWebSocket VLESS 链接：\n'
  printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&type=ws&host=%s&path=%s#%s\n' \
    "$uuid" "$cdn_domain" "$cdn_port" "$encoded_domain" "$encoded_domain" "$encoded_path" "$encoded_ws_name"
  printf '\nWebSocket 回源路径：%s\n' "$ws_path"
fi
if [ "$node_type" = 2 ] || [ "$node_type" = 3 ]; then
  printf 'CDN 客户端入口：%s:%s\n' "$cdn_domain" "$cdn_port"
  printf 'CDN 域名（SNI 和 WebSocket Host）：%s\n' "$cdn_domain"
  printf '回源：将 HTTP WebSocket 转发到 %s:%s -> 本机 TCP %s。\n' \
    "$public_host" "$ws_public_port" "$ws_listen_port"
  printf '请在外部开启该域名的 CDN 代理和 WebSocket。\n'
  printf '本脚本不会修改 DNS、代理状态、回源规则或优选 IP。\n'
  printf '如果之后使用优选 CDN IP，只替换链接中的地址，SNI 和 WebSocket Host 保持不变。\n'
  printf '普通 CDN 回源是 HTTP，未配置源站证书；Cloudflare 需为该主机名设置灵活（Flexible）模式。\n'
  printf '其他网站需要完全/严格模式时，请用仅匹配此主机名的配置规则，避免改动整个域名。\n'
  printf '警告：CDN 到源站的链路是明文，随机路径不是加密或防火墙。\n'
fi
if [ "$node_type" = 4 ]; then
  print_tunnel_setup
fi
if [ "$node_type" != 2 ]; then
  printf '\n直连映射：公网 TCP %s -> 本机 TCP %s。\n' "$direct_public_port" "$direct_listen_port"
fi
if [ "$node_type" = 2 ] || [ "$node_type" = 3 ]; then
  printf 'CDN 映射：公网 TCP %s -> 本机 TCP %s。\n' "$ws_public_port" "$ws_listen_port"
fi
printf '本脚本不会修改服务商端口映射、DNS 或 Cloudflare 外部路由。\n'
