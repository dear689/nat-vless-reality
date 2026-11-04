# NAT VPS VLESS installer

Interactive installers for a **new Debian/Ubuntu or Alpine NAT VPS**. Detect Internet connectivity, choose the server's IPv4/IPv6 outbound policy, then choose a node type and optional domain routing. The script starts Xray and prints one or two private `vless://` client import links:

1. **Direct only: VLESS + REALITY + TCP + Vision.** The default REALITY target is Apple's `gateway.icloud.com`.
2. **CDN only: VLESS + WebSocket + client TLS.**
3. **Direct + CDN:** two separate Xray inbounds and links. Requires two distinct provider port mappings.
4. **Direct + Cloudflare Tunnel:** direct REALITY plus a loopback-only WebSocket inbound reached through a persistent named Cloudflare Tunnel (sometimes called Argo Tunnel). Requires the Tunnel token and a public-hostname route, which can be added after the connector comes online.

Combined modes share one UUID and outbound policy while keeping separate listeners, transport settings, and links. The Cloudflare Tunnel mode installs and enables `cloudflared` as a separate service. Its additional memory use has not been measured on the script's 128 MiB Alpine test target; do not assume it will fit a 128 MiB VPS.

The Alpine variant targets **at least 128 MiB RAM / 1 GiB disk** for Xray-only modes and avoids Python, panels, and Xray geodata. This is a minimum target, not a guarantee under every workload; 64 MiB is not supported as a deployment target.

It does **not** change your provider's port mapping, firewall, or an existing Xray installation. It refuses to overwrite an existing Xray binary/configuration/service.

## Install

Log in as `root` (or use `sudo`) on the **target VPS**. Download and inspect the script before running it:

Debian/Ubuntu (systemd):

```bash
curl -fsSLo install.sh https://raw.githubusercontent.com/dear689/nat-vless-reality/main/install.sh
less install.sh
sudo bash install.sh
```

Alpine (OpenRC, including an Alpine Podman image **only if OpenRC services work inside it**):

```sh
apk add --no-cache ca-certificates curl
curl -fsSLo install-alpine.sh https://raw.githubusercontent.com/dear689/nat-vless-reality/main/install-alpine.sh
cat install-alpine.sh
sh install-alpine.sh
```

Run the Alpine commands as root. The script requires **OpenRC to be booted**, not just installed, and exits before making changes otherwise. Some provider Podman images do not run OpenRC or do not persist container changes across rebuilds. Check with `test -e /run/openrc/softlevel && echo OpenRC-ready` before installing; if there is no output, this variant is not suitable for that image. A local TCP listen port below 1024 is not supported because the service runs as `nobody`.

The installer first checks IPv4 and IPv6 Internet access using bounded HTTPS requests. It then asks for the outbound policy: **1) IPv4 only**, **2) IPv6 only**, or **3) dual-stack**. Dual-stack is the default when both families work; otherwise the working family is the default. An unavailable family cannot be selected. If neither probe succeeds, the installer stops so you can check routing, DNS, and connectivity.

Next select a mode with the **1/2/3/4 installation menu**; press Enter for direct-only, or retry after an invalid choice. No separate post-install control panel is installed. Direct uses one provider-mapped public TCP port and one local listen port. CDN-only uses the origin mapping and CDN hostname. Direct + CDN asks for two distinct provider-mapped ports and two distinct local ports; a single mapped port cannot serve both inbounds. Direct + Cloudflare Tunnel asks for the direct mapping, the Tunnel hostname, a token, and a local WebSocket port. Keep the printed `vless://` links private: they contain credentials for the node.

The separate Chinese routing menu defaults to **1) ordinary mode**. Choose **2) custom domains via SOCKS5** to enter your own domains and upstream address, port, and optional credentials. Both choices work with every node type; no domain list is bundled or downloaded.

The provider's external TCP port must map to the matching local listen port, and its firewall must allow that traffic. For an IPv6 origin endpoint, enter its IPv6 address without square brackets; the generated link will add them.

## Startup and uninstall

Startup is automatic: Debian/Ubuntu enables `xray.service`, and Alpine adds `xray` to OpenRC's `default` runlevel. Mode 4 also enables `cloudflared-nat-vless` in the same service manager. No additional startup command is required.

To uninstall on **the target VPS as root**, the same command works on both supported platforms:

```sh
(nat_uninstall=$(mktemp) && trap 'rm -f "$nat_uninstall"' EXIT && curl -fsSL https://raw.githubusercontent.com/dear689/nat-vless-reality/main/uninstall.sh -o "$nat_uninstall" && sh "$nat_uninstall" --yes)
```

This immediately stops the project's services, removes their startup entries, and deletes Xray's binary, node configuration, service files, and the local Tunnel token. Omit `--yes` for an interactive confirmation. Legacy installations without the new ownership marker are recognized through the expected service and, on systemd, the node configuration. Additional Xray template instances must be handled before uninstalling their shared binary. Unrecognized installations and redirected file paths are refused before any changes.

Only the known project files are removed; nonempty directories and other files are retained. Generic `cloudflared` binaries/packages, package repositories, system tools and service accounts are retained because the installer may have reused them. The dedicated Tunnel service is removed and will no longer run. Cloudflare-side Tunnel/DNS/CDN configuration and provider NAT mappings must be removed separately if no longer needed. The command can be run again safely and adds no permanent management process.

## IPv4 and IPv6 egress

The outbound choice controls how **Xray connects directly to destination websites**. It is independent of the address used to connect to your node. You can keep an IPv4 NAT entry address while selecting IPv6-only or dual-stack egress. Optional domain routing sends only matching traffic through a separate SOCKS5 outbound; the ordinary policy below continues to apply to other destinations.

- **IPv4 only:** resolve and connect using IPv4, and block destination IPv6 literals.
- **IPv6 only:** resolve and connect using IPv6, and block destination IPv4 literals. IPv4-only destinations will not work; the script does not provide NAT64 or another translation service.
- **Dual-stack:** allow IPv4 and IPv6 destinations. TCP connections prefer IPv6 and can fall back to IPv4; UDP uses the resolved addresses without the same connection fallback. This does not combine both families into one connection or guarantee that every website uses IPv6.

Detection tests actual HTTPS egress rather than treating an assigned address or a default route as proof of connectivity. It does not discover provider NAT mappings or prove that an incoming public port is reachable. Outbound-family selection does not enable or disable IPv6 system-wide, change kernel settings, or add a tunnel or background network monitor. The separate Cloudflare Tunnel service is installed only when mode 4 is selected.

## Optional domain routing

Choose **2** in the routing menu to send selected domains through a SOCKS5 server you already operate on another host. Enter its IP or hostname, port (default `1080`), username, and password. Leave the username empty for an upstream that does not require authentication; otherwise both credentials must be between 1 and 255 UTF-8 bytes. The password prompt is hidden. This version accepts SOCKS5 connection details, not VLESS/VMess/Shadowsocks import links, and does not install a SOCKS5 server on the other host.

Enter domains separated by spaces or English commas:

```text
example.com full:exact.example.net domain:another.example.org
```

Bare `example.com` is normalized to `domain:example.com` and matches that domain and its subdomains. `full:exact.example.net` matches only the exact hostname. Rules are lowercased and deduplicated. URLs, paths, ports, wildcard syntax, and IP addresses are rejected; use ASCII/Punycode hostnames. An enabled list cannot be empty. All domains are supplied by you; the installer has no preset AI/service rules.

The existing `direct` outbound stays first. Unmatched traffic uses the selected IPv4/IPv6 policy, and matched traffic uses `custom-upstream` through SOCKS5. Both inbounds in a combined mode share these rules. A failed upstream connection fails the matching request instead of falling back to ordinary egress. TCP and UDP matches use the same outbound, but UDP needs a SOCKS5 server with working UDP ASSOCIATE support and reachable relay ports.

The upstream address must be reachable from the NAT host. Its connection is independent of the ordinary outbound policy: choosing IPv6-only ordinary egress can still use an IPv4 SOCKS5 endpoint when the operating system has working IPv4. A genuinely IPv6-only host needs a reachable IPv6 upstream. SOCKS5 itself, including its authentication, is unencrypted on the network; destination HTTPS content retains its own TLS encryption.

Domain routing enables HTTP/TLS/QUIC sniffing with `routeOnly: false` on the VLESS inbounds. A recognizable hostname selects the route and replaces the original destination, so an IP resolved incorrectly on the client is not forwarded unchanged to the SOCKS5 upstream. Matching requests send the domain to the upstream for resolution; ordinary requests continue through `direct` with the selected address-family policy. Sniffed ordinary traffic is also resolved by the node, so client-pinned destination IPs may be replaced. ECH or traffic without a usable hostname may prevent matching. This also does not guarantee that a service will accept the upstream IP.

Ordinary mode leaves sniffing and routing absent from the generated configuration. Enabling routing adds only Xray configuration: no extra resident process, geodata download, or Alpine Python dependency. Credentials are written into the protected Xray configuration, passed to its generator through the environment instead of command arguments, and not included in the printed links or routing summary. Startup and uninstall use the existing service and commands.

## CDN mode

Mode 2 serves **plain HTTP WebSocket** on the local listen port, with VLESS authentication and a random path. It has no Vision flow, REALITY keys, or origin certificate. The script asks for one CDN hostname and generates a client link like:

```text
vless://UUID@cdn.example.com:443?encryption=none&security=tls&sni=cdn.example.com&fp=chrome&type=ws&host=cdn.example.com&path=%2Fws-random#NAT-VLESS-WS
```

Before importing it, configure the CDN hostname externally:

- Create the DNS record and enable proxying/CDN service for the hostname.
- Enable WebSocket support and forward requests to the NAT VPS origin public address and provider-mapped **external** TCP port. The provider must map that port to the local listen port shown by the installer.
- The client-facing CDN port (`443` in the generated link) and the NAT origin port are separate. If the provider port is non-standard, configure an explicit CDN origin-port rule, tunnel, or equivalent upstream mapping; the installer does not create that rule.
- Keep the generated UUID and WS path unchanged. If you later select a preferred CDN edge IP, replace only the link address in the client; keep the CDN hostname as SNI and WebSocket Host.
- The client-to-CDN leg uses TLS on port 443. The CDN-to-origin leg is still plaintext HTTP WebSocket. This script does not install an origin certificate or configure Cloudflare Full/Full (strict).
- For Cloudflare, this HTTP origin needs Flexible encryption mode for the node hostname. If other hostnames use Full or Full (strict), scope the Flexible setting to this hostname with a Configuration Rule rather than changing the zone-wide mode.

No DNS records, CDN rules, certificates, proxy status, or preferred edge IPs are changed automatically.

## Cloudflare Tunnel mode

Create a **remotely managed named Tunnel** in Cloudflare first. Enter the intended public hostname in the installer and paste the tunnel token only into the interactive hidden prompt. If the dashboard requires an online connector before configuring routes, run the installer first, then add the route. Its service URL must be `http://127.0.0.1:<Tunnel WS local port>` (default `2096`), including `http://`. Leave the route's path field blank; keep the generated random WS path in the client link. The script does not modify Cloudflare DNS or Tunnel ingress rules.

The script installs `cloudflared` (or reuses an existing binary that supports `--token-file`), stores the token in `/etc/nat-vless/cloudflared.token` with root/service-group-only access, and enables a least-privilege service. It refuses to overwrite its existing Tunnel configuration or service and leaves other Tunnel configuration directories alone. The WebSocket inbound binds only to `127.0.0.1`; it does not need a second public NAT mapping.

Both installers print a Chinese dashboard checklist with the exact public hostname, the complete `http://127.0.0.1:<port>` service URL, and the generated client WS path on separate lines for copying. It explains which route field to leave blank and what to enter if the dashboard separates protocol and URL. The Tunnel token is never echoed in this checklist.

TLS terminates at the Cloudflare edge, which must have a valid certificate covering the public hostname. Cloudflare's connection to `cloudflared` is encrypted separately, while `cloudflared` connects to Xray over loopback HTTP. **This local HTTP listener needs no origin certificate.** Unlike ordinary CDN-to-origin forwarding, the zone's Flexible/Full/Full (strict) setting does not change the Tunnel service URL or force this local connection to use HTTPS. Do not treat switching the entire zone to Flexible as a Tunnel prerequisite. See Cloudflare's [HTTPS origin troubleshooting guide](https://developers.cloudflare.com/tunnel/troubleshooting/https-origins/).

The host still needs outbound connectivity to Cloudflare Tunnel endpoints (TCP or UDP port 7844). The connector uses `--edge-ip-version auto` independently of Xray's outbound choice, so it can also run on an IPv6-only host. A running connector service does not prove that the public-hostname route is correct; test the generated link after confirming the dashboard route. Cloudflare Tunnel supports WebSockets. This mode means Cloudflare Tunnel, not Argo Smart Routing.

After service startup, WS modes check the local listener using an HTTP/1.1 WebSocket upgrade. Tunnel mode also checks the public hostname over HTTPS with certificate verification enabled. HTTP `101` confirms the WS handshake, not VLESS authentication or destination Internet access. These bounded checks bypass environment proxies. A failed check reports its HTTP/curl status without deleting services or withholding the links; this also allows the initial installation to finish before you create the dashboard route. The checks run only during installation and add no permanent process or runtime dependency.

## Scope and testing

- Supported targets: Debian/Ubuntu with systemd, or Alpine with working OpenRC; root privileges, an interactive terminal, supported CPU architecture, and outbound access to GitHub and package repositories. Alpine supports x86_64, aarch64, and armv7l.
- The Alpine script avoids Python, OpenSSL and geodata, uses a disk-backed temporary directory instead of a potentially RAM-backed `/tmp`, and removes installer-only packages after startup (`curl` remains if already installed explicitly as shown above). It runs Xray with `GOGC=50`, trading some CPU for lower Go heap growth. This does not impose a hard memory cap. Debian/Ubuntu have different system overhead; the 128 MiB live measurements below apply only to the tested Alpine container.
- For a 128 MB trial, check `rc-service xray status`, `grep VmRSS /proc/$(pidof xray)/status`, and the container's memory usage after making a real client connection. Leave room for system processes and multiple connections; a successful boot alone is not a stability test.
- Existing Xray configuration is left untouched; the installer exits before setup in that case.
- Direct mode was installed on a clean Alpine 3.24.2 x86_64 Podman NAT container with a 128 MiB cgroup limit and 1 GiB disk. The user confirmed client connectivity and service startup after a provider restart. One post-install sample showed 63.3 MiB container memory, 33.1 MiB Xray RSS, 38.1 MiB disk usage, and zero memory-limit/OOM events. These are point-in-time measurements, not long-term or high-concurrency guarantees.
- The direct-mode measurements do not establish CDN, Cloudflare Tunnel, or optional domain-routing memory usage. Local regression tests cover the four-mode menu, configuration/link generators, outbound-family choices, optional routing input, and Alpine link output after removing installer-only dependencies. With an Xray binary they validate all four modes' configurations plus loopback WS forwarding in modes 2, 3, and 4. Optional routing tests run a real VLESS/WS client-server chain with an authenticated SOCKS5 fixture and separate IPv4/IPv6 origins, checking suffix/exact domain rules, sniffed HTTP Host routing, unaffected ordinary traffic, and upstream failure without direct fallback. They do not install services or validate real DNS, CDN, Tunnel tokens, dashboard routes, UDP relaying, or provider-to-provider routing. The new combined modes, Cloudflare Tunnel service, and optional routing need live testing on a provider host; fresh Debian/Ubuntu deployment remains unverified.
- Before using on another host, confirm its NAT mapping and firewall rules; avoid using this on a machine with a setup you need to preserve.

## Regression tests

Requires Python 3, a POSIX shell, and `jq`. Uses synthetic credentials and local temporary files only:

```sh
python3 -m unittest discover -s tests -v
```

Set `XRAY_TEST_BIN` to an Xray executable to also run configuration validation, loopback WS forwarding, and the optional SOCKS5 routing chain. `INSTALLER_TEST_SHELL` and `JQ_TEST_BIN` can specify the shell and jq executable explicitly. No production configuration or credentials are loaded.
