#!/system/bin/sh
# 在设备上直接问【正在运行的内核策略】：某个访问放不放行。（#126，2026-09-27）
#
# 用法（在 Mac 上）：
#   printf '%s\n' "vendor_init system_prop property_service set" "kernel vendor_file system firmware_load" \
#     | adb shell 'su -c "sh /data/local/tmp/policy-query.sh"'
# 每行：<源域> <目标类型> <类> <权限>。目标一律按 u:object_r:<类型>:s0 构造；
# 目标是进程（如 capability 类的 self）时把 object_r 换成 r 用 -p 选项：行首加 "p "。
# 输出 ALLOW / DENY；源域是 permissive 域时额外标 [permissive]。
#
# 原理：selinuxfs 的 access 节点（security_compute_av），写 "scon tcon 类号"、读回
#   "allowed decided auditallow auditdeny seqno flags"（十六进制）。类号与权限位号
#   来自 /sys/fs/selinux/class/<类>/{index,perms/<权限>}。
# 为什么需要它：permissive 下同一个 (源, 目标类型, 类, 权限) 只记一条 denial，
#   "日志里没看到"推不出"放行了"；读 .te 又可能漏 neverallow / 宏展开 / 版本差异
#   （2026-09-27 就查出 refs 里的 access_vectors 比构建机旧，少了 firmware_load）。
#   这个查询答的是设备上此刻真实加载的那份策略。
# 需要 root（ksu 域）：普通 shell 域没有 compute_av 权限。
q() {
  role=object_r
  if [ "$1" = p ]; then role=r; shift; fi
  s=$1; t=$2; c=$3; p=$4
  ci=$(cat /sys/fs/selinux/class/$c/index 2>/dev/null) || { echo "??    没有这个类: $c"; return; }
  pi=$(cat /sys/fs/selinux/class/$c/perms/$p 2>/dev/null) || { echo "??    $c 没有权限 $p"; return; }
  exec 3<>/sys/fs/selinux/access
  printf "u:r:%s:s0 u:%s:%s:s0 %s" "$s" "$role" "$t" "$ci" >&3
  read -r ans <&3
  exec 3<&-
  set -- $ans
  allowed=$(( 0x$1 )); flags=$(( 0x$6 ))
  tag=""; [ $(( flags & 1 )) -ne 0 ] && tag=" [permissive]"
  if [ $(( allowed & (1 << (pi - 1)) )) -ne 0 ]; then
    echo "ALLOW $s $t:$c $p$tag"
  else
    echo "DENY  $s $t:$c $p$tag"
  fi
}
while read -r a b c d e; do
  [ -z "$a" ] && continue
  case "$a" in \#*) continue ;; esac
  if [ "$a" = p ]; then q p "$b" "$c" "$d" "$e"; else q "$a" "$b" "$c" "$d"; fi
done
