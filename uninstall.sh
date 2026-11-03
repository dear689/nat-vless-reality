#!/bin/sh
set -eu

fail() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

assume_yes=0
case "$#" in
  0) ;;
  1)
    case "$1" in
      --yes|-y) assume_yes=1 ;;
      *) fail '用法：sh uninstall.sh [--yes]' ;;
    esac
    ;;
  *) fail '用法：sh uninstall.sh [--yes]' ;;
esac
[ "$(id -u)" -eq 0 ] || fail '请使用 root 运行。'

if [ -f /etc/alpine-release ]; then
  platform=alpine
  command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1 \
    || fail '未找到 OpenRC 服务管理工具。'
  xray_service=/etc/init.d/xray
  tunnel_service=/etc/init.d/cloudflared-nat-vless
elif [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  platform=systemd
  xray_service=/etc/systemd/system/xray.service
  tunnel_service=/etc/systemd/system/cloudflared-nat-vless.service
else
  fail '仅支持 Alpine/OpenRC 或 Debian、Ubuntu/systemd。'
fi

# Refuse redirected paths before stopping services or removing any files.
check_path() {
  checked_path=$1
  while [ "$checked_path" != / ]; do
    [ ! -L "$checked_path" ] || fail "发现符号链接，停止卸载：$checked_path"
    checked_path=${checked_path%/*}
    checked_path=${checked_path:-/}
  done
}

for target in \
  /usr/local/bin/xray /usr/local/etc/xray/config.json \
  /usr/local/etc/xray/.nat-vless-installer \
  /etc/nat-vless/cloudflared.token "$xray_service" "$tunnel_service"; do
  check_path "$target"
done
if [ "$platform" = systemd ]; then
  for target in \
    /etc/systemd/system/xray@.service \
    /etc/systemd/system/xray.service.d/10-donot_touch_single_conf.conf \
    /etc/systemd/system/xray@.service.d/10-donot_touch_single_conf.conf; do
    check_path "$target"
  done
fi

xray_found=0
tunnel_found=0
if [ -e /usr/local/bin/xray ] || [ -e /usr/local/etc/xray/config.json ] \
  || [ -e /usr/local/etc/xray/.nat-vless-installer ] || [ -e "$xray_service" ]; then
  xray_found=1
  if [ -e "$xray_service" ]; then
    if [ "$platform" = alpine ]; then
      grep -Eq '^description="VLESS( REALITY)? server"$' "$xray_service" \
        && grep -Fxq 'command=/usr/local/bin/xray' "$xray_service" \
        && grep -Fxq 'command_args="run -config /usr/local/etc/xray/config.json"' "$xray_service" \
        && grep -Fq 'command_user=nobody:' "$xray_service" \
        || fail 'Xray 服务已被其他程序替换或修改，未做任何修改。'
    else
      grep -Fxq 'ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json' "$xray_service" \
        || fail 'Xray 服务已被其他程序替换或修改，未做任何修改。'
    fi
  fi
  if [ -f /usr/local/etc/xray/.nat-vless-installer ]; then
    grep -Fxq 'nat-vless-reality-v1' /usr/local/etc/xray/.nat-vless-installer \
      || fail '安装标记无法识别，未做任何修改。'
  elif [ "$platform" = alpine ]; then
    [ -f "$xray_service" ] || fail '未识别为本项目的旧版 Xray 服务，未做任何修改。'
  else
    [ -f "$xray_service" ] \
      && grep -Fxq 'ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json' "$xray_service" \
      || fail '未识别为本项目的旧版 Xray 服务，未做任何修改。'
    # Legacy systemd installs have no marker; inspect JSON without printing secrets.
    python3 - /usr/local/etc/xray/config.json <<'PY' \
      || fail 'Xray 配置不符合本项目结构，未做任何修改。'
import json
import re
import sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        config = json.load(f)
    inbound = config["inbounds"]
    outbound = config["outbounds"]
    assert 1 <= len(inbound) <= 2
    assert all(item["protocol"] == "vless" for item in inbound)
    assert len(outbound) == 1
    assert outbound[0]["protocol"] == "freedom" and outbound[0]["tag"] == "direct"
    assert set(config) == {"log", "inbounds", "outbounds"}
    assert config["log"] == {"loglevel": "warning"}
    for item in inbound:
        clients = item["settings"]["clients"]
        assert len(clients) == 1 and item["settings"]["decryption"] == "none"
        stream = item["streamSettings"]
        if stream["security"] == "reality":
            assert stream["network"] in ("raw", "tcp")
            assert clients[0]["flow"] == "xtls-rprx-vision"
            assert stream["realitySettings"]["show"] is False
            assert len(stream["realitySettings"]["shortIds"]) == 1
        else:
            assert stream["network"] == "ws" and stream["security"] == "none"
            assert "flow" not in clients[0]
            assert re.fullmatch(r"/ws-[0-9a-f]{16}", stream["wsSettings"]["path"])
except (OSError, ValueError, KeyError, TypeError, AssertionError):
    sys.exit(1)
PY
  fi
fi
if [ -e "$tunnel_service" ]; then
  grep -Fq 'Cloudflare Tunnel for NAT VLESS WebSocket' "$tunnel_service" \
    && grep -Fq -- '--token-file /etc/nat-vless/cloudflared.token' "$tunnel_service" \
    || fail 'Tunnel 服务不符合本项目结构，未做任何修改。'
  tunnel_found=1
elif [ -e /etc/nat-vless/cloudflared.token ] && [ "$xray_found" -eq 0 ]; then
  fail '发现无对应服务的 Tunnel Token，无法确认归属，未做任何修改。'
fi

if [ "$xray_found" -eq 0 ] && [ "$tunnel_found" -eq 0 ]; then
  printf '未发现本项目安装，无需卸载。\n'
  exit 0
fi
if [ "$platform" = systemd ] && [ "$xray_found" -eq 1 ]; then
  loaded_instances=$(systemctl list-units --all --full --plain --no-legend 'xray@*.service') \
    || fail '无法检查其他 Xray 实例，未做任何修改。'
  installed_instances=$(systemctl list-unit-files --no-legend 'xray@*.service') \
    || fail '无法检查 Xray 自启实例，未做任何修改。'
  if printf '%s\n%s\n' "$loaded_instances" "$installed_instances" \
    | grep -Eq '^xray@[^[:space:]]+\.service[[:space:]]'; then
    fail '发现其他 Xray 模板实例共用内核，请先处理这些实例再卸载。'
  fi
fi
printf '将卸载本机 NAT VLESS 节点、配置和专用 Argo 服务，并取消它们的开机自启。\n'
if [ "$assume_yes" -ne 1 ]; then
  printf '确认卸载？输入 y 继续 [y/N]：'
  IFS= read -r answer || exit 1
  case "$answer" in y|Y) ;; *) printf '已取消。\n'; exit 0 ;; esac
fi

stop_service() {
  service_name=$1
  service_file=$2
  [ -e "$service_file" ] || return 0
  if [ "$platform" = systemd ]; then
    systemctl stop "$service_name.service" || fail "无法停止 $service_name，保留所有文件。"
    systemctl disable "$service_name.service" || fail "无法取消 $service_name 自启，保留所有文件。"
  else
    status_code=0
    rc-service "$service_name" status >/dev/null 2>&1 || status_code=$?
    if [ "$status_code" -ne 3 ]; then
      rc-service "$service_name" stop || fail "无法停止 $service_name，保留所有文件。"
      status_code=0
      rc-service "$service_name" status >/dev/null 2>&1 || status_code=$?
      [ "$status_code" -eq 3 ] || fail "无法确认 $service_name 已停止，保留所有文件。"
    fi
    for runlevel in /etc/runlevels/*; do
      [ -e "$runlevel/$service_name" ] || [ -L "$runlevel/$service_name" ] || continue
      rc-update del "$service_name" "${runlevel##*/}" \
        || fail "无法取消 $service_name 自启，保留所有文件。"
    done
  fi
}
if [ "$tunnel_found" -eq 1 ]; then
  stop_service cloudflared-nat-vless "$tunnel_service"
fi
if [ "$xray_found" -eq 1 ]; then
  stop_service xray "$xray_service"
fi

if [ "$tunnel_found" -eq 1 ] || [ "$xray_found" -eq 1 ]; then
  rm -f -- "$tunnel_service" /etc/nat-vless/cloudflared.token
  rmdir /etc/nat-vless 2>/dev/null || true
fi
if [ "$xray_found" -eq 1 ]; then
  rm -f -- "$xray_service" /usr/local/bin/xray \
    /usr/local/etc/xray/config.json /usr/local/etc/xray/.nat-vless-installer
  rmdir /usr/local/etc/xray 2>/dev/null || true
  if [ "$platform" = systemd ]; then
    rm -f -- /etc/systemd/system/xray@.service \
      /etc/systemd/system/xray.service.d/10-donot_touch_single_conf.conf \
      /etc/systemd/system/xray@.service.d/10-donot_touch_single_conf.conf
    rmdir /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d 2>/dev/null || true
  fi
fi
if [ "$platform" = systemd ]; then
  systemctl daemon-reload
  systemctl reset-failed xray.service cloudflared-nat-vless.service 2>/dev/null || true
fi
printf '卸载完成，可以重新运行安装脚本。\n'
printf '共享 cloudflared 程序、系统工具和系统账户已保留；本项目服务已停止并取消自启。\n'
printf 'Cloudflare 控制台中的 Tunnel、DNS 和 CDN 回源规则请按需手动删除。\n'
