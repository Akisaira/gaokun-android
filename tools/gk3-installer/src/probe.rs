//! `gk3_probe`：列出磁盘 / 分区 / 空闲区（installer-lib.sh:131-225、:227-247）。
//!
//!   DISK path=/dev/nvme0n1 size_mib=488386 model=… removable=0 tran=nvme medium=no
//!   PART path=… num=1 start=2048 end=616447 size_mib=300 size_kib=307200 type=<GUID> name=… fs=vfat fslabel=… os=esp medium=no
//!   FREE disk=/dev/nvme0n1 start=616448 end=… size_mib=…
//!
//! 每一个字段的来源、默认值、编码与否都照 shell 版逐个搬过来（注释里写着对应的那一行）。
//! shell 版吞掉的失败（`2>/dev/null`、`|| echo 0`）这里照样按它的默认值走 —— 但都进了 [`Diag`]。

use std::io;

use crate::exec::Cmd;
use crate::gpt;
use crate::host::{capture, cat, Diag, Host};
use crate::protocol::{Out, Record};
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

/// `gk3_probe`。返回值 = shell 版的退出码（它总是 0）
pub fn probe(host: &dyn Host, out: &mut Out, diag: &mut Diag) -> io::Result<i32> {
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
        out.record(
            &Record::new("DISK")
                .raw("path", &dev)
                .num("size_mib", size_mib)
                .enc("model", &model)
                .raw("removable", &removable)
                .raw("tran", &tran)
                .raw("medium", is_medium),
        )?;
        probe_parts(host, out, diag, &dev, sectors)?;
    }
    Ok(0)
}

/// installer-lib.sh:174-216 `gk3__probe_parts`
fn probe_parts(host: &dyn Host, out: &mut Out, diag: &mut Diag, disk: &str, total_sectors: i64) -> io::Result<()> {
    if host.which("sgdisk").is_none() {
        // shell 版这里只打一行日志（gk3_log）就回 0 —— 界面上这块盘就像没有分区。原样照搬，日志同文
        out.log(&format!("缺 sgdisk，跳过 {disk} 的分区探测"))?;
        return Ok(());
    }
    // shell 版对同一块盘跑了 1 + 2×分区数 次 sgdisk；输出是确定的，这里每种只跑一次
    let p_out = capture(host, &Cmd::new("sgdisk").arg("-p").arg(disk), &[0], diag);
    let p = gpt::parse_print(&p_out);
    let first_usable = if p.first_usable.is_empty() { 2048 } else { int_or_note(&p.first_usable, 2048, "First usable sector", diag) };
    let last_usable = if p.last_usable.is_empty() {
        total_sectors - 2048
    } else {
        int_or_note(&p.last_usable, total_sectors - 2048, "last usable sector", diag)
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
    Ok(())
}

fn int_or_note(v: &[u8], dflt: i64, what: &str, diag: &mut Diag) -> i64 {
    match sh::arith_int(v) {
        Some(n) => n,
        None => {
            diag.note(format!("sgdisk 的 {what} 读不懂（{}），按 {dflt} 算", String::from_utf8_lossy(v)));
            dflt
        }
    }
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
            .cmd("sgdisk -p /dev/nvme0n1", 0, P);
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

    fn run(h: &FakeHost) -> (String, String, Diag) {
        let (mut o, mut e) = (Vec::new(), Vec::new());
        let mut diag = Diag::default();
        let rc = probe(h, &mut Out::new(&mut o, &mut e), &mut diag).unwrap();
        assert_eq!(rc, 0);
        (String::from_utf8(o).unwrap(), String::from_utf8(e).unwrap(), diag)
    }

    #[test]
    fn windows_disk() {
        let (o, e, diag) = run(&host());
        assert_eq!(
            o,
            "DISK path=/dev/nvme0n1 size_mib=488386 model=SAMSUNG%20MZ9L4512HBLU-00B07 removable=0 tran=nvme medium=no
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
        assert!(!o.contains("PART"));
        assert_eq!(e, "缺 sgdisk，跳过 /dev/nvme0n1 的分区探测\n");
    }

    #[test]
    fn sgdisk_failure_falls_back_like_shell_but_is_noted() {
        // sgdisk -p 起不来：shell 版按 2048 / 总扇区−2048 报一整块空闲（它看不出来是读失败）——
        // 输出照搬，但 Diag 里有一笔（偏差清单里的"静默失败"S1）
        let mut h = host();
        h.cmds.remove("sgdisk -p /dev/nvme0n1");
        let (o, _, diag) = run(&h);
        assert!(o.contains("FREE disk=/dev/nvme0n1 start=2048 end=1000213168 "), "{o}");
        assert_eq!(diag.notes().len(), 1);
        assert!(diag.notes()[0].contains("sgdisk -p /dev/nvme0n1"));
    }

    #[test]
    fn medium_detection() {
        let mut h = host();
        h.cmds.insert("findmnt -no SOURCE /media/gk3".into(), (0, b"/dev/nvme0n1p3\n".to_vec(), vec![]));
        h.cmds.insert("lsblk -no PKNAME /dev/nvme0n1p3".into(), (0, b"nvme0n1\n".to_vec(), vec![]));
        let (o, _, _) = run(&h);
        assert!(o.contains("tran=nvme medium=yes\n"));
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
