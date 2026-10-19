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
printf 'Node type:\n  1) VLESS + REALITY + TCP (direct)\n  2) VLESS + WebSocket (plain HTTP origin for external CDN)\nChoose [1]: ' >/dev/tty
IFS= read -r node_type <&3 || fail 'Could not read node type.'
node_type=${node_type:-1}
case "$node_type" in 1|2) ;; *) fail 'Choose node type 1 or 2.' ;; esac
printf 'Public IP or hostname: ' >/dev/tty
IFS= read -r public_host <&3 || fail 'Could not read public host.'
printf 'Provider-mapped public TCP port: ' >/dev/tty
IFS= read -r public_port <&3 || fail 'Could not read public port.'
printf 'Local listen port [%s]: ' "$public_port" >/dev/tty
IFS= read -r listen_port <&3 || fail 'Could not read listen port.'
listen_port=${listen_port:-$public_port}
server_name=
ws_path=
default_name=NAT-VLESS
if [ "$node_type" = 1 ]; then
  printf 'REALITY SNI [%s]: ' "$DEFAULT_SNI" >/dev/tty
  IFS= read -r server_name <&3 || fail 'Could not read SNI.'
  server_name=${server_name:-$DEFAULT_SNI}
else
  default_name=NAT-VLESS-WS
  printf 'CDN mode: no domain/certificate setup; an HTTP WebSocket path will be generated.\n' >/dev/tty
fi
printf 'Node name [%s]: ' "$default_name" >/dev/tty
IFS= read -r node_name <&3 || fail 'Could not read node name.'
node_name=${node_name:-$default_name}
exec 3<&-

[ -n "$public_host" ] || fail 'Public host is required.'
printf '%s' "$public_host" | grep -Eq '^([A-Za-z0-9.:-]+|\[[A-Fa-f0-9:]+\])$' \
  || fail 'Public host must be an IP address or DNS hostname without a scheme or port.'
for port in "$public_port" "$listen_port"; do
  printf '%s' "$port" | grep -Eq '^[1-9][0-9]{0,4}$' \
    || fail 'TCP ports must be numbers between 1 and 65535.'
  [ "$port" -le 65535 ] || fail 'TCP ports must be between 1 and 65535.'
done
[ "$listen_port" -ge 1024 ] || fail 'Local listen port must be at least 1024 when running as nobody.'
if [ "$node_type" = 1 ]; then
  printf '%s' "$server_name" | grep -Eq '^[A-Za-z0-9.-]+$' || fail 'Invalid SNI hostname.'
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

apk add --no-cache ca-certificates
apk add --no-cache --virtual .nat-vless-build-deps curl jq unzip
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
  --arg mode "$node_type" --arg path "$ws_path" \
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
    outbounds: [{protocol: "freedom", tag: "direct"}]
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
fi
# Clean both the release archive and temporary packages after successful start.
rm -rf "$tmp_dir"
trap - EXIT HUP INT TERM
apk del .nat-vless-build-deps || printf 'Warning: installer-only packages could not be removed.\n' >&2
printf '\nXray service is active. VLESS link (keep private):\n'
if [ "$node_type" = 1 ]; then
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s\n' \
    "$uuid" "$public_host" "$public_port" "$server_name" "$public_key" "$short_id" "$encoded_name"
else
  printf 'vless://%s@%s:%s?encryption=none&security=none&type=ws&path=%s#%s\n' \
    "$uuid" "$public_host" "$public_port" "$encoded_path" "$encoded_name"
  printf '\nWebSocket origin path: %s\n' "$ws_path"
  printf 'CDN setup is external. This link is an origin template, NOT a TLS/CDN-ready node.\n'
  printf 'Client: set CDN address/edge port, enable TLS, set your domain as SNI and WS Host; keep UUID and path.\n'
  printf 'Origin: forward HTTP WebSocket traffic to the mapped public TCP port; no TLS certificate is installed.\n'
  printf 'WARNING: CDN-to-origin traffic is plaintext; a random path is not encryption or a firewall.\n'
fi
printf '\nEnsure the provider maps public TCP port %s to local TCP port %s.\n' "$public_port" "$listen_port"
printf 'This installer does not change provider mappings or firewall rules.\n'
