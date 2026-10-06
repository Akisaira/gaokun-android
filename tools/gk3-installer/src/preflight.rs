//! `gk3_preflight`：这台机器能不能装（installer-lib.sh:257-326、:328-349、:351-385）。一项一行：
//!
//!   CHECK id=root ok=yes|no
//!   CHECK id=uefi ok=yes|no
//!   CHECK id=model ok=yes|no|unknown value=… [skipped=yes]
//!   CHECK id=bios ok=yes value=…
//!   CHECK id=secureboot ok=yes|no|unknown value=disabled|enabled|
//!   CHECK id=tools ok=yes | ok=no missing=a,b pkgs=p,q
//!   CHECK id=power ok=yes|no|unknown value=<电量> ac=yes|no min=<门槛>

use std::io;

use crate::exec::Cmd;
use crate::host::{capture, cat, Diag, Host};
use crate::protocol::{Out, Record};
use crate::sh;

/// 预检要求的工具（installer-lib.sh:312）
const TOOLS: [&str; 11] = ["sgdisk", "partprobe", "blkid", "lsblk", "findmnt", "mkfs.vfat", "mkfs.ext4", "dd", "od", "zstd", "python3"];

/// installer-lib.sh:331-349 `gk3__tool_pkg`
pub fn tool_pkg(t: &str) -> &str {
    match t {
        "sgdisk" => "gdisk",
        "partprobe" => "parted",
        "blkid" | "lsblk" | "findmnt" => "util-linux",
        "mkfs.vfat" => "dosfstools",
        "mkfs.ext4" | "resize2fs" | "e2fsck" | "chattr" => "e2fsprogs",
        "ntfsresize" | "ntfscat" | "ntfs-3g" | "mkntfs" => "ntfs-3g",
        "dd" | "od" | "sha256sum" => "coreutils",
        "zstd" => "zstd",
        "python3" => "python3",
        "systemd-run" | "systemd-inhibit" => "systemd",
        other => other,
    }
}

/// `sed -n 's/.*Hardware name: [^ ]* \([^/,]*\).*/\1/p'`（贪婪的 .* ⇒ 从最后一个能匹配的位置开始）
fn hw_model(line: &[u8]) -> Vec<u8> {
    const K: &[u8] = b"Hardware name: ";
    let mut end = line.len();
    while let Some(i) = sh::rfind(line.get(..end).unwrap_or(&[]), K) {
        let rest = line.get(i + K.len()..).unwrap_or(&[]);
        if let Some(sp) = rest.iter().position(|&c| c == b' ') {
            let cap = rest.get(sp + 1..).unwrap_or(&[]);
            let n = cap.iter().take_while(|&&c| c != b'/' && c != b',').count();
            return cap.get(..n).unwrap_or(&[]).to_vec();
        }
        end = i + K.len() - 1;
    }
    Vec::new()
}

/// `sed -n 's/.*, BIOS \([^ ]*\).*/\1/p'`
fn hw_bios(line: &[u8]) -> Vec<u8> {
    const K: &[u8] = b", BIOS ";
    match sh::rfind(line, K) {
        Some(i) => {
            let rest = line.get(i + K.len()..).unwrap_or(&[]);
            let n = rest.iter().take_while(|&&c| c != b' ').count();
            rest.get(..n).unwrap_or(&[]).to_vec()
        }
        None => Vec::new(),
    }
}

pub fn preflight(host: &dyn Host, out: &mut Out, diag: &mut Diag) -> io::Result<i32> {
    // dmesg 里那行 "Hardware name: …"，只在 sysfs 读不到时才去取（与 shell 版的 gk3__hwline 一样懒）
    let mut hwline: Option<Vec<u8>> = None;
    let mut hw = |diag: &mut Diag| -> Vec<u8> {
        hwline
            .get_or_insert_with(|| {
                let d = capture(host, &Cmd::new("dmesg"), &[0], diag);
                sh::lines(&d).into_iter().find(|l| sh::find(l, b"Hardware name:").is_some()).map(|l| l.to_vec()).unwrap_or_default()
            })
            .clone()
    };

    let uid = capture(host, &Cmd::new("id").arg("-u"), &[0], diag);
    out.record(&Record::new("CHECK").raw("id", "root").raw("ok", if uid == b"0" { "yes" } else { "no" }))?;
    out.record(&Record::new("CHECK").raw("id", "uefi").raw("ok", if host.is_dir("/sys/firmware/efi") { "yes" } else { "no" }))?;

    let mut v = cat(host, "/sys/class/dmi/id/product_name").unwrap_or_default();
    if v.is_empty() {
        v = hw_model(&hw(diag));
    }
    let skip_model = host.env("GK3_SKIP_MODEL_CHECK").filter(|s| !s.is_empty()).as_deref().unwrap_or("0") == "1";
    let r = Record::new("CHECK").raw("id", "model");
    let r = if skip_model {
        r.raw("ok", "unknown").enc("value", if v.is_empty() { b"?".to_vec() } else { v.clone() }).raw("skipped", "yes")
    } else {
        match v.as_slice() {
            b"GK-W7X" => r.raw("ok", "yes").raw("value", &v),
            b"" => r.raw("ok", "unknown").raw("value", ""),
            _ => r.raw("ok", "no").enc("value", &v),
        }
    };
    out.record(&r)?;

    let mut v = cat(host, "/sys/class/dmi/id/bios_version").unwrap_or_default();
    if v.is_empty() {
        v = hw_bios(&hw(diag));
    }
    out.record(&Record::new("CHECK").raw("id", "bios").raw("ok", "yes").enc("value", if v.is_empty() { b"?".to_vec() } else { v }))?;

    // efivarfs 的文件 = 4 字节属性 + 1 字节值（installer-lib.sh:278-282、:304-310）
    let sb = host.read("/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c").ok().and_then(|b| b.get(4).copied());
    let r = Record::new("CHECK").raw("id", "secureboot");
    out.record(&match sb {
        Some(0) => r.raw("ok", "yes").raw("value", "disabled"),
        Some(1) => r.raw("ok", "no").raw("value", "enabled"),
        _ => r.raw("ok", "unknown").raw("value", ""),
    })?;

    let mut missing: Vec<&str> = Vec::new();
    let mut pkgs: Vec<&str> = Vec::new();
    for t in TOOLS {
        if host.which(t).is_some() {
            continue;
        }
        missing.push(t);
        let p = tool_pkg(t);
        if !pkgs.contains(&p) {
            pkgs.push(p);
        }
    }
    let r = Record::new("CHECK").raw("id", "tools");
    out.record(&if missing.is_empty() {
        r.raw("ok", "yes")
    } else {
        r.raw("ok", "no").raw("missing", missing.join(",")).raw("pkgs", pkgs.join(","))
    })?;

    power_check(host, out)?;
    Ok(0)
}

/// installer-lib.sh:358-385 `gk3__power_check`
fn power_check(host: &dyn Host, out: &mut Out) -> io::Result<()> {
    let ps = host.env("GK3_POWER_SUPPLY_DIR").filter(|s| !s.is_empty()).unwrap_or_else(|| "/sys/class/power_supply".into());
    let min = host.env("GK3_POWER_MIN_PCT").filter(|s| !s.is_empty()).unwrap_or_else(|| "15".into());
    let entries = host.glob(&ps);
    let mut bat: Option<String> = None;
    if host.readable(&format!("{ps}/gaokun-ec-battery/capacity")) {
        bat = Some(format!("{ps}/gaokun-ec-battery"));
    } else {
        for d in &entries {
            if cat(host, &format!("{d}/type")).as_deref() == Some(b"Battery") && host.readable(&format!("{d}/capacity")) {
                bat = Some(d.clone());
                break;
            }
        }
    }
    // 接着电源：任何一个不是电池的 power_supply 报 online=1，或者电池自己说在充电
    let mut ac = false;
    for d in &entries {
        let t = cat(host, &format!("{d}/type")).unwrap_or_default();
        if !t.is_empty() && t != b"Battery" && cat(host, &format!("{d}/online")).as_deref() == Some(b"1") {
            ac = true;
            break;
        }
    }
    if let Some(b) = &bat {
        if cat(host, &format!("{b}/status")).as_deref() == Some(b"Charging") {
            ac = true;
        }
    }
    let cap = bat.as_ref().and_then(|b| cat(host, &format!("{b}/capacity"))).unwrap_or_default();
    let ac_s = if ac { "yes" } else { "no" };
    let r = Record::new("CHECK").raw("id", "power");
    let r = if cap.is_empty() || !cap.iter().all(u8::is_ascii_digit) {
        r.raw("ok", "unknown").raw("value", "")
    } else {
        // [ "$cap" -ge "$min" ] || [ "$ac" = yes ]（min 不是整数 ⇒ 测试出错 ⇒ 假）
        let ge = matches!((sh::test_int(&cap), sh::test_int(min.as_bytes())), (Some(c), Some(m)) if c >= m);
        r.raw("ok", if ge || ac { "yes" } else { "no" }).raw("value", &cap)
    };
    out.record(&r.raw("ac", ac_s).raw("min", &min))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::fake::FakeHost;

    fn run(h: &FakeHost) -> String {
        let (mut o, mut e) = (Vec::new(), Vec::new());
        assert_eq!(preflight(h, &mut Out::new(&mut o, &mut e), &mut Diag::default()).unwrap(), 0);
        String::from_utf8(o).unwrap()
    }

    fn gaokun() -> FakeHost {
        let mut h = FakeHost::default()
            .cmd("id -u", 0, "0\n")
            .file("/sys/class/dmi/id/product_name", "GK-W7X\n")
            .file("/sys/class/dmi/id/bios_version", "2.16\n")
            .file("/ps/gaokun-ec-battery/type", "Battery\n")
            .file("/ps/gaokun-ec-battery/capacity", "80\n")
            .file("/ps/gaokun-ec-battery/status", "Discharging\n")
            .file("/ps/gaokun-ec-adapter/type", "USB\n")
            .file("/ps/gaokun-ec-adapter/online", "0\n");
        h.dirs.push("/sys/firmware/efi".into());
        h.files.insert("/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c".into(), vec![6, 0, 0, 0, 0]);
        h.env.insert("GK3_POWER_SUPPLY_DIR".into(), "/ps".into());
        for t in TOOLS {
            h = h.tool(t);
        }
        h
    }

    #[test]
    fn all_good() {
        assert_eq!(
            run(&gaokun()),
            "CHECK id=root ok=yes\nCHECK id=uefi ok=yes\nCHECK id=model ok=yes value=GK-W7X\nCHECK id=bios ok=yes value=2.16\n\
CHECK id=secureboot ok=yes value=disabled\nCHECK id=tools ok=yes\nCHECK id=power ok=yes value=80 ac=no min=15\n"
        );
    }

    #[test]
    fn dmesg_fallback_and_missing_tools() {
        let mut h = gaokun();
        h.files.remove("/sys/class/dmi/id/product_name");
        h.files.remove("/sys/class/dmi/id/bios_version");
        h = h.cmd("dmesg", 0, "[    0.000000] Booting\n[    0.000000] Hardware name: HUAWEI GK-W7X/GK-W7X-PCB, BIOS 2.16 01/31/2023\n");
        h.tools.retain(|t| !["sgdisk", "partprobe", "blkid", "lsblk"].contains(&t.as_str()));
        let o = run(&h);
        assert!(o.contains("CHECK id=model ok=yes value=GK-W7X\n"), "{o}");
        assert!(o.contains("CHECK id=bios ok=yes value=2.16\n"));
        // 与 test-apply.sh 的 P 组同一个期望值
        assert!(o.contains("CHECK id=tools ok=no missing=sgdisk,partprobe,blkid,lsblk pkgs=gdisk,parted,util-linux\n"));
    }

    #[test]
    fn hw_line_parsing() {
        assert_eq!(hw_model(b"Hardware name: QEMU QEMU Virtual Machine, BIOS 1.0"), b"QEMU Virtual Machine");
        assert_eq!(hw_model(b"Hardware name: nospace"), b"");
        assert_eq!(hw_bios(b"Hardware name: A B, BIOS 2.17 x"), b"2.17");
        assert_eq!(hw_bios(b"nothing"), b"");
    }

    #[test]
    fn power_low_and_charging() {
        let mut h = gaokun();
        h.files.insert("/ps/gaokun-ec-battery/capacity".into(), b"9\n".to_vec());
        assert!(run(&h).ends_with("CHECK id=power ok=no value=9 ac=no min=15\n"));
        h.files.insert("/ps/gaokun-ec-adapter/online".into(), b"1\n".to_vec());
        assert!(run(&h).ends_with("CHECK id=power ok=yes value=9 ac=yes min=15\n"));
        h.files.retain(|k, _| !k.starts_with("/ps/"));
        assert!(run(&h).ends_with("CHECK id=power ok=unknown value= ac=no min=15\n"));
    }

    #[test]
    fn secureboot_and_model_variants() {
        let mut h = gaokun();
        h.files.insert("/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c".into(), vec![6, 0, 0, 0, 1]);
        h.files.insert("/sys/class/dmi/id/product_name".into(), b"GK-W7X Pro\n".to_vec());
        let o = run(&h);
        assert!(o.contains("CHECK id=secureboot ok=no value=enabled\n"));
        assert!(o.contains("CHECK id=model ok=no value=GK-W7X%20Pro\n"));
        h.env.insert("GK3_SKIP_MODEL_CHECK".into(), "1".into());
        assert!(run(&h).contains("CHECK id=model ok=unknown value=GK-W7X%20Pro skipped=yes\n"));
    }
}
