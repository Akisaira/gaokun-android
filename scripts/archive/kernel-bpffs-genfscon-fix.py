#!/usr/bin/env python3
"""让 bpffs 回到「惰性 SELinux 标注」，以兼容 Android 的 genfscon（幂等）。

    python3 scripts/kernel-bpffs-genfscon-fix.py ~/gaokun/mainline-linux

★ 问题（2026-08-19 实机定案，crDroid 16.0 + 主线 7.2-rc2）

Android 靠 sepolicy 的 genfscon 给 bpffs 子目录打标签：
    genfscon bpf /net_shared u:object_r:fs_bpf_net_shared:s0     （共 11 条）
genfscon 是【惰性】标注 —— inode 首次被访问时按路径匹配。

但主线内核的 bpffs（kernel/bpf/inode.c）在 bpf_mkdir / bpf_mkobj / bpf_mklink
三处都调用 security_inode_init_security()，即【创建时急切赋标签】，
从父目录继承。于是 /sys/fs/bpf 下所有子目录和文件都拿到根标签
u:object_r:fs_bpf:s0，genfscon 那 11 条形同虚设。

后果：system_server 崩溃循环、开不进桌面。
ClatCoordinator 注册时会【逐字比对标签字符串】（不是权限检查，permissive 无效）：
    packages/modules/Connectivity/service/jni/
        com_android_server_connectivity_ClatCoordinator.cpp:564 verifyClatPerms()
    E jniClatCoordinator: context of '/sys/fs/bpf/net_shared' is
        'u:object_r:fs_bpf:s0' != 'u:object_r:fs_bpf_net_shared:s0'
    → ALOGF 置 fatal → abort()

★ 为什么不能在用户态修

试过 chcon -R，得到 ENOTSUP。原因：SELinux 的 selinux_inode_setxattr() 只在
超级块带 SBLABEL_MNT（即策略对该 fs 用 fs_use_xattr）时才允许写
security.selinux；而 Android 策略对 bpf 用的是 genfscon，没有 SBLABEL_MNT。
所以用户态无论如何都改不了 bpffs 的标签。

★ 对照实验（证明不是 genfscon 整体失效）

    /proc/sysrq-trigger  → proc_sysrq             ✅
    /sys/kernel/tracing  → debugfs_tracing_debug  ✅
    /sys/fs/bpf/*        → fs_bpf                 ❌ 只有 bpffs

★ 修法

把三处 security_inode_init_security() 用编译期常量短路掉，
inode 不再在创建时被标注 → SELinux 回落到 genfscon 路径匹配。
保留调用表达式（放在 ?: 的未取分支里）以免 bpf_fs_initxattrs
变成未使用函数触发 -Werror=unused-function。

副作用：bpffs 对象不再获得 LSM 初始 xattr。本机不用 BPF LSM 的这项能力，
且 Android 从来就假设 bpffs 走 genfscon，所以这是「恢复 Android 预期行为」。
"""
import io, sys, pathlib

GUARD = "BPF_FS_EAGER_SECURITY_INIT"

GUARD_BLOCK = """
/*
 * gaokun3/Android: bpffs 必须由 SELinux 通过 genfscon 惰性标注。
 * 见 scripts/kernel-bpffs-genfscon-fix.py 的完整说明。
 * 置 1 即恢复主线原行为（Android 上会导致 system_server 崩溃循环）。
 */
#define BPF_FS_EAGER_SECURITY_INIT 0
"""

OLD = """	ret = security_inode_init_security(inode, dir, &dentry->d_name,
					   bpf_fs_initxattrs, NULL);"""
NEW = """	ret = BPF_FS_EAGER_SECURITY_INIT
		? security_inode_init_security(inode, dir, &dentry->d_name,
					       bpf_fs_initxattrs, NULL)
		: 0;"""

def main():
    tree = pathlib.Path(sys.argv[1] if len(sys.argv) > 1
                        else pathlib.Path.home() / "gaokun/mainline-linux").expanduser()
    p = tree / "kernel/bpf/inode.c"
    if not p.exists():
        print(f"✗ 找不到 {p}"); sys.exit(1)
    s = io.open(p, encoding="utf-8").read()

    if GUARD in s:
        print(f"  已打过补丁（{s.count(NEW)} 处短路），幂等跳过")
        return

    n = s.count(OLD)
    if n != 3:
        print(f"✗ 预期 3 处调用点，实际找到 {n} 处 —— 上游可能改了写法，请人工确认")
        sys.exit(1)

    anchor = "static int bpf_fs_initxattrs(struct inode *inode,\n"
    idx = s.index(anchor)
    s = s[:idx] + GUARD_BLOCK.lstrip("\n") + "\n" + s[idx:]
    s = s.replace(OLD, NEW)
    io.open(p, "w", encoding="utf-8", newline="").write(s)
    print(f"  已短路 {n} 处 security_inode_init_security()，并插入 {GUARD} 开关")

if __name__ == "__main__":
    main()
