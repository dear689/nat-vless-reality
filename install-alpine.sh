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
printf '节点类型：\n  1) VLESS + REALITY + TCP（直连）\n  2) VLESS + WebSocket（供外部 CDN 回源的明文 HTTP）\n请选择 [1]：' >/dev/tty
IFS= read -r node_type <&3 || fail 'Could not read node type.'
node_type=${node_type:-1}
case "$node_type" in 1|2) ;; *) fail '节点类型只能选择 1 或 2。' ;; esac
printf '公网 IP 或域名（客户端/CDN 入口，与出站方式无关）：' >/dev/tty
IFS= read -r public_host <&3 || fail 'Could not read public host.'
printf '服务商映射的公网 TCP 端口：' >/dev/tty
IFS= read -r public_port <&3 || fail 'Could not read public port.'
printf '本机监听端口 [%s]：' "$public_port" >/dev/tty
IFS= read -r listen_port <&3 || fail 'Could not read listen port.'
listen_port=${listen_port:-$public_port}
server_name=
ws_path=
cdn_domain=
cdn_port=443
default_name=NAT-VLESS
if [ "$node_type" = 1 ]; then
  printf 'REALITY SNI [%s]：' "$DEFAULT_SNI" >/dev/tty
  IFS= read -r server_name <&3 || fail 'Could not read SNI.'
  server_name=${server_name:-$DEFAULT_SNI}
else
  default_name=NAT-VLESS-WS
  printf 'CDN 域名（SNI 和 WebSocket Host）：' >/dev/tty
  IFS= read -r cdn_domain <&3 || fail 'Could not read CDN domain.'
fi
printf '节点名称 [%s]：' "$default_name" >/dev/tty
IFS= read -r node_name <&3 || fail 'Could not read node name.'
node_name=${node_name:-$default_name}
exec 3<&-

[ -n "$public_host" ] || fail '公网 IP 或域名不能为空。'
validate_host "$public_host" '公网 IP 或域名'
validate_port "$public_port" '服务商映射的公网 TCP 端口'
validate_port "$listen_port" '本机监听端口'
[ "$listen_port" -ge 1024 ] || fail '本机监听端口必须不小于 1024（服务以 nobody 用户运行）。'
if [ "$node_type" = 1 ]; then
  validate_hostname "$server_name" 'REALITY SNI'
else
  validate_hostname "$cdn_domain" 'CDN 域名'
fi

listen_address=0.0.0.0
case "$public_host" in *:*) listen_address='::' ;; esac
if command -v ss >/dev/null 2>&1 && ss -Hltn "sport = :$listen_port" | grep -q .; then
  fail "Local TCP port $listen_port is already in use."
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
if [ "$node_type" = 1 ]; then
  key_output=$("$tmp_dir/xray" x25519)
  private_key=$(printf '%s\n' "$key_output" | sed -nE 's/^Private ?[Kk]ey:[[:space:]]*//p' | head -n 1)
  public_key=$(printf '%s\n' "$key_output" | sed -nE 's/^(Password( \(PublicKey\))?|Public ?[Kk]ey):[[:space:]]*//p' | head -n 1)
  [ -n "$private_key" ] && [ -n "$public_key" ] || fail 'Could not parse REALITY keypair.'
  short_id=$random_id
else
  ws_path="/ws-$random_id"
fi

jq -n \
  --arg mode "$node_type" --arg family "$address_family" --arg path "$ws_path" \
  --arg address "$listen_address" --argjson port "$listen_port" \
  --arg uuid "$uuid" --arg sni "$server_name" \
  --arg private_key "$private_key" --arg sid "$short_id" '
  {
    log: {loglevel: "warning"},
    inbounds: [{
      listen: $address, port: $port, protocol: "vless",
      settings: {
        clients: [(if $mode == "1" then {id: $uuid, flow: "xtls-rprx-vision"} else {id: $uuid} end)],
        decryption: "none"
      },
      streamSettings: (if $mode == "1" then {
        network: "raw", security: "reality",
        realitySettings: {
          show: false, target: ($sni + ":443"), xver: 0,
          serverNames: [$sni], privateKey: $private_key, shortIds: [$sid]
        }
      } else {network: "ws", security: "none", wsSettings: {path: $path}} end)
    }],
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

# Refuse to replace files created by another process while downloading.
[ ! -e "$XRAY_BIN" ] && [ ! -e "$XRAY_CONFIG" ] && [ ! -e "$XRAY_SERVICE" ] \
  || fail 'An Xray installation appeared during setup; refusing to overwrite it.'
install -d -m 755 /usr/local/bin /usr/local/etc/xray
install -m 755 "$tmp_dir/xray" "$XRAY_BIN"
install -m 640 -o root -g "$service_group" "$tmp_dir/config.json" "$XRAY_CONFIG"
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

case "$public_host" in
  *:*) case "$public_host" in \[*\]) ;; *) public_host="[$public_host]" ;; esac ;;
esac
encoded_name=$(jq -nr --arg value "$node_name" '$value | @uri')
if [ "$node_type" = 2 ]; then
  encoded_path=$(jq -nr --arg value "$ws_path" '$value | @uri')
  encoded_domain=$(jq -nr --arg value "$cdn_domain" '$value | @uri')
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
if [ "$node_type" = 1 ]; then
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s\n' \
    "$uuid" "$public_host" "$public_port" "$server_name" "$public_key" "$short_id" "$encoded_name"
else
  printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&type=ws&host=%s&path=%s#%s\n' \
    "$uuid" "$cdn_domain" "$cdn_port" "$encoded_domain" "$encoded_domain" "$encoded_path" "$encoded_name"
  printf '\nWebSocket 回源路径：%s\n' "$ws_path"
  printf 'CDN 客户端入口：%s:%s\n' "$cdn_domain" "$cdn_port"
  printf 'CDN 域名（SNI 和 WebSocket Host）：%s\n' "$cdn_domain"
  printf '回源：将 HTTP WebSocket 转发到 %s:%s -> 本机 TCP %s。\n' \
    "$public_host" "$public_port" "$listen_port"
  printf '请在外部开启该域名的 CDN 代理和 WebSocket。\n'
  printf '本脚本不会修改 DNS、代理状态、回源规则或优选 IP。\n'
  printf '如果之后使用优选 CDN IP，只替换链接中的地址，SNI 和 WebSocket Host 保持不变。\n'
  printf 'CDN 到源站仍是明文 HTTP WebSocket；本脚本没有配置源站证书或 Full（严格）模式。\n'
  printf '警告：CDN 到源站的链路是明文，随机路径不是加密或防火墙。\n'
fi
printf '\n请确认服务商已将公网 TCP 端口 %s 映射到本机 TCP 端口 %s。\n' "$public_port" "$listen_port"
printf '本脚本不会修改服务商端口映射或防火墙规则。\n'
