#!/system/bin/sh
# 游戏模式设备端（由 scripts/game-mode.sh push 到 /data/local/tmp/ 使用；
# 也可以在设备 root shell 里直接跑）：
#
#   sh /data/local/tmp/gk3-game-mode-device.sh identity|on <分钟>|off|status
#
# 动作与边界见 game-mode.sh 顶部。这里只记实现上踩过的点：
#   * resetprop 用 KSU 的 /data/adb/ksu/bin/resetprop（Magisk 语法）。
#     ro.* 删掉只影响内存属性区，重启自还原；persist.* 是真持久，靠状态文件还原。
#   * on 的最后一步是【延迟关 adb】—— 立即关会把正在执行的 shell 一起杀掉。
#     定时器、安全网必须先布好。⚠️ USB 配置要走 setprop 才改 gadget（resetprop 不触发
#     init 的 on property 钩子）；改 gadget 会立刻断开本会话。
#   * ⚠️★★ 定时器必须 trap '' HUP / setsid 脱离会话：`stop adbd` 会毁掉 PTY，
#     同进程组的定时器跟着收 SIGHUP。2026-10-10 实测没隔离的代价：定时器死在
#     adb 前头，关掉的 adb 再也回不来，只能按电源键重启走开机兜底。
#   * 恢复靠三层：定时器 → game-mode.sh off → 开机安全网
#     /data/adb/service.d/gk3-game-mode-safety.sh（active 标记还在就拉回 adb）。

RP=/data/adb/ksu/bin/resetprop
DIR=/data/local/tmp/gk3-game-mode
STATE=$DIR/state
ACTIVE=$DIR/active
TIMER_PID=$DIR/timer.pid
SAFETY=/data/adb/service.d/gk3-game-mode-safety.sh

# 只删 ro.crdroid.version —— Duck Detector 的判据表（SystemPropertiesCatalog /
# CustomRomCatalog）只查这一个键。⚠️ 别扩大到整个 ro.crdroid.* 家族：
# ro.crdroid.device 是 find-device.sh 认设备的身份判据（CLAUDE.md），砸了会连不上排查；
# ro.crdroid.build.version / display.version / ro.crdroidlegal.url 没有检测器查，留着。
CRDROID_PROPS="ro.crdroid.version"

# 会话里要藏起来的包（baseline 实测的 dangerous_apps / root_managers 命中）。
# 用 uninstall --user 0 而不是 disable-user：检测器走 getInstalledPackages，
# disable 后仍算"已安装"。卸前把 APK 备份到 $DIR/apk/，unhide 原样装回（可逆）。
HIDE_PKGS="com.resukisu.resukisu bin.mt.termex"
# 残留目录：DangerousAppsCatalog 把 /sdcard/MT2 直接映射成 bin.mt.termex 命中，
# 空目录也算。mv 到一旁而不是删（用户数据，unhide 放回）。
HIDE_PATHS="/sdcard/MT2"
# 指纹族全列：2026-10-10 baseline 实测 ro.system/vendor.build.fingerprint 仍为
# :userdebug/，检测器（Bootloader/SystemProperties 的 "fingerprint tail" 漂移判据）
# 会拿它们当反射源，漏改就多两条 Type drift。ro.product.{system,vendor}.build.fingerprint
# 与 ro.bootimage.build.fingerprint 本机为空，列上无害。
# ⚠️ Build.FINGERPRINT（android.os.Build 常量）在 zygote 预加载时定死，运行时改不了；
#    运行时改属性反而会制造 property↔constant 漂移。ROM 级对齐在
#    scripts/crdroid-tree-fixes.py tree-fix [23]（config.mk 的 fingerprint 变体段 → user），
#    下次 ROM 构建后这里的 sed 就是无操作（尾部本来就是 :user/）。
FP_PROPS="ro.build.fingerprint ro.product.build.fingerprint ro.system.build.fingerprint ro.vendor.build.fingerprint ro.product.system.build.fingerprint ro.product.vendor.build.fingerprint ro.bootimage.build.fingerprint"

log() { echo "game-mode: $*"; }

need_root() {
  [ "$(id -u)" = "0" ] || { echo "需要 root（adb shell 在本机经 KSU 即 root）"; exit 1; }
  [ -x "$RP" ] || { echo "找不到 $RP"; exit 1; }
}

save_orig() { # save_orig <prop>
  [ -f "$STATE/$1" ] && return 0
  getprop "$1" > "$STATE/$1"
}

save_setting() { # save_setting <namespace> <key>
  [ -f "$STATE/setting.$2" ] && return 0
  settings get "$1" "$2" > "$STATE/setting.$2" 2>/dev/null
}

do_identity() {
  mkdir -p "$STATE"
  for p in $FP_PROPS $CRDROID_PROPS; do save_orig "$p"; done
  # SEC-5：指纹尾部 :userdebug/ → :user/（与 ro.build.type=user 对齐）
  for p in $FP_PROPS; do
    cur=$(getprop "$p")
    [ -n "$cur" ] || continue
    new=$(echo "$cur" | sed 's|:userdebug/|:user/|')
    if [ "$cur" != "$new" ]; then
      "$RP" "$p" "$new"
      log "$p 尾部 userdebug→user"
    fi
  done
  # SystemProperties：ro.crdroid.version 任意非空 = danger
  for p in $CRDROID_PROPS; do
    if [ -n "$(getprop "$p")" ]; then
      "$RP" --delete "$p"
      log "删除 $p"
    fi
  done
}

# 藏包 / 恢复：只动 $HIDE_PKGS。hide 会真卸载（对 user 0），APK 备份到 $DIR/apk/。
do_hide() {
  mkdir -p "$STATE" "$DIR/apk"
  for pkg in $HIDE_PKGS; do
    pm path "$pkg" >/dev/null 2>&1 || { log "$pkg 未安装，跳过"; continue; }
    if [ ! -f "$STATE/hidden.$pkg" ]; then
      pm path "$pkg" | sed 's/^package://' > "$STATE/hidden.$pkg"
      # 每个 path 都备份（split APK 会有多个）
      while read -r apk; do
        [ -f "$apk" ] || continue
        base="$DIR/apk/${pkg}.$(basename "$apk")"
        cp "$apk" "$base" 2>/dev/null || log "备份失败 $apk"
      done < "$STATE/hidden.$pkg"
    fi
    pm uninstall --user 0 "$pkg" >/dev/null 2>&1 || pm uninstall "$pkg" >/dev/null 2>&1
    log "已隐藏 $pkg"
  done
  for p in $HIDE_PATHS; do
    [ -e "$p" ] || continue
    mv "$p" "$p.gk3hidden" 2>/dev/null && log "残留目录 $p 已移开"
  done
}

do_unhide() {
  for pkg in $HIDE_PKGS; do
    [ -f "$STATE/hidden.$pkg" ] || continue
    pm install-existing "$pkg" >/dev/null 2>&1 && { log "已恢复（系统包）$pkg"; rm -f "$STATE/hidden.$pkg"; continue; }
    # 用户包：从备份装回。base.apk 优先，装不上就全量试
    ok=0
    for f in "$DIR/apk/${pkg}."*.apk "$DIR/apk/${pkg}."*; do
      [ -f "$f" ] || continue
      pm install -r "$f" >/dev/null 2>&1 && ok=1 && break
    done
    if [ "$ok" = 1 ]; then
      log "已恢复（备份）$pkg"
    else
      log "恢复失败 $pkg —— 备份在 $DIR/apk/，手动装"
    fi
    rm -f "$STATE/hidden.$pkg"
  done
  for p in $HIDE_PATHS; do
    [ -e "$p.gk3hidden" ] || continue
    mv "$p.gk3hidden" "$p" 2>/dev/null && log "残留目录 $p 已放回"
  done
}

write_safety() {  [ -f "$SAFETY" ] && return 0
  cat > "$SAFETY" <<'EOF'
#!/system/bin/sh
# gk3 游戏模式兜底：开机时若仍有残留标记，把 adb / 开发者选项恢复回来。
# 由 scripts/game-mode.sh 的 on 安装；off 不删它（无害，平时直接退出）。
MARK=/data/local/tmp/gk3-game-mode/active
[ -f "$MARK" ] || exit 0
settings put global adb_enabled 1
settings put global development_settings_enabled 1
setprop persist.sys.usb.config adb
setprop persist.adb.tcp.port 5555
setprop service.adb.tcp.port 5555
rm -f "$MARK"
EOF
  chmod 755 "$SAFETY"
  log "已安装开机兜底 $SAFETY"
}

# 开机身份归一（独立于 game-mode 开关；resetprop 不持久，每开机都要重打）
IDENTITY_BOOT=/data/adb/service.d/gk3-game-identity.sh
install_identity_boot() {
  cat > "$IDENTITY_BOOT" <<'EOF'
#!/system/bin/sh
# gk3 身份归一（开机）：SEC-5 指纹尾部 userdebug→user；删 ro.crdroid.version。
# 由 scripts/game-mode.sh install 安装 / uninstall 卸载。只动这两个判据点，
# 别扩大范围（ro.crdroid.device 是 find-device.sh 的身份判据）。
RP=/data/adb/ksu/bin/resetprop
[ -x "$RP" ] || exit 0
for p in ro.build.fingerprint ro.product.build.fingerprint ro.system.build.fingerprint ro.vendor.build.fingerprint; do
  cur=$(getprop "$p")
  [ -n "$cur" ] || continue
  new=$(echo "$cur" | sed 's|:userdebug/|:user/|')
  [ "$cur" != "$new" ] && "$RP" "$p" "$new"
done
[ -n "$(getprop ro.crdroid.version)" ] && "$RP" --delete ro.crdroid.version
exit 0
EOF
  chmod 755 "$IDENTITY_BOOT"
  log "已安装开机身份归一 $IDENTITY_BOOT"
}
uninstall_identity_boot() {
  rm -f "$IDENTITY_BOOT"
  log "已卸载开机身份归一"
}

start_timer() { # start_timer <分钟>
  if [ -f "$TIMER_PID" ]; then
    old=$(cat "$TIMER_PID" 2>/dev/null)
    [ -n "$old" ] && kill "$old" 2>/dev/null
    rm -f "$TIMER_PID"
  fi
  min=$1
  # ⚠️★★ 定时器必须活得过 `stop adbd`：那一下会毁掉 PTY，同会话进程收 SIGHUP。
  #    2026-10-10 实测代价（首次 on/off 链路测试）：没隔离的定时器跟着 adb 一起死，
  #    adb 关了就再也回不来，只能按电源键重启走开机兜底。trap '' HUP 是最小隔离；
  #    有 setsid（toybox 自带）就再套一层新会话，双保险。
  if command -v setsid >/dev/null 2>&1; then
    setsid sh -c "trap '' HUP; sleep $((min * 60)); exec sh \"$0\" off" >/dev/null 2>&1 &
  else
    ( trap '' HUP; sleep $((min * 60)); sh "$0" off ) >/dev/null 2>&1 &
  fi
  echo $! > "$TIMER_PID"
  log "定时器已布：$min 分钟后自动恢复（pid $!）"
}

do_on() {
  need_root
  min=${1:-60}
  mkdir -p "$STATE"
  do_identity
  save_setting global development_settings_enabled
  save_setting global adb_enabled
  [ -f "$STATE/persist.sys.usb.config" ] || getprop persist.sys.usb.config > "$STATE/persist.sys.usb.config"
  [ -f "$STATE/persist.adb.tcp.port" ] || getprop persist.adb.tcp.port > "$STATE/persist.adb.tcp.port"
  write_safety
  start_timer "$min"
  touch "$ACTIVE"
  # ⚠️ USB / TCP 配置要走 setprop（属性服务）：resetprop 直写属性区、不触发 init 的
  #    `on property:persist.sys.usb.config=*`，gadget 不重新枚举 —— 主机侧 adb 接口
  #    会一直挂着（2026-10-10 实测）。改 gadget 会立刻断开本会话 ⇒ 定时器与安全网
  #    必须先就位（上面两行已布好）。resetprop 只用来做持久副本，兜底 setprop 被拒。
  "$RP" persist.sys.usb.config mtp
  setprop persist.sys.usb.config mtp
  setprop sys.usb.config mtp
  "$RP" --delete persist.adb.tcp.port
  setprop service.adb.tcp.port ""
  settings put global development_settings_enabled 0
  log "关闭 adb……"
  ( trap '' HUP; sleep 1; settings put global adb_enabled 0; stop adbd ) >/dev/null 2>&1 &
}

do_off() {
  need_root
  if [ -f "$TIMER_PID" ]; then
    old=$(cat "$TIMER_PID" 2>/dev/null)
    [ -n "$old" ] && kill "$old" 2>/dev/null
    rm -f "$TIMER_PID"
  fi
  for p in $FP_PROPS $CRDROID_PROPS; do
    if [ -f "$STATE/$p" ]; then
      "$RP" "$p" "$(cat "$STATE/$p")"
      rm -f "$STATE/$p"
    fi
  done
  # persist 值还原（原值一般是 adb / 5555）。
  # ⚠️ 同 do_on：USB 配置必须 setprop 才改 gadget；resetprop 只做持久副本。
  #    另外把运行时 sys.usb.config 与 service.adb.tcp.port 一并拉回，
  #    否则 adbd 起来了主机侧仍看不到接口 / 5555 不监听。
  if [ -f "$STATE/persist.sys.usb.config" ]; then
    v=$(cat "$STATE/persist.sys.usb.config")
    [ -n "$v" ] && { "$RP" persist.sys.usb.config "$v"; setprop persist.sys.usb.config "$v"; }
    rm -f "$STATE/persist.sys.usb.config"
  fi
  usb=$(getprop persist.sys.usb.config)
  [ -n "$usb" ] && setprop sys.usb.config "$usb"
  if [ -f "$STATE/persist.adb.tcp.port" ]; then
    v=$(cat "$STATE/persist.adb.tcp.port")
    [ -n "$v" ] && { "$RP" persist.adb.tcp.port "$v"; setprop persist.adb.tcp.port "$v"; }
    rm -f "$STATE/persist.adb.tcp.port"
  fi
  tcp=$(getprop persist.adb.tcp.port)
  [ -n "$tcp" ] && setprop service.adb.tcp.port "$tcp"
  for k in development_settings_enabled adb_enabled; do
    if [ -f "$STATE/setting.$k" ]; then
      v=$(cat "$STATE/setting.$k")
      [ "$v" = "null" ] && v=0
      settings put global "$k" "$v"
      rm -f "$STATE/setting.$k"
    fi
  done
  rm -f "$ACTIVE"
  settings put global adb_enabled 1
  start adbd 2>/dev/null
  log "已恢复"
}

do_status() {
  echo "== game-mode status =="
  [ -f "$ACTIVE" ] && echo "active 标记：在（游戏模式生效中）" || echo "active 标记：无"
  [ -f "$TIMER_PID" ] && echo "定时器 pid：$(cat "$TIMER_PID")" || echo "定时器：无"
  for p in $FP_PROPS $CRDROID_PROPS ro.build.type ro.build.tags; do
    echo "  $p = $(getprop "$p")"
  done
  echo "  persist.sys.usb.config = $(getprop persist.sys.usb.config)"
  echo "  persist.adb.tcp.port   = $(getprop persist.adb.tcp.port)"
  echo "  adb_enabled            = $(settings get global adb_enabled)"
  echo "  development_settings   = $(settings get global development_settings_enabled)"
  [ -f "$SAFETY" ] && echo "开机兜底：已安装" || echo "开机兜底：未安装"
}

case "${1:-}" in
  identity)  need_root; do_identity ;;
  on)        do_on "${2:-60}" ;;
  off)       do_off ;;
  status)    do_status ;;
  install)   need_root; install_identity_boot; do_identity ;;
  uninstall) need_root; uninstall_identity_boot ;;
  hide)      need_root; do_hide ;;
  unhide)    need_root; do_unhide ;;
  *)         echo "用法：$0 identity|on <分钟>|off|status|install|uninstall|hide|unhide"; exit 1 ;;
esac
