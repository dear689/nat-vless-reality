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
  /usr/local/etc/xray/.nat-vless-resources \
  /etc/nat-vless/cloudflared.token "$xray_service" "$tunnel_service" \
  /run/xray.pid /run/cloudflared-nat-vless.pid \
  /root/nat-vless-node.txt /root/install-alpine.sh /root/install.sh; do
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

resources_file=/usr/local/etc/xray/.nat-vless-resources
resources_found=0
owned_binary=0
owned_package=0
owned_user=0
owned_group=0
owned_repo=0
owned_key=0
owned_xray_user=0
owned_xray_group=0
if [ -e "$resources_file" ]; then
  [ -f "$resources_file" ] || fail '资源清单不是普通文件，未做任何修改。'
  first_resource=1
  while IFS= read -r resource || [ -n "$resource" ]; do
    if [ "$first_resource" -eq 1 ]; then
      [ "$resource" = nat-vless-resources-v1 ] || fail '资源清单无法识别，未做任何修改。'
      first_resource=0
      continue
    fi
    case "$resource" in
      cloudflared-binary) owned_binary=1 ;;
      cloudflared-package) owned_package=1 ;;
      cloudflared-user) owned_user=1 ;;
      cloudflared-group) owned_group=1 ;;
      cloudflared-repo) owned_repo=1 ;;
      cloudflared-key) owned_key=1 ;;
      xray-user) owned_xray_user=1 ;;
      xray-group) owned_xray_group=1 ;;
      *) fail '资源清单含未知条目，未做任何修改。' ;;
    esac
  done < "$resources_file"
  [ "$first_resource" -eq 0 ] || fail '资源清单为空，未做任何修改。'
  resources_found=1
fi
if [ "$owned_binary" -eq 1 ]; then check_path /usr/local/bin/cloudflared; fi
if [ "$owned_repo" -eq 1 ]; then check_path /etc/apt/sources.list.d/cloudflared.list; fi
if [ "$owned_key" -eq 1 ]; then check_path /usr/share/keyrings/cloudflare-main.gpg; fi

check_pid_file() {
  pid_file=$1
  [ -e "$pid_file" ] || return 0
  [ -f "$pid_file" ] || fail "PID 文件无法识别，未做任何修改：$pid_file"
  checked_pid=$(cat "$pid_file")
  case "$checked_pid" in ''|*[!0-9]*) fail "PID 文件无法识别：$pid_file" ;; esac
  [ "$checked_pid" -gt 0 ] || fail "PID 文件无法识别：$pid_file"
  if kill -0 "$checked_pid" 2>/dev/null; then
    fail "发现仍在运行的进程，未清理其文件：$pid_file"
  fi
}

check_tree() {
  check_path "$1"
  tree_links=$(find "$1" -type l -print) || fail "无法检查目录：$1"
  [ -z "$tree_links" ] || fail "目录包含符号链接，停止卸载：$1"
}

stage_found=0
stage_paths=
for stage in /usr/local/.nat-vless-install.*; do
  [ -e "$stage" ] || [ -L "$stage" ] || continue
  check_path "$stage/.nat-vless-stage"
  [ -d "$stage" ] && [ -f "$stage/.nat-vless-stage" ] || continue
  [ "$(cat "$stage/.nat-vless-stage")" = nat-vless-stage-v1 ] || continue
  case "${stage##*/}" in
    .nat-vless-install.??????) ;;
    *) fail "暂存目录名称无法识别，停止卸载：$stage" ;;
  esac
  case "${stage##*/}" in *[!A-Za-z0-9.-]*) fail "暂存目录名称无法识别：$stage" ;; esac
  check_tree "$stage"
  check_pid_file "$stage/installer.pid"
  stage_found=1
  stage_paths="$stage_paths$stage
"
done
recovery_paths=
for recovery in /root/nat-vless-recovery-*; do
  [ -e "$recovery" ] || [ -L "$recovery" ] || continue
  check_path "$recovery/.nat-vless-recovery"
  [ -d "$recovery" ] && [ -f "$recovery/.nat-vless-recovery" ] || continue
  [ "$(cat "$recovery/.nat-vless-recovery")" = nat-vless-recovery-v1 ] || continue
  case "${recovery##*/}" in
    *[!A-Za-z0-9.-]*) fail "备份目录名称无法识别：$recovery" ;;
  esac
  check_tree "$recovery"
  recovery_paths="$recovery_paths$recovery
"
done
build_deps_found=0
if [ "$platform" = alpine ] && command -v apk >/dev/null 2>&1 \
  && apk info -e .nat-vless-build-deps >/dev/null 2>&1; then
  build_deps_found=1
fi

xray_found=0
tunnel_found=0
if [ -e /usr/local/bin/xray ] || [ -e /usr/local/etc/xray/config.json ] \
  || [ -e /usr/local/etc/xray/.nat-vless-installer ] || [ -e "$xray_service" ] \
  || [ "$resources_found" -eq 1 ]; then
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
  elif [ "$resources_found" -eq 1 ]; then
    :
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

if [ "$xray_found" -eq 0 ] && [ "$tunnel_found" -eq 0 ] \
  && [ "$stage_found" -eq 0 ] && [ "$build_deps_found" -eq 0 ] \
  && [ -z "$recovery_paths" ]; then
  printf '未发现本项目安装，无需卸载。\n'
  exit 0
fi
if [ "$xray_found" -eq 1 ] && [ ! -e "$xray_service" ]; then
  check_pid_file /run/xray.pid
  if command -v pidof >/dev/null 2>&1 && pidof xray >/dev/null 2>&1; then
    fail '发现无对应服务的 Xray 进程，未做任何修改。'
  fi
fi
if [ "$tunnel_found" -eq 1 ] || [ "$xray_found" -eq 1 ]; then
  if [ ! -e "$tunnel_service" ]; then check_pid_file /run/cloudflared-nat-vless.pid; fi
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
if [ "$xray_found" -eq 1 ]; then
  for other_service in /etc/init.d/* /etc/systemd/system/*.service /usr/lib/systemd/system/*.service /lib/systemd/system/*.service; do
    [ -f "$other_service" ] || continue
    [ "$other_service" != "$xray_service" ] || continue
    [ "$other_service" != /etc/systemd/system/xray@.service ] || continue
    if grep -Fq /usr/local/bin/xray "$other_service"; then
      fail '其他服务正在使用本项目 Xray 程序，请先处理该服务再卸载。'
    fi
  done
fi
for service_name in xray cloudflared-nat-vless; do
  if [ "$platform" = alpine ]; then
    for runlevel in /etc/runlevels/*; do
      [ -e "$runlevel/$service_name" ] || [ -L "$runlevel/$service_name" ] || continue
      check_path "$runlevel"
    done
  else
    for wants_dir in /etc/systemd/system/*.wants /etc/systemd/system/*.requires; do
      [ -e "$wants_dir/$service_name.service" ] || [ -L "$wants_dir/$service_name.service" ] || continue
      check_path "$wants_dir"
    done
  fi
done
printf '将卸载本机 NAT VLESS 节点、配置、专用 Argo 服务和可识别的安装残留，并取消开机自启。\n'
if [ "$assume_yes" -ne 1 ]; then
  printf '确认卸载？输入 y 继续 [y/N]：'
  IFS= read -r answer || exit 1
  case "$answer" in y|Y) ;; *) printf '已取消。\n'; exit 0 ;; esac
fi

stop_service() {
  service_name=$1
  service_file=$2
  if [ "$platform" = systemd ]; then
    if [ -e "$service_file" ]; then
      systemctl stop "$service_name.service" || fail "无法停止 $service_name，保留所有文件。"
      systemctl disable "$service_name.service" || fail "无法取消 $service_name 自启，保留所有文件。"
    else
      for wants_dir in /etc/systemd/system/*.wants /etc/systemd/system/*.requires; do
        [ -e "$wants_dir/$service_name.service" ] || [ -L "$wants_dir/$service_name.service" ] || continue
        check_path "$wants_dir"
        rm -f -- "$wants_dir/$service_name.service"
      done
    fi
  else
    if [ -e "$service_file" ]; then
      status_code=0
      rc-service "$service_name" status >/dev/null 2>&1 || status_code=$?
      if [ "$status_code" -ne 3 ]; then
        rc-service "$service_name" stop || fail "无法停止 $service_name，保留所有文件。"
        status_code=0
        rc-service "$service_name" status >/dev/null 2>&1 || status_code=$?
        [ "$status_code" -eq 3 ] || fail "无法确认 $service_name 已停止，保留所有文件。"
      fi
    fi
    for runlevel in /etc/runlevels/*; do
      [ -e "$runlevel/$service_name" ] || [ -L "$runlevel/$service_name" ] || continue
      check_path "$runlevel"
      if [ -e "$service_file" ]; then
        rc-update del "$service_name" "${runlevel##*/}" \
          || fail "无法取消 $service_name 自启，保留所有文件。"
      fi
      rm -f -- "$runlevel/$service_name"
    done
  fi
  check_pid_file "/run/$service_name.pid"
  rm -f -- "/run/$service_name.pid"
}
if [ "$tunnel_found" -eq 1 ] || [ "$xray_found" -eq 1 ]; then
  stop_service cloudflared-nat-vless "$tunnel_service"
fi
if [ "$xray_found" -eq 1 ]; then
  stop_service xray "$xray_service"
  if command -v pidof >/dev/null 2>&1 && pidof xray >/dev/null 2>&1; then
    fail '仍有 Xray 进程运行，保留配置和程序。'
  fi
fi

if [ "$tunnel_found" -eq 1 ] || [ "$xray_found" -eq 1 ]; then
  rm -f -- "$tunnel_service" /etc/nat-vless/cloudflared.token
  rmdir /etc/nat-vless 2>/dev/null || true
fi
cloudflared_shared=0
if [ "$owned_binary$owned_package$owned_user$owned_group$owned_repo$owned_key" != 000000 ]; then
  for other_config in /etc/cloudflared /root/.cloudflared /home/*/.cloudflared; do
    if [ -e "$other_config" ] || [ -L "$other_config" ]; then cloudflared_shared=1; fi
  done
  for other_service in /etc/init.d/* /etc/systemd/system/*.service /usr/lib/systemd/system/*.service /lib/systemd/system/*.service; do
    [ -f "$other_service" ] || continue
    [ "$other_service" != "$tunnel_service" ] || continue
    if [ "$owned_package" -eq 1 ]; then
      case "${other_service##*/}" in
        cloudflared.service|cloudflared-update.service)
          if ! systemctl is-active --quiet "${other_service##*/}" \
            && ! systemctl is-enabled --quiet "${other_service##*/}"; then
            continue
          fi
          ;;
      esac
    fi
    if grep -Fq cloudflared "$other_service"; then cloudflared_shared=1; fi
  done
  if command -v pidof >/dev/null 2>&1 && pidof cloudflared >/dev/null 2>&1; then
    cloudflared_shared=1
  fi
  if [ "$cloudflared_shared" -eq 1 ]; then
    printf '检测到其他 cloudflared 配置、服务或进程，保留共享程序、账户和资源清单。\n'
  else
    if [ "$owned_package" -eq 1 ]; then
      command -v dpkg-query >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1 \
        || fail '无法检查或卸载专用 cloudflared 软件包，资源清单已保留。'
      package_status=
      package_query_status=0
      package_status=$(dpkg-query -W -f='${Status}' cloudflared 2>/dev/null) || package_query_status=$?
      [ "$package_query_status" -le 1 ] || fail '无法检查 cloudflared 软件包状态，资源清单已保留。'
      if [ "$package_query_status" -eq 0 ] && [ -n "$package_status" ] \
        && [ "$package_status" != 'unknown ok not-installed' ]; then
        apt-get purge -y cloudflared || fail '无法卸载专用 cloudflared 软件包，资源清单已保留。'
        package_status=
        package_query_status=0
        package_status=$(dpkg-query -W -f='${Status}' cloudflared 2>/dev/null) || package_query_status=$?
        [ "$package_query_status" -le 1 ] || fail '无法确认 cloudflared 软件包已移除，资源清单已保留。'
        if [ "$package_query_status" -eq 0 ] && [ -n "$package_status" ] \
          && [ "$package_status" != 'unknown ok not-installed' ]; then
          fail 'cloudflared 软件包仍有残留，资源清单已保留。'
        fi
      fi
    fi
    if [ "$owned_binary" -eq 1 ]; then rm -f -- /usr/local/bin/cloudflared; fi
    if [ "$owned_user" -eq 1 ] && id cloudflared >/dev/null 2>&1; then
      if [ "$platform" = alpine ]; then
        deluser cloudflared || fail '无法删除专用 cloudflared 用户，资源清单已保留。'
      else
        userdel cloudflared || fail '无法删除专用 cloudflared 用户，资源清单已保留。'
      fi
    fi
    if [ "$owned_group" -eq 1 ]; then
      if [ "$platform" = alpine ]; then
        if grep -q '^cloudflared:' /etc/group 2>/dev/null; then
          delgroup cloudflared || fail '无法删除专用 cloudflared 组，资源清单已保留。'
        fi
      elif getent group cloudflared >/dev/null 2>&1; then
        groupdel cloudflared || fail '无法删除专用 cloudflared 组，资源清单已保留。'
      fi
    fi
    if [ "$owned_repo" -eq 1 ]; then rm -f -- /etc/apt/sources.list.d/cloudflared.list; fi
    if [ "$owned_key" -eq 1 ]; then rm -f -- /usr/share/keyrings/cloudflare-main.gpg; fi
  fi
elif [ -e /usr/local/bin/cloudflared ] || command -v cloudflared >/dev/null 2>&1; then
  printf '未记录 cloudflared 程序的创建归属，保留现有共享程序和账户。\n'
fi

xray_shared=0
if [ "$owned_xray_user$owned_xray_group" != 00 ]; then
  for other_config in /usr/local/etc/xray/*; do
    [ -e "$other_config" ] || [ -L "$other_config" ] || continue
    [ "$other_config" = /usr/local/etc/xray/config.json ] || xray_shared=1
  done
  for other_service in /etc/init.d/* /etc/systemd/system/*.service /usr/lib/systemd/system/*.service /lib/systemd/system/*.service; do
    [ -f "$other_service" ] || continue
    [ "$other_service" != "$xray_service" ] || continue
    [ "$other_service" != /etc/systemd/system/xray@.service ] || continue
    if grep -Eq '(^|[/[:space:]])xray([/[:space:]]|$)' "$other_service"; then xray_shared=1; fi
  done
  if [ "$xray_shared" -eq 1 ]; then
    printf '检测到其他 Xray 配置或服务，保留共享账户和资源清单。\n'
  else
    if [ "$owned_xray_user" -eq 1 ] && id xray >/dev/null 2>&1; then
      if [ "$platform" = alpine ]; then
        deluser xray || fail '无法删除专用 Xray 用户，资源清单已保留。'
      else
        userdel xray || fail '无法删除专用 Xray 用户，资源清单已保留。'
      fi
    fi
    if [ "$owned_xray_group" -eq 1 ]; then
      if [ "$platform" = alpine ]; then
        if grep -q '^xray:' /etc/group 2>/dev/null; then
          delgroup xray || fail '无法删除专用 Xray 组，资源清单已保留。'
        fi
      elif getent group xray >/dev/null 2>&1; then
        groupdel xray || fail '无法删除专用 Xray 组，资源清单已保留。'
      fi
    fi
  fi
fi

if [ "$build_deps_found" -eq 1 ]; then
  apk del .nat-vless-build-deps || fail '无法移除本项目安装专用依赖，请重试卸载。'
  if apk info -e .nat-vless-build-deps >/dev/null 2>&1; then
    fail '安装专用依赖仍存在，请重试卸载。'
  fi
fi
printf '%s' "$stage_paths$recovery_paths" | while IFS= read -r cleanup_dir; do
  [ -n "$cleanup_dir" ] || continue
  rm -rf -- "$cleanup_dir"
done
if [ "$xray_found" -eq 1 ]; then
  if [ -f /root/nat-vless-node.txt ] \
    && grep -q '^vless://' /root/nat-vless-node.txt \
    && ! grep -qv '^vless://[^[:space:]]\{1,\}$' /root/nat-vless-node.txt; then
    rm -f -- /root/nat-vless-node.txt
  fi
  for installer_copy in /root/install-alpine.sh /root/install.sh; do
    [ -f "$installer_copy" ] || continue
    if grep -Fq nat-vless-reality-v1 "$installer_copy" \
      && grep -Eq '^XRAY_BIN="?/usr/local/bin/xray"?$' "$installer_copy"; then
      rm -f -- "$installer_copy"
    fi
  done
  rm -f -- "$xray_service" /usr/local/bin/xray /usr/local/etc/xray/config.json
  if [ "$platform" = systemd ]; then
    rm -f -- /etc/systemd/system/xray@.service \
      /etc/systemd/system/xray.service.d/10-donot_touch_single_conf.conf \
      /etc/systemd/system/xray@.service.d/10-donot_touch_single_conf.conf
    rmdir /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d 2>/dev/null || true
  fi
  rm -f -- /usr/local/etc/xray/.nat-vless-installer
  if [ "$cloudflared_shared" -eq 0 ] && [ "$xray_shared" -eq 0 ]; then
    rm -f -- "$resources_file"
  fi
  rmdir /usr/local/etc/xray 2>/dev/null || true
fi
if [ "$platform" = systemd ]; then
  systemctl daemon-reload
  systemctl reset-failed xray.service cloudflared-nat-vless.service 2>/dev/null || true
fi
if [ "$cloudflared_shared" -eq 1 ] || [ "$xray_shared" -eq 1 ]; then
  printf '节点已卸载；共享资源及归属清单已保留，请处理共享用途后再次卸载，再重新安装。\n'
else
  printf '卸载完成，可以重新运行安装脚本。\n'
fi
printf '已清理可确认属于本项目的文件；原有共享程序、系统工具和未标记文件保留。\n'
printf 'Cloudflare 控制台中的 Tunnel、DNS 和 CDN 回源规则请按需手动删除。\n'
