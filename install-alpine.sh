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

validate_route_domain() {
  route_validation_domain=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$route_validation_domain" in
    domain:*) route_validation_domain=${route_validation_domain#domain:} ;;
    full:*) route_validation_domain=${route_validation_domain#full:} ;;
  esac
  validate_hostname "$route_validation_domain" "$2"
  case "$route_validation_domain" in
    *[!0-9.]*) ;;
    *) fail "$2 需要填写域名，不能填写 IP 地址。" ;;
  esac
  route_domain_old_ifs=$IFS
  IFS=.
  set -- $route_validation_domain
  IFS=$route_domain_old_ifs
  for route_domain_label do
    [ "${#route_domain_label}" -le 63 ] \
      || fail '分流域名的每一段不能超过 63 个字符。'
  done
}

normalize_route_domains() {
  route_domain_input=$(printf '%s' "$route_domains" \
    | tr '[:upper:]' '[:lower:]' | tr ',[:space:]' '\n')
  route_domains=
  while IFS= read -r route_rule || [ -n "$route_rule" ]; do
    [ -n "$route_rule" ] || continue
    case "$route_rule" in
      domain:*) route_prefix=domain:; route_domain=${route_rule#domain:} ;;
      full:*) route_prefix=full:; route_domain=${route_rule#full:} ;;
      *) route_prefix=domain:; route_domain=$route_rule ;;
    esac
    validate_route_domain "$route_domain" '分流域名'
    route_rule=$route_prefix$route_domain
    if ! printf '%s\n' "$route_domains" | grep -Fxq "$route_rule"; then
      if [ -n "$route_domains" ]; then
        route_domains="$route_domains
$route_rule"
      else
        route_domains=$route_rule
      fi
    fi
  done <<ROUTE_DOMAINS
$route_domain_input
ROUTE_DOMAINS
  [ -n "$route_domains" ] || fail '启用分流时至少填写一个域名。'
}

validate_route_auth() {
  if [ -z "$route_user" ]; then
    [ -z "$route_password" ] || fail 'SOCKS5 密码不能在用户名为空时单独填写。'
    return 0
  fi
  route_user_bytes=$(printf '%s' "$route_user" | wc -c)
  route_password_bytes=$(printf '%s' "$route_password" | wc -c)
  [ "$route_user_bytes" -le 255 ] \
    && [ "$route_password_bytes" -ge 1 ] && [ "$route_password_bytes" -le 255 ] \
    || fail 'SOCKS5 用户名和密码各需 1 到 255 个 UTF-8 字节。'
}

parse_route_vless() {
  # Parse secrets through stdin; never place the import link in process arguments.
  route_vless_outbound=$(printf '%s' "$route_vless_link" | jq -Rsec '
    def require($ok; $message):
      if $ok then . else error($message) end;
    def decode_uri:
      [explode[] | if . < 128 then [.] | implode else [.] | implode | @uri end]
      | join("")
      | require((gsub("%[0-9A-Fa-f]{2}"; "") | contains("%") | not);
          "百分号编码无效。")
      | [scan("%[0-9A-Fa-f]{2}|.") | if startswith("%") then
          .[1:] | ascii_downcase | explode
          | map(if . <= 57 then . - 48 else . - 87 end)
          | .[0] * 16 + .[1]
        else explode[] end]
      | reduce .[] as $byte (
          {out: [], need: 0, value: 0, minimum: 0};
          if .need == 0 then
            if $byte < 128 then .out += [$byte]
            elif $byte >= 194 and $byte <= 223 then
              .need = 1 | .value = ($byte - 192) | .minimum = 128
            elif $byte >= 224 and $byte <= 239 then
              .need = 2 | .value = ($byte - 224) | .minimum = 2048
            elif $byte >= 240 and $byte <= 244 then
              .need = 3 | .value = ($byte - 240) | .minimum = 65536
            else error("UTF-8 编码无效。") end
          else
            require($byte >= 128 and $byte <= 191; "UTF-8 编码无效。")
            | .value = (.value * 64 + $byte - 128) | .need -= 1
            | if .need == 0 then
                require(.value >= .minimum and .value <= 1114111
                  and (.value < 55296 or .value > 57343); "UTF-8 编码无效。")
                | .out += [.value]
              else . end
          end)
      | require(.need == 0; "UTF-8 编码不完整。")
      | .out | implode
      | require(all(explode[]; . >= 32 and (. < 127 or . > 159));
          "链接参数不能包含控制字符。");
    def dns_name:
      length >= 1 and length <= 253
      and all(split(".")[]; length <= 63
        and test("^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$"));
    def ipv4:
      test("^([0-9]{1,3}\\.){3}[0-9]{1,3}$")
      and all(split(".")[]; tonumber <= 255
        and (length == 1 or (startswith("0") | not)));
    def ipv6:
      (if contains(".") then
        split(":")[-1] as $tail
        | if $tail | ipv4 then rtrimstr($tail) + "0:0" else "" end
      else . end)
      | split("::") as $halves
      | if ($halves | length) == 1 then
          split(":") | length == 8 and all(.[]; test("^[A-Fa-f0-9]{1,4}$"))
        elif ($halves | length) == 2 then
          all($halves[]; . == "" or all(split(":")[]; test("^[A-Fa-f0-9]{1,4}$")))
          and ([$halves[] | split(":")[] | select(length > 0)] | length < 8)
        else false end;
    def endpoint:
      if contains(":") then ipv6
      elif test("^[0-9.]+$") then ipv4 else dns_name end;
    def sni_name:
      dns_name and (test("^[0-9.]+$") | not);

    require(length <= 16384; "VLESS 链接过长。")
    | split("#")[0]
    | require(all(explode[]; . > 32 and . != 127); "请粘贴完整的一行 VLESS 链接。")
    | (capture("^vless://(?<id>[^@/?#]+)@(?<host>\\[[^\\]]+\\]|[^:/?#@]+):(?<port>[0-9]+)/?\\?(?<query>.*)$")
        // error("VLESS 链接格式无效，需要地址、端口和参数。")) as $uri
    | ($uri.id | decode_uri | ascii_downcase) as $id
    | require($id | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$");
        "VLESS 用户 ID 必须是 UUID。")
    | ($uri.host | ltrimstr("[") | rtrimstr("]") | decode_uri | ascii_downcase) as $address
    | require($address | endpoint; "VLESS 服务器地址无效。")
    | require(($uri.host | startswith("[")) == ($address | contains(":"));
        "只有 IPv6 地址需要使用方括号。")
    | ($uri.port | tonumber) as $port
    | require($port >= 1 and $port <= 65535; "VLESS 端口需要在 1 到 65535 之间。")
    | (reduce ($uri.query | split("&")[]) as $item ({};
        ($item | capture("^(?<key>[^=]+)=(?<value>.*)$")
          // error("VLESS 查询参数需要使用名称=值。")) as $pair
        | ($pair.key | decode_uri) as $key
        | require(has($key) | not; "VLESS 链接含有重复参数。")
        | .[$key] = ($pair.value | decode_uri))) as $q
    | require(all($q | keys[]; IN("encryption", "security", "type", "flow", "sni",
        "fp", "pbk", "sid", "spx", "alpn", "host", "path", "headerType",
        "allowInsecure", "insecure")); "链接含有暂不支持的参数，请使用标准 REALITY/TLS 链接。")
    | require(($q.encryption // "none") == "none"; "暂不支持此 VLESS encryption 设置。")
    | require(($q.security == "reality" or $q.security == "tls");
        "分流上游必须启用 REALITY 或 TLS，不能使用明文链接。")
    | require(all(["allowInsecure", "insecure"][];
        . as $key | ($q | has($key) | not) or ($q[$key] | IN("0", "false")));
        "不能关闭 TLS 证书校验。")
    | require(($q.headerType // "none") | IN("", "none"); "暂不支持 TCP 伪装头。")
    | ($q.type // "tcp" | if . == "tcp" then "raw" else . end) as $network
    | require($network == "raw" or ($network == "ws" and $q.security == "tls");
        "只支持 REALITY/TCP、TLS/TCP 和 TLS/WebSocket。")
    | ($q.flow // "") as $flow
    | require($flow == "" or ($flow == "xtls-rprx-vision" and $network == "raw");
        "此传输方式不支持链接中的 flow。")
    | ($q.sni // (if $q.security == "tls" then $address else "" end)) as $sni
    | require($sni | sni_name; "请在链接中提供有效的 TLS/REALITY SNI 域名。")
    | ($q.fp // "chrome") as $fp
    | require($fp | IN("chrome", "firefox", "safari", "ios", "android", "edge",
        "360", "qq", "random", "randomized"); "暂不支持此 TLS 指纹。")
    | require($network == "ws" or (($q.host // "") == "" and ($q.path // "") == "");
        "TCP 链接不能包含 WebSocket Host 或路径。")
    | {
        protocol: "vless", tag: "custom-upstream",
        settings: {vnext: [{address: $address, port: $port, users: [
          {id: $id, encryption: "none"}
          + (if $flow != "" then {flow: $flow} else {} end)
        ]}]},
        streamSettings: {network: $network, security: $q.security}
      }
    | if $q.security == "reality" then
        require(($q.pbk // "") | test("^[A-Za-z0-9_-]{43}$"); "REALITY 公钥格式无效。")
        | ($q.sid // "" | ascii_downcase) as $sid
        | require(($sid | test("^[0-9a-f]{0,16}$")) and ($sid | length % 2 == 0);
            "REALITY Short ID 需要 0 到 16 位偶数长度十六进制字符。")
        | require(($q.alpn // "") == ""; "暂不支持 REALITY 自定义 ALPN。")
        | ($q.spx // "/") as $spider
        | require($spider | startswith("/"); "REALITY SpiderX 必须以 / 开头。")
        | .streamSettings.realitySettings = {
            show: false, serverName: $sni, fingerprint: $fp,
            publicKey: $q.pbk, shortId: $sid, spiderX: $spider
          }
      else
        require(all(["pbk", "sid", "spx"][]; . as $key | ($q[$key] // "") == "");
            "TLS 链接不能携带 REALITY 参数。")
        | .streamSettings.tlsSettings = {
            serverName: $sni, fingerprint: $fp, allowInsecure: false
          }
        | if ($q.alpn // "") != "" then
            ($q.alpn | split(",")) as $alpn
            | require(all($alpn[]; test("^[A-Za-z0-9./_-]{1,32}$")); "ALPN 参数无效。")
            | .streamSettings.tlsSettings.alpn = $alpn
          else . end
      end
    | if $network == "ws" then
        ($q.host // $sni) as $host
        | ($q.path // "/") as $path
        | require($host | dns_name; "WebSocket Host 需要是有效域名。")
        | require($path | startswith("/"); "WebSocket 路径必须以 / 开头。")
        | .streamSettings.wsSettings = {host: $host, path: $path}
      else . end
  ') || fail "无法导入 VLESS 分流上游，未安装配置。"
  route_vless_link=
}

select_routing_mode() {
  routing_mode=1
  route_domains=
  route_host=
  route_port=
  route_user=
  route_password=
  route_vless_link=
  route_vless_outbound=
  while :; do
    printf '流量分流：\n  1) 普通模式（全部使用本机出站）\n  2) 自定义域名分流（指定域名走 SOCKS5 上游）\n  3) 自定义域名走 VLESS 加密上游（粘贴链接）\n请选择 [1]：' >/dev/tty
    IFS= read -r routing_mode <&3 || fail '无法读取分流模式。'
    routing_mode=${routing_mode:-1}
    case "$routing_mode" in
      1) return 0 ;;
      2|3) break ;;
      *) printf '请输入 1、2 或 3。\n' ;;
    esac
  done
  set +x
  printf '需要分流的域名（空格或逗号分隔，裸域名包含子域，full: 表示精确匹配）：' >/dev/tty
  IFS= read -r route_domains <&3 || fail '无法读取分流域名。'
  normalize_route_domains
  if [ "$routing_mode" = 3 ]; then
    printf '支持 REALITY/TCP、TLS/TCP 和 TLS/WebSocket；NAT 落地使用公网映射端口。\n'
    printf '粘贴完整 vless:// 链接（输入不回显）：' >/dev/tty
    IFS= read -r -s route_vless_link <&3 || fail '无法读取 VLESS 上游链接。'
    printf '\n' >/dev/tty
    parse_route_vless
    printf 'VLESS 上游已解析，稍后随完整配置一起检查；连通性仍需实测。\n'
    return 0
  fi
  printf 'SOCKS5 上游 IP 或域名（不带协议和端口）：' >/dev/tty
  IFS= read -r route_host <&3 || fail '无法读取 SOCKS5 上游地址。'
  case "$route_host" in
    \[*\]) route_host=${route_host#\[}; route_host=${route_host%\]} ;;
  esac
  validate_host "$route_host" 'SOCKS5 上游地址'
  printf 'SOCKS5 上游端口 [1080]：' >/dev/tty
  IFS= read -r route_port <&3 || fail '无法读取 SOCKS5 上游端口。'
  route_port=${route_port:-1080}
  validate_port "$route_port" 'SOCKS5 上游端口'
  printf 'SOCKS5 用户名（无需认证则留空）：' >/dev/tty
  IFS= read -r route_user <&3 || fail '无法读取 SOCKS5 用户名。'
  if [ -n "$route_user" ]; then
    printf 'SOCKS5 密码（输入不回显）：' >/dev/tty
    IFS= read -r -s route_password <&3 || fail '无法读取 SOCKS5 密码。'
    printf '\n' >/dev/tty
  fi
  validate_route_auth
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
select_routing_mode
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

export XRAY_ROUTE_USER="$route_user"
export XRAY_ROUTE_PASSWORD="$route_password"
export XRAY_ROUTE_VLESS="$route_vless_outbound"
jq -n \
  --arg mode "$node_type" --arg family "$address_family" --arg path "$ws_path" \
  --arg address "$listen_address" --arg direct_port "$direct_listen_port" \
  --arg ws_port "$ws_listen_port" \
  --arg routing_mode "${routing_mode:-1}" --arg route_domains "${route_domains:-}" \
  --arg route_host "${route_host:-}" --arg route_port "${route_port:-}" \
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
    }
  | if $routing_mode == "2" or $routing_mode == "3" then
      .inbounds |= map(. + {
        sniffing: {
          enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: false
        }
      })
      | .outbounds += [(if $routing_mode == "3" then
          env.XRAY_ROUTE_VLESS | fromjson
        else {
          protocol: "socks", tag: "custom-upstream",
          settings: {
            servers: [{
              address: $route_host, port: ($route_port | tonumber)
            } + (if (env.XRAY_ROUTE_USER // "") != "" then {
              users: [{user: env.XRAY_ROUTE_USER, pass: env.XRAY_ROUTE_PASSWORD}]
            } else {} end)]
          }
        } end)]
      | .routing = {
          domainStrategy: "AsIs",
          rules: [{
            type: "field",
            domain: ($route_domains | split("\n") | map(select(length > 0))),
            outboundTag: "custom-upstream"
          }]
        }
    else . end' > "$tmp_dir/config.json"
unset XRAY_ROUTE_USER XRAY_ROUTE_PASSWORD XRAY_ROUTE_VLESS route_user route_password route_vless_outbound
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
if [ "${routing_mode:-1}" = 2 ] || [ "${routing_mode:-1}" = 3 ]; then
  if [ "$routing_mode" = 3 ]; then
    printf '自定义域名分流：已启用；命中域名走 VLESS 加密上游，其余流量走本机。\n'
  else
    printf '自定义域名分流：已启用；命中域名走 SOCKS5 上游，其余流量走本机。\n'
    printf '分流上游：%s:%s（账号密码不回显）。\n' "$route_host" "$route_port"
    printf 'SOCKS5 链路和认证不加密；HTTPS 内容仍使用 TLS。UDP/QUIC 需要上游支持 UDP。\n'
  fi
  printf '命中域名的上游连接失败时，不会回落到本机出口。\n'
  printf '分流域名规则：\n%s\n' "$route_domains"
  printf '本机 IPv4/IPv6 出站选择只约束普通流量；上游连接使用系统可达的地址族。\n'
else
  printf '流量分流：普通模式，全部使用本机出站。\n'
fi
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
