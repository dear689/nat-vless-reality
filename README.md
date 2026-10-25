# NAT VPS VLESS installer

Interactive installers for a **new Debian/Ubuntu or Alpine NAT VPS**. Detect Internet connectivity, choose the server's IPv4/IPv6 outbound policy, then choose one node type. The script starts Xray and prints one private `vless://` client import link:

1. **Direct: VLESS + REALITY + TCP + Vision.** The default REALITY target is Apple's `gateway.icloud.com`.
2. **CDN-ready VLESS + WebSocket + client TLS.** The script asks for the CDN hostname and generates a directly importable link with that hostname as the address, SNI, and WebSocket Host. The CDN, DNS, proxy status, origin rule, and preferred edge IP remain external.

Only one inbound is installed, not both. The Alpine variant targets **at least 128 MiB RAM / 1 GiB disk** and avoids Python, additional reverse proxies, panels, and Xray geodata. This is a minimum target, not a guarantee under every workload; 64 MiB is not supported as a deployment target.

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

Next choose node type **1** (direct, default) or **2** (CDN), then enter the origin public IP/hostname, provider-mapped **public TCP port**, corresponding **local TCP listen port**, and custom node name. Mode 1 asks for a REALITY SNI. Mode 2 asks for the CDN hostname and uses client TLS port 443 by default. The public and local ports may differ on a NAT VPS. Keep the printed `vless://` link private: it contains credentials for the node.

The provider's external TCP port must map to the local listen port, and its firewall must allow that traffic. For an IPv6 origin endpoint, enter its IPv6 address without square brackets; the generated link will add them.

## IPv4 and IPv6 egress

The outbound choice controls how **Xray connects to destination websites**. It is independent of the address used to connect to your node. You can keep an IPv4 NAT entry address while selecting IPv6-only or dual-stack egress. Only one origin endpoint and one import link are needed.

- **IPv4 only:** resolve and connect using IPv4, and block destination IPv6 literals.
- **IPv6 only:** resolve and connect using IPv6, and block destination IPv4 literals. IPv4-only destinations will not work; the script does not provide NAT64 or another translation service.
- **Dual-stack:** allow IPv4 and IPv6 destinations. TCP connections prefer IPv6 and can fall back to IPv4; UDP uses the resolved addresses without the same connection fallback. This does not combine both families into one connection or guarantee that every website uses IPv6.

Detection tests actual HTTPS egress rather than treating an assigned address or a default route as proof of connectivity. It does not discover provider NAT mappings or prove that an incoming public port is reachable. The script does not enable or disable IPv6 system-wide, change kernel settings, or add a tunnel or background network monitor.

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

## Scope and testing

- Supported targets: Debian/Ubuntu with systemd, or Alpine with working OpenRC; root privileges, an interactive terminal, supported CPU architecture, and outbound access to GitHub and package repositories. Alpine supports x86_64, aarch64, and armv7l.
- The Alpine script avoids Python, OpenSSL and geodata, uses a disk-backed temporary directory instead of a potentially RAM-backed `/tmp`, and removes installer-only packages after startup (`curl` remains if already installed explicitly as shown above). It runs Xray with `GOGC=50`, trading some CPU for lower Go heap growth. This does not impose a hard memory cap. Debian/Ubuntu have different system overhead; the 128 MiB live measurements below apply only to the tested Alpine container.
- For a 128 MB trial, check `rc-service xray status`, `grep VmRSS /proc/$(pidof xray)/status`, and the container's memory usage after making a real client connection. Leave room for system processes and multiple connections; a successful boot alone is not a stability test.
- Existing Xray configuration is left untouched; the installer exits before setup in that case.
- Direct mode was installed on a clean Alpine 3.24.2 x86_64 Podman NAT container with a 128 MiB cgroup limit and 1 GiB disk. The user confirmed client connectivity and service startup after a provider restart. One post-install sample showed 63.3 MiB container memory, 33.1 MiB Xray RSS, 38.1 MiB disk usage, and zero memory-limit/OOM events. These are point-in-time measurements, not long-term or high-concurrency guarantees.
- The direct-mode measurements do not establish CDN-mode memory usage. Local regression tests cover both configuration/link generators and outbound-family choices, and can validate configurations plus loopback WS forwarding with an Xray binary. They do not install services or validate real DNS/CDN rules. The new outbound-family choices need live testing on a provider host; fresh Debian/Ubuntu deployment remains unverified.
- Before using on another host, confirm its NAT mapping and firewall rules; avoid using this on a machine with a setup you need to preserve.

## Regression tests

Requires Python 3, a POSIX shell, and `jq`. Uses synthetic credentials and local temporary files only:

```sh
python3 -m unittest discover -s tests -v
```

Set `XRAY_TEST_BIN` to an Xray executable to also run configuration validation and loopback WS forwarding. `INSTALLER_TEST_SHELL` and `JQ_TEST_BIN` can specify the shell and jq executable explicitly. No production configuration or credentials are loaded.
