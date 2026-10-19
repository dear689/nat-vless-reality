#!/bin/sh
set -eu

XRAY_BIN=/usr/local/bin/xray
XRAY_CONFIG=/usr/local/etc/xray/config.json
XRAY_SERVICE=/etc/init.d/xray
DEFAULT_SNI=www.microsoft.com

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
printf 'Public IP or hostname: ' >/dev/tty
IFS= read -r public_host <&3 || fail 'Could not read public host.'
printf 'Provider-mapped public TCP port: ' >/dev/tty
IFS= read -r public_port <&3 || fail 'Could not read public port.'
printf 'Local listen port [%s]: ' "$public_port" >/dev/tty
IFS= read -r listen_port <&3 || fail 'Could not read listen port.'
listen_port=${listen_port:-$public_port}
printf 'REALITY SNI [%s]: ' "$DEFAULT_SNI" >/dev/tty
IFS= read -r server_name <&3 || fail 'Could not read SNI.'
server_name=${server_name:-$DEFAULT_SNI}
printf 'Node name [NAT-VLESS]: ' >/dev/tty
IFS= read -r node_name <&3 || fail 'Could not read node name.'
node_name=${node_name:-NAT-VLESS}
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
printf '%s' "$server_name" | grep -Eq '^[A-Za-z0-9.-]+$' || fail 'Invalid SNI hostname.'

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

key_output=$("$tmp_dir/xray" x25519)
private_key=$(printf '%s\n' "$key_output" | sed -nE 's/^Private ?[Kk]ey:[[:space:]]*//p' | head -n 1)
public_key=$(printf '%s\n' "$key_output" | sed -nE 's/^(Password( \(PublicKey\))?|Public ?[Kk]ey):[[:space:]]*//p' | head -n 1)
[ -n "$private_key" ] && [ -n "$public_key" ] || fail 'Could not parse REALITY keypair.'
uuid=$("$tmp_dir/xray" uuid)
short_id=$(dd if=/dev/urandom bs=8 count=1 2>/dev/null | od -An -tx1 | tr -d '[:space:]')
[ "${#short_id}" -eq 16 ] || fail 'Could not generate a REALITY short ID.'

jq -n \
  --arg address "$listen_address" --argjson port "$listen_port" \
  --arg uuid "$uuid" --arg sni "$server_name" \
  --arg private_key "$private_key" --arg sid "$short_id" '
  {
    log: {loglevel: "warning"},
    inbounds: [{
      listen: $address, port: $port, protocol: "vless",
      settings: {clients: [{id: $uuid, flow: "xtls-rprx-vision"}], decryption: "none"},
      streamSettings: {
        network: "raw", security: "reality",
        realitySettings: {
          show: false, target: ($sni + ":443"), xver: 0,
          serverNames: [$sni], privateKey: $private_key, shortIds: [$sid]
        }
      }
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
description="VLESS REALITY server"
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
# Clean both the release archive and temporary packages after successful start.
rm -rf "$tmp_dir"
trap - EXIT HUP INT TERM
apk del .nat-vless-build-deps || printf 'Warning: installer-only packages could not be removed.\n' >&2
printf '\nXray service is active. VLESS link (keep private):\n'
printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s\n' \
  "$uuid" "$public_host" "$public_port" "$server_name" "$public_key" "$short_id" "$encoded_name"
printf '\nEnsure the provider maps public TCP port %s to local TCP port %s.\n' "$public_port" "$listen_port"
printf 'This installer does not change provider mappings or firewall rules.\n'
