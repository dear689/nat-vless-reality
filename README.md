# NAT VPS VLESS + REALITY installer

Interactive installer for a **new Debian/Ubuntu NAT VPS** with systemd. It installs Xray, configures a single VLESS + REALITY/TCP inbound, starts the systemd service, and prints a client import link.

It does **not** change your provider's port mapping, firewall, or an existing Xray installation. It refuses to overwrite an existing Xray binary/configuration/service.

## Install

Log in as `root` (or use `sudo`) on the **target VPS**. Download and inspect the script before running it:

```bash
curl -fsSLo install.sh https://raw.githubusercontent.com/dear689/nat-vless-reality/main/install.sh
less install.sh
sudo bash install.sh
```

Enter the public IP/hostname, provider-mapped **public TCP port**, corresponding **local TCP listen port**, REALITY SNI, and node name when prompted. The public and local ports may differ on a NAT VPS. The script then prints a `vless://` link for your client. Keep the link private: it contains credentials for the node.

The provider's external TCP port must map to the local listen port, and its firewall must allow that traffic. The script uses a direct outbound by default. For IPv6-only endpoints, enter the IPv6 address without square brackets; the generated link will add them.

## Scope and testing

- Supported target: Debian/Ubuntu, systemd, `apt-get`, root privileges, an interactive terminal, and outbound access to GitHub and package repositories.
- Existing Xray configuration is left untouched; the installer exits before setup in that case.
- Script syntax, generated configuration, and `xray run -test` were checked against Xray 26.3.27. A fresh-host end-to-end installation and client connection have **not** been tested yet.
- Before using on another host, confirm its NAT mapping and firewall rules; avoid using this on a machine with a setup you need to preserve.
