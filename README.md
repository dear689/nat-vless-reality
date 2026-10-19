# NAT VPS VLESS installer

Interactive installers for a **new Debian/Ubuntu or Alpine NAT VPS**. Choose one node type, start Xray, and receive a private `vless://` client import link:

1. **Direct: VLESS + REALITY + TCP + Vision.** The default REALITY target is Apple's `gateway.icloud.com`.
2. **External CDN origin: VLESS + WebSocket, without origin TLS.** No domain, certificate, reverse proxy, or CDN account is requested or configured by the script. A random WS path is generated and included in the link. You configure the CDN and edit the imported client yourself.

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

Choose **1** (default) or **2**, then enter the public IP/hostname, provider-mapped **public TCP port**, corresponding **local TCP listen port**, and node name. Only mode 1 asks for a REALITY SNI; mode 2 does not ask for a domain. The public and local ports may differ on a NAT VPS. The script then prints a `vless://` link for your client. Keep the link private: it contains credentials for the node.

The provider's external TCP port must map to the local listen port, and its firewall must allow that traffic. The script uses a direct outbound by default. For IPv6-only endpoints, enter the IPv6 address without square brackets; the generated link will add them.

## External CDN mode

Mode 2 serves **plain HTTP WebSocket** on the local listen port, with VLESS authentication and a random path. It has no Vision flow, REALITY keys, WS Host restriction, or certificate. The output link is an **origin template**, not a ready-to-use TLS/CDN node:

- Import the link and keep the generated UUID and WS path unchanged.
- In your client, change the server address to your CDN hostname or preferred CDN edge IP, select its public TLS port (for example, 443), enable TLS, and set SNI and WS Host to your own proxied hostname.
- Configure your CDN externally to send HTTP WebSocket requests to the VPS public IP and provider-mapped **external** TCP port. Preserve the WS path and WebSocket upgrade. A CDN's supported client-facing ports are separate from the NAT origin port.
- This origin cannot accept HTTPS. For Cloudflare, a Full/Full (strict) connection directly to this origin will fail; configure HTTP to this hostname's origin externally. The installer does not change any zone-wide or hostname-specific SSL settings.
- TLS on the client-to-CDN leg does **not** encrypt the CDN-to-origin leg in this mode. The random path is not encryption or a firewall. Use a separately configured TLS reverse proxy if encrypted origin traffic is required; that is outside this lightweight installer.

No DNS records, CDN rules, certificates, or client settings are changed automatically. Do not import this template unchanged and expect CDN TLS to work.

## Scope and testing

- Supported targets: Debian/Ubuntu with systemd, or Alpine with working OpenRC; root privileges, an interactive terminal, supported CPU architecture, and outbound access to GitHub and package repositories. Alpine supports x86_64, aarch64, and armv7l.
- The Alpine script avoids Python, OpenSSL and geodata, uses a disk-backed temporary directory instead of a potentially RAM-backed `/tmp`, and removes installer-only packages after startup (`curl` remains if already installed explicitly as shown above). It runs Xray with `GOGC=50`, trading some CPU for lower Go heap growth. This does not impose a hard memory cap. Debian/Ubuntu have different system overhead; the 128 MiB live measurements below apply only to the tested Alpine container.
- For a 128 MB trial, check `rc-service xray status`, `grep VmRSS /proc/$(pidof xray)/status`, and the container's memory usage after making a real client connection. Leave room for system processes and multiple connections; a successful boot alone is not a stability test.
- Existing Xray configuration is left untouched; the installer exits before setup in that case.
- Direct mode was installed on a clean Alpine 3.24.2 x86_64 Podman NAT container with a 128 MiB cgroup limit and 1 GiB disk. The user confirmed client connectivity and service startup after a provider restart. One post-install sample showed 63.3 MiB container memory, 33.1 MiB Xray RSS, 38.1 MiB disk usage, and zero memory-limit/OOM events. These are point-in-time measurements, not long-term or high-concurrency guarantees.
- CDN mode needs a separate live provider/CDN test; the direct-mode measurements do not establish CDN-mode memory usage. Local regression tests cover both configuration/link generators, and can validate configurations plus loopback WS forwarding with an Xray binary. They do not install services or validate real DNS/CDN rules. Fresh Debian/Ubuntu deployment remains unverified.
- Before using on another host, confirm its NAT mapping and firewall rules; avoid using this on a machine with a setup you need to preserve.

## Regression tests

Requires Python 3, a POSIX shell, and `jq`. Uses synthetic credentials and local temporary files only:

```sh
python3 -m unittest discover -s tests -v
```

Set `XRAY_TEST_BIN` to an Xray executable to also run configuration validation and loopback WS forwarding. `INSTALLER_TEST_SHELL` and `JQ_TEST_BIN` can specify the shell and jq executable explicitly. No production configuration or credentials are loaded.
