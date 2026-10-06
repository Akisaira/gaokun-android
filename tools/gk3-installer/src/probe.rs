//! `gk3_probe`：列出磁盘 / 分区 / 空闲区（installer-lib.sh:131-225、:227-247）。
//!
//!   DISK path=/dev/nvme0n1 size_mib=488386 model=… removable=0 tran=nvme medium=no table=gpt|mbr|unreadable|unknown
//!   PART path=… num=1 start=2048 end=616447 size_mib=300 size_kib=307200 type=<GUID> name=… fs=vfat fslabel=… os=esp medium=no
//!   FREE disk=/dev/nvme0n1 start=616448 end=… size_mib=…
//!
//! 每一个字段的来源、默认值、编码与否都照 shell 版逐个搬过来（注释里写着对应的那一行）。
//! shell 版吞掉的失败（`2>/dev/null`、`|| echo 0`）这里照样按它的默认值走 —— 但都进了 [`Diag`]。
//! 分区表读不出（S1，2026-10-06 两边一起修）不再按默认值走：DISK 记 `table=unreadable`，不列 PART / FREE，
//! 报 `ERR code=disk-unreadable disk=… touched=no`，最后退出码 1（别的盘照常列出）。

use std::io;

use crate::exec::Cmd;
use crate::gpt;
use crate::host::{capture, cat, Diag, Host};
use crate::protocol::{Failure, Out, Record, Touched};
use crate::sh;

/// 安装介质（/media/gk3）所在的整块盘；不是从介质启动 ⇒ 空串（installer-lib.sh:122-129 `gk3__medium_disk`）
pub fn medium_disk(host: &dyn Host, diag: &mut Diag) -> String {
    // findmnt：1 = 没挂（正常情况，不记）
    let dev = capture(host, &Cmd::new("findmnt").args(["-no", "SOURCE", "/media/gk3"]), &[0, 1], diag);
    if dev.is_empty() {
        return String::new();
    }
    let dev = String::from_utf8_lossy(&dev).into_owned();
    // `lsblk -no PKNAME "$dev" | head -1`
    let pk = capture(host, &Cmd::new("lsblk").args(["-no", "PKNAME"]).arg(dev), &[0], diag);
    let first = sh::lines(&pk).first().map(|l| l.to_vec()).unwrap_or_default();
    if first.is_empty() {
        String::new()
    } else {
        format!("/dev/{}", String::from_utf8_lossy(&first))
    }
}

/// installer-lib.sh:227-247 `gk3__guess_os` —— 只用于界面提示，不参与任何判断
pub fn guess_os(ptype: &[u8], pname: &[u8], fstype: &[u8]) -> &'static str {
    match pname {
        b"esp" => return "esp",
        b"super" | b"userdata" | b"metadata" | b"misc" | b"boot_a" | b"boot_b" => return "android",
        _ => {}
    }
    match ptype {
        b"C12A7328-F81F-11D2-BA4B-00A0C93EC93B" => return "esp",
        b"DE94BBA4-06D1-4D40-A16A-BFD50179D6AC" => return "winre",
        b"E3C9E316-0B5C-4DB8-817D-F92DF00215AE" => return "msr",
        _ => {}
    }
    match fstype {
        b"ntfs" => "windows",
        b"ext4" | b"ext3" | b"btrfs" | b"xfs" => "linux",
        b"f2fs" => "android",
        b"vfat" => "fat",
        b"crypto_LUKS" => "luks",
        _ => "",
    }
}

/// `gk3_probe`。返回值 = shell 版的退出码：有盘读不出分区表 ⇒ 1，否则 0
pub fn probe(host: &dyn Host, out: &mut Out, diag: &mut Diag) -> io::Result<i32> {
    let mut rc = 0;
    let allow_loop = host.env("GK3_ALLOW_LOOP").as_deref().unwrap_or("0") == "1";
    let medium = medium_disk(host, diag);
    for d in host.glob("/sys/block") {
        let name = sh::basename(&d).to_string();
        // installer-lib.sh:148-151
        if name.starts_with("loop") {
            if !allow_loop {
                continue;
            }
        } else if ["ram", "zram", "dm-", "sr", "md"].iter().any(|p| name.starts_with(p)) {
            continue;
        }
        let dev = format!("/dev/{name}");
        if !host.exists(&dev) {
            continue;
        }
        // sectors=$(cat "$d/size" 2>/dev/null || echo 0); [ "$sectors" -gt 0 ] || continue
        let sectors_raw = cat(host, &format!("{d}/size")).unwrap_or_else(|| b"0".to_vec());
        let sectors = match sh::test_int(&sectors_raw) {
            Some(s) if s > 0 => s,
            Some(_) => continue,
            None => {
                diag.note(format!("{d}/size 不是整数（{}），跳过这块盘（shell 版同样跳过）", String::from_utf8_lossy(&sectors_raw)));
                continue;
            }
        };
        let size_mib = sectors / 2048;
        if size_mib < 1024 {
            continue;
        }
        // model：第一行、去首尾空白；空 ⇒ "?"（installer-lib.sh:162）
        let model = match host.read(&format!("{d}/device/model")) {
            Ok(v) => {
                let first = v.split(|&c| c == b'\n').next().unwrap_or(&[]);
                sh::trim_space(first).to_vec()
            }
            Err(_) => Vec::new(),
        };
        let model = if model.is_empty() { b"?".to_vec() } else { model };
        let removable = cat(host, &format!("{d}/removable")).unwrap_or_else(|| b"0".to_vec());
        // tran=$(lsblk -dno TRAN /dev/$name | head -1 | tr -d ' ')；空 ⇒ "?"
        let tran_out = capture(host, &Cmd::new("lsblk").args(["-dno", "TRAN"]).arg(dev.clone()), &[0], diag);
        let mut tran: Vec<u8> = sh::lines(&tran_out).first().map(|l| l.to_vec()).unwrap_or_default();
        tran.retain(|&c| c != b' ');
        let tran = if tran.is_empty() { b"?".to_vec() } else { tran };
        let is_medium = if dev == medium { "yes" } else { "no" };
        let table = gpt::read_table(host, &dev);
        out.record(
            &Record::new("DISK")
                .raw("path", &dev)
                .num("size_mib", size_mib)
                .enc("model", &model)
                .raw("removable", &removable)
                .raw("tran", &tran)
                .raw("medium", is_medium)
                .raw("table", table.kind.as_str()),
        )?;
        if !probe_parts(host, out, diag, &dev, &table)? {
            rc = 1;
        }
    }
    Ok(rc)
}

/// 读不出分区表：ERR + `!!`（installer-lib.sh `gk3__probe_parts` 里的 `gk3_fail disk-unreadable … touched=no`）
fn unreadable(out: &mut Out, disk: &str, why: &str) -> io::Result<bool> {
    out.fail(&Failure {
        code: "disk-unreadable".into(),
        fields: vec![("disk".into(), disk.as_bytes().to_vec())],
        touched: Some(Touched::No),
        human: format!("读不出 {disk} 的分区表（{why}）—— 不列它的分区与空闲区"),
    })?;
    Ok(false)
}

/// installer-lib.sh `gk3__probe_parts`。返回 false = 这块盘读不出（已经报过 ERR）
fn probe_parts(host: &dyn Host, out: &mut Out, diag: &mut Diag, disk: &str, table: &gpt::Table) -> io::Result<bool> {
    match table.kind {
        gpt::Kind::Unknown => {
            // shell 版这里只打一行日志（gk3_log）就回 0 —— 界面上这块盘就像没有分区（预检会报缺工具）。日志同文
            out.log(&format!("缺 sgdisk，跳过 {disk} 的分区探测"))?;
            return Ok(true);
        }
        gpt::Kind::Unreadable => return unreadable(out, disk, &table.why),
        gpt::Kind::Gpt | gpt::Kind::Mbr => {}
    }
    // shell 版对同一块盘跑 1 + 2×分区数 次 sgdisk；输出是确定的，这里每种只跑一次
    let p = gpt::parse_print(&table.print);
    // read_table 已经保证这一行在、两个数都是数字串；数字大到溢出 i64 时 bash 会回绕 —— 这里当成读不出（偏差 D2 一类）
    let (Some(first_usable), Some(last_usable)) = (sh::arith_int(&p.first_usable), sh::arith_int(&p.last_usable)) else {
        return unreadable(out, disk, "可用扇区的范围读不懂");
    };

    let medium_part =
        String::from_utf8_lossy(&capture(host, &Cmd::new("findmnt").args(["-no", "SOURCE", "/media/gk3"]), &[0, 1], diag)).into_owned();
    let medium_real = host.readlink_f(&medium_part);
    let mut cursor = first_usable;
    for row in gpt::sorted_by_start(&p.rows) {
        if row.num.is_empty() {
            continue;
        }
        let num = String::from_utf8_lossy(&row.num).into_owned();
        let (Some(start), Some(end)) = (sh::arith_int(&row.start), sh::arith_int(&row.end)) else {
            // shell 版在这里会做一次非法的算术（bash 报错、这一行的输出走样）—— sgdisk 的表行不会出现这种情况
            diag.note(format!(
                "{disk} 第 {num} 个分区的起止扇区读不懂（{} / {}），跳过",
                String::from_utf8_lossy(&row.start),
                String::from_utf8_lossy(&row.end)
            ));
            continue;
        };
        // [ "$start" -gt "$cursor" ]
        if start > cursor {
            emit_free(out, disk, cursor, start - 1)?;
        }
        let part = gpt::partpath(disk, &num);
        let info_out = capture(host, &Cmd::new("sgdisk").arg("-i").arg(num.clone()).arg(disk), &[0], diag);
        let info = gpt::parse_info(&info_out);
        // blkid：2 = 认不出文件系统（正常情况，不记）
        let fstype = capture(host, &Cmd::new("blkid").args(["-o", "value", "-s", "TYPE"]).arg(part.clone()), &[0, 2], diag);
        let fslabel = capture(host, &Cmd::new("blkid").args(["-o", "value", "-s", "LABEL"]).arg(part.clone()), &[0, 2], diag);
        let ptype = if info.type_guid.is_empty() { b"?".to_vec() } else { info.type_guid.clone() };
        // [ -n "$medium_part" ] && [ "$(readlink -f "$medium_part")" = "$(readlink -f "$part")" ]（两边都解析失败 = 两个空串 = 相等）
        let is_medium = !medium_part.is_empty() && medium_real.clone().unwrap_or_default() == host.readlink_f(&part).unwrap_or_default();
        let span = end - start + 1;
        out.record(
            &Record::new("PART")
                .raw("path", &part)
                .raw("num", &num)
                .raw("start", &row.start)
                .raw("end", &row.end)
                .num("size_mib", span / 2048)
                .num("size_kib", span / 2)
                .raw("type", &ptype)
                .enc("name", &info.name)
                .raw("fs", &fstype)
                .enc("fslabel", &fslabel)
                .raw("os", guess_os(&info.type_guid, &info.name, &fstype))
                .raw("medium", if is_medium { "yes" } else { "no" }),
        )?;
        cursor = end + 1;
    }
    if cursor < last_usable {
        emit_free(out, disk, cursor, last_usable)?;
    }
    Ok(true)
}

/// installer-lib.sh:218-225 `gk3__emit_free`：小于 16 MiB 的缝隙不报
fn emit_free(out: &mut Out, disk: &str, start: i64, end: i64) -> io::Result<()> {
    let mib = (end - start + 1) / 2048;
    if mib < 16 {
        return Ok(());
    }
    out.record(&Record::new("FREE").raw("disk", disk).num("start", start).num("end", end).num("size_mib", mib))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::fake::FakeHost;

    const P: &str = "Disk /dev/nvme0n1: 1000215216 sectors, 476.9 GiB
First usable sector is 34, last usable sector is 1000215182

Number  Start (sector)    End (sector)  Size       Code  Name
   1            2048          616447   300.0 MiB   EF00  EFI system partition
   2          616448          649215   16.0 MiB    0C01  Microsoft reserved partition
   3          649216       200000000   95.1 GiB    0700  Basic data partition
";

    fn host() -> FakeHost {
        let mut h = FakeHost::default()
            .tool("sgdisk")
            .file("/sys/block/nvme0n1/size", "1000215216\n")
            .file("/sys/block/nvme0n1/removable", "0\n")
            .file("/sys/block/nvme0n1/device/model", "SAMSUNG MZ9L4512HBLU-00B07              \n")
            .file("/sys/block/loop0/size", "83886080\n")
            .file("/sys/block/zram0/size", "83886080\n")
            .block("/dev/nvme0n1")
            .block("/dev/loop0")
            .block("/dev/zram0")
            .cmd("findmnt -no SOURCE /media/gk3", 1, "")
            .cmd("lsblk -dno TRAN /dev/nvme0n1", 0, "nvme\n")
            .cmd("sgdisk -p /dev/nvme0n1", 0, P)
            .cmd("blkid -p -o value -s PTTYPE /dev/nvme0n1", 0, "gpt\n");
        let infos = [
            ("1", "C12A7328-F81F-11D2-BA4B-00A0C93EC93B", "EFI system partition", "vfat", "SYSTEM"),
            ("2", "E3C9E316-0B5C-4DB8-817D-F92DF00215AE", "Microsoft reserved partition", "", ""),
            ("3", "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", "Basic data partition", "ntfs", "Windows 卷"),
        ];
        for (n, g, name, fs, label) in infos {
            h = h
                .cmd(&format!("sgdisk -i {n} /dev/nvme0n1"), 0, &format!("Partition GUID code: {g} (x)\nPartition name: '{name}'\n"))
                .cmd(&format!("blkid -o value -s TYPE /dev/nvme0n1p{n}"), if fs.is_empty() { 2 } else { 0 }, fs)
                .cmd(&format!("blkid -o value -s LABEL /dev/nvme0n1p{n}"), if label.is_empty() { 2 } else { 0 }, label);
        }
        h
    }

    fn run_rc(h: &FakeHost) -> (i32, String, String, Diag) {
        let (mut o, mut e) = (Vec::new(), Vec::new());
        let mut diag = Diag::default();
        let rc = probe(h, &mut Out::new(&mut o, &mut e), &mut diag).unwrap();
        (rc, String::from_utf8(o).unwrap(), String::from_utf8(e).unwrap(), diag)
    }

    fn run(h: &FakeHost) -> (String, String, Diag) {
        let (rc, o, e, diag) = run_rc(h);
        assert_eq!(rc, 0);
        (o, e, diag)
    }

    #[test]
    fn windows_disk() {
        let (o, e, diag) = run(&host());
        assert_eq!(
            o,
            "DISK path=/dev/nvme0n1 size_mib=488386 model=SAMSUNG%20MZ9L4512HBLU-00B07 removable=0 tran=nvme medium=no table=gpt
PART path=/dev/nvme0n1p1 num=1 start=2048 end=616447 size_mib=300 size_kib=307200 type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B name=EFI%20system%20partition fs=vfat fslabel=SYSTEM os=esp medium=no
PART path=/dev/nvme0n1p2 num=2 start=616448 end=649215 size_mib=16 size_kib=16384 type=E3C9E316-0B5C-4DB8-817D-F92DF00215AE name=Microsoft%20reserved%20partition fs= fslabel= os=msr medium=no
PART path=/dev/nvme0n1p3 num=3 start=649216 end=200000000 size_mib=97339 size_kib=99675392 type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 name=Basic%20data%20partition fs=ntfs fslabel=Windows%20卷 os=windows medium=no
FREE disk=/dev/nvme0n1 start=200000001 end=1000215182 size_mib=390730
"
        );
        assert_eq!(e, "");
        // loop 没开 GK3_ALLOW_LOOP、zram 永远跳过；blkid 的 2、findmnt 的 1 都是预期内的，不记
        assert!(diag.is_empty(), "{:?}", diag.notes());
    }

    #[test]
    fn missing_sgdisk_is_logged_not_silent() {
        let mut h = host();
        h.tools.clear();
        let (o, e, _) = run(&h);
        assert!(o.starts_with("DISK path=/dev/nvme0n1 "));
        assert!(o.ends_with(" table=unknown\n"), "{o}");
        assert!(!o.contains("PART"));
        assert_eq!(e, "缺 sgdisk，跳过 /dev/nvme0n1 的分区探测\n");
    }

    /// 读不出的盘：DISK 照列（table=unreadable）、不列 PART / FREE、ERR + `!!`、退出码 1；不进 Diag（已经明确报了）
    fn assert_unreadable(h: &FakeHost, why: &str) {
        let (rc, o, e, diag) = run_rc(h);
        assert_eq!(rc, 1);
        assert_eq!(
            o,
            "DISK path=/dev/nvme0n1 size_mib=488386 model=SAMSUNG%20MZ9L4512HBLU-00B07 removable=0 tran=nvme medium=no table=unreadable\n"
        );
        let mut el = e.lines();
        assert_eq!(el.next(), Some("ERR code=disk-unreadable disk=/dev/nvme0n1 touched=no"));
        let human = el.next().unwrap();
        assert!(human.starts_with("!! 读不出 /dev/nvme0n1 的分区表") && human.contains(why), "{human}");
        assert_eq!(el.next(), None);
        assert!(diag.is_empty(), "{:?}", diag.notes());
    }

    #[test]
    fn unreadable_disk_is_reported_not_free() {
        // S1（2026-10-06 修）：原来 sgdisk -p 读失败时按 2048 / 总扇区−2048 报一整块空闲 —— 有数据的盘被当成空盘
        let mut h = host();
        h.cmds.remove("sgdisk -p /dev/nvme0n1"); // 起不来
        assert_unreadable(&h, "没有正常结束");
        // 打不开（真机上是 rc=2 "Problem opening … for reading! Error is 2."）
        let h = host().cmd_err(
            "sgdisk -p /dev/nvme0n1",
            2,
            "",
            "Problem opening /dev/nvme0n1 for reading! Error is 2.\nThe specified file does not exist!\n",
        );
        assert_unreadable(&h, "退出码 2：Problem opening");
        // ★ 整块盘读都 EIO（dm-error 实测）：退出码 0、stdout 是一张空表 —— 只有 stderr 上的读错误说明真相
        let h = host().cmd_err(
            "sgdisk -p /dev/nvme0n1",
            0,
            "Creating new GPT entries in memory.\nDisk /tmp/gk3err: 6291456 sectors, 3.0 GiB\nFirst usable sector is 34, last usable sector is 6291422\n\nNumber  Start (sector)    End (sector)  Size       Code  Name\n",
            "Warning! Read error 5; strange behavior now likely!\nWarning! Read error 5; strange behavior now likely!\n",
        );
        assert_unreadable(&h, "Read error 5");
        // 只有备份 GPT 读不到（前 1 MiB 可读）：分区表读得出来，但这块盘在报 I/O 错 —— 一样不碰
        let h = host().cmd_err("sgdisk -p /dev/nvme0n1", 0, P, "Warning! Error 5 reading partition table for CRC check!\n");
        assert_unreadable(&h, "Error 5 reading");
        // 退出码 0 但没有可用扇区那一行
        let h = host().cmd("sgdisk -p /dev/nvme0n1", 0, "something else\n");
        assert_unreadable(&h, "没有可用扇区");
    }

    #[test]
    fn partition_named_read_error_is_fine() {
        // 读错误只在 stderr 里找：stdout 里一个叫 "read error 1 reading" 的分区不该把整块盘判成读不出
        let h = host().cmd(
            "sgdisk -p /dev/nvme0n1",
            0,
            &format!("{P}   4       200000001       200100000   48.8 MiB    8300  read error 1 reading\n"),
        );
        let h = h.cmd(
            "sgdisk -i 4 /dev/nvme0n1",
            0,
            "Partition GUID code: 0FC63DAF-8483-4772-8E79-3D69D8477DE4 (x)\nPartition name: 'read error 1 reading'\n",
        );
        let (o, _, _) = run(&h);
        assert!(o.contains(" table=gpt\n"), "{o}");
        assert!(o.contains("name=read%20error%201%20reading "), "{o}");
    }

    #[test]
    fn mbr_disk_is_listed_and_marked() {
        // MBR 盘照列（sgdisk 在内存里转出来的样子），DISK 上标 table=mbr —— 界面据此只给整盘清空
        let h = host()
            .cmd(
                "sgdisk -p /dev/nvme0n1",
                0,
                &format!("\n***\nFound invalid GPT and valid MBR; converting MBR to GPT format\nin memory. \n***\n\n{P}"),
            )
            .cmd("blkid -p -o value -s PTTYPE /dev/nvme0n1", 0, "dos\n");
        let (o, _, _) = run(&h);
        assert!(o.contains("medium=no table=mbr\n"), "{o}");
        assert_eq!(o.matches("\nPART ").count(), 3, "{o}");
        // 混合 MBR / 坏了主 GPT 头：blkid 说 gpt、sgdisk 没有那句 ⇒ gpt；只剩保护性 MBR：PMBR ⇒ gpt
        for pt in ["gpt\n", "PMBR\n", ""] {
            let h = host().cmd("blkid -p -o value -s PTTYPE /dev/nvme0n1", if pt.is_empty() { 2 } else { 0 }, pt);
            assert!(run(&h).0.contains(" table=gpt\n"));
        }
    }

    #[test]
    fn medium_detection() {
        let mut h = host();
        h.cmds.insert("findmnt -no SOURCE /media/gk3".into(), (0, b"/dev/nvme0n1p3\n".to_vec(), vec![]));
        h.cmds.insert("lsblk -no PKNAME /dev/nvme0n1p3".into(), (0, b"nvme0n1\n".to_vec(), vec![]));
        let (o, _, _) = run(&h);
        assert!(o.contains("tran=nvme medium=yes table=gpt\n"));
        assert!(o.contains("os=windows medium=yes\n"));
        assert!(o.contains("os=esp medium=no\n"));
    }

    #[test]
    fn small_and_empty_model() {
        let mut h = host();
        h.files.insert("/sys/block/nvme0n1/device/model".into(), b"   \n".to_vec());
        h.files.insert("/sys/block/nvme0n1/size".into(), b"2097151\n".to_vec()); // < 1 GiB
        let (o, _, _) = run(&h);
        assert_eq!(o, "");
        h.files.insert("/sys/block/nvme0n1/size".into(), b"2097152\n".to_vec());
        let (o, _, _) = run(&h);
        assert!(o.starts_with("DISK path=/dev/nvme0n1 size_mib=1024 model=? "), "{o}");
    }

    #[test]
    fn guess_os_table() {
        assert_eq!(guess_os(b"x", b"esp", b""), "esp");
        assert_eq!(guess_os(b"x", b"gk3rescue", b"ext4"), "linux");
        assert_eq!(guess_os(b"DE94BBA4-06D1-4D40-A16A-BFD50179D6AC", b"Basic data partition", b"ntfs"), "winre");
        assert_eq!(guess_os(b"x", b"", b"BitLocker"), "");
    }
}
