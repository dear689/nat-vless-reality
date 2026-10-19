# NAT VPS VLESS + REALITY installer

Interactive installers for a **new Debian/Ubuntu or Alpine NAT VPS**. They install Xray, configure a single VLESS + REALITY/TCP inbound, start the service, and print a client import link. The Alpine variant is designed to avoid Python and Xray geodata on small machines.

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
apk add --no-cache curl
curl -fsSLo install-alpine.sh https://raw.githubusercontent.com/dear689/nat-vless-reality/main/install-alpine.sh
cat install-alpine.sh
sh install-alpine.sh
```

Run the Alpine commands as root. The script requires **OpenRC to be booted**, not just installed, and exits before making changes otherwise. Some provider Podman images do not run OpenRC or do not persist container changes across rebuilds. Check with `test -e /run/openrc/softlevel && echo OpenRC-ready` before installing; if there is no output, this variant is not suitable for that image. A local TCP listen port below 1024 is not supported because the service runs as `nobody`.

Enter the public IP/hostname, provider-mapped **public TCP port**, corresponding **local TCP listen port**, REALITY SNI, and node name when prompted. The public and local ports may differ on a NAT VPS. The script then prints a `vless://` link for your client. Keep the link private: it contains credentials for the node.

The provider's external TCP port must map to the local listen port, and its firewall must allow that traffic. The script uses a direct outbound by default. For IPv6-only endpoints, enter the IPv6 address without square brackets; the generated link will add them.

## Scope and testing

- Supported targets: Debian/Ubuntu with systemd, or Alpine with working OpenRC; root privileges, an interactive terminal, supported CPU architecture, and outbound access to GitHub and package repositories. Alpine supports x86_64, aarch64, and armv7l.
- A 128 MB RAM / 1 GB disk NAT VPS is **not guaranteed** to run Xray comfortably: actual memory headroom and provider container limitations need a live test. The Alpine script avoids Python and geodata files, but still downloads the official release archive temporarily.
- Existing Xray configuration is left untouched; the installer exits before setup in that case.
- The Debian/Ubuntu script syntax, generated configuration, and `xray run -test` were checked against Xray 26.3.27. The Alpine installer has not been tested on a live provider Podman image yet. Fresh-host installation and client connectivity remain unverified for both installers.
- Before using on another host, confirm its NAT mapping and firewall rules; avoid using this on a machine with a setup you need to preserve.
