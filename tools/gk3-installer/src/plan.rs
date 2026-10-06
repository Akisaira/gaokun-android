//! `gk3_plan`：算出分区方案（installer-lib.sh:378-575）。纯计算 + 只读的 sgdisk，不碰盘。
//!
//!   gk3_plan --disk D --mode wipe|alongside|reinstall --rescue yes|no
//!            [--region-start S --region-end E] [--esp PATH] [--userdata-mib N] [--keep-data yes|no] [--disk-size-mib N]
//!
//! 输出：`PLAN op=wipe|mkpart|useesp|reuse …` 若干行 + `PLANSUM …`；失败是 stdout 上的一行 `PLANERR msg=…`、退出码 1。
//! ⚠️ PLANERR 之前已经打出去的 PLAN 行不撤回（shell 版就是这样：例如 useesp 在空间检查之前），对拍要求顺序也一样。

use std::io;

use crate::exec::Cmd;
use crate::gpt;
use crate::host::{capture, Diag, Host};
use crate::protocol::{Out, Record};
use crate::sh;

// ── 布局常量（installer-lib.sh:52-62、:392-394）。shell 版是无条件赋值，环境变量改不了它们，这里也一样 ──
pub const ESP_MIB: i64 = 300;
pub const MISC_MIB: i64 = 4;
pub const METADATA_MIB: i64 = 32;
pub const SUPER_MIB: i64 = 12288;
pub const BOOT_MIB: i64 = 64;
pub const RESCUE_MIB: i64 = 1024;
pub const USERDATA_MIN_MIB: i64 = 8192;
/// installer-lib.sh:65
pub const ESP_NEED_MIB: i64 = 150;
/// installer-lib.sh:67
pub const ESP_REINSTALL_NEED_MIB: i64 = 16;
pub const TYPE_ESP: &str = "ef00";
pub const TYPE_DATA: &str = "8300";

/// 我们的分区名（alongside 时查重用；installer-lib.sh:426）
const OUR_NAMES: &str = " misc metadata boot_a boot_b super userdata gk3rescue ";

#[derive(Debug, Default)]
struct Args {
    disk: String,
    mode: String,
    rescue: String,
    rstart: String,
    rend: String,
    esp: String,
    ud_mib: String,
    keep: String,
    fake_disk_mib: Option<String>,
}

/// 失败：一行 `PLANERR msg=<代码> [k=v…]`（stdout），退出码 1
fn planerr(out: &mut Out, msg: &str, kv: &[(&str, String)]) -> io::Result<i32> {
    let mut r = Record::new("PLANERR").raw("msg", msg);
    for (k, v) in kv {
        r = r.raw(k, v);
    }
    out.record(&r)?;
    Ok(1)
}

pub fn plan(host: &dyn Host, args: &[String], out: &mut Out, diag: &mut Diag) -> io::Result<i32> {
    let mut a = Args { mode: "wipe".into(), rescue: "no".into(), keep: "no".into(), ..Default::default() };
    let mut it = args.iter();
    while let Some(flag) = it.next() {
        let slot = match flag.as_str() {
            "--disk" => &mut a.disk,
            "--keep-data" => &mut a.keep,
            "--mode" => &mut a.mode,
            "--rescue" => &mut a.rescue,
            "--region-start" => &mut a.rstart,
            "--region-end" => &mut a.rend,
            "--esp" => &mut a.esp,
            "--userdata-mib" => &mut a.ud_mib,
            "--disk-size-mib" => a.fake_disk_mib.get_or_insert_with(String::new),
            other => return planerr(out, &format!("unknown-arg:{other}"), &[]),
        };
        match it.next() {
            Some(v) => *slot = v.clone(),
            // ⚠️ 偏差 D1：shell 版这里 `shift 2` 失败、$# 不变 —— 死循环，界面永远停在"正在计算"
            None => return planerr(out, &format!("missing-value:{flag}"), &[]),
        }
    }
    if a.disk.is_empty() {
        return planerr(out, "no-disk", &[]);
    }
    // ⑤ MBR 盘（installer-lib.sh gk3_plan 的 ⑤；S2，2026-10-06 两边一起修）：写表一定失败，而且失败在别的步骤动过盘之后
    //   （installer-lib.sh gk3__table_guard 的注释）。
    //   整盘清空不拦（本来就要抹掉分区表）；在重新安装的分支之前（原来重新安装绕过了它）。
    //   原来的判据找 "MBR only"，gdisk 1.0.10 从不输出它 ⇒ 从没触发过；判据见 gpt::classify。
    //   读不出（Unreadable）这里不拦：方案是纯计算，读不出由 gk3_probe 报、由 gk3_apply 在动盘前拦
    if a.mode != "wipe" && gpt::read_table(host, &a.disk).kind == gpt::Kind::Mbr {
        return planerr(out, "mbr-disk", &[]);
    }
    if a.mode == "reinstall" {
        return plan_reinstall(host, &a, out, diag);
    }

    let has_sgdisk = host.which("sgdisk").is_some();
    // ① 分区名查重（installer-lib.sh:415-437）：整盘模式不查
    if a.mode != "wipe" && has_sgdisk {
        let p = gpt::parse_print(&capture(host, &Cmd::new("sgdisk").arg("-p").arg(a.disk.clone()), &[0], diag));
        let mut dup = String::new();
        for row in &p.rows {
            let n = String::from_utf8_lossy(&row.num).into_owned();
            let nm = gpt::parse_info(&capture(host, &Cmd::new("sgdisk").arg("-i").arg(n).arg(a.disk.clone()), &[0], diag)).name;
            let nm = String::from_utf8_lossy(&nm).into_owned();
            if nm == "esp" {
                continue;
            }
            // case " misc … " in *" $nm "*)：子串匹配（名字里带空格的 "misc metadata" 也会中 —— 照搬）
            if OUR_NAMES.contains(&format!(" {nm} ")) {
                dup.push(' ');
                dup.push_str(&nm);
            }
        }
        if !dup.is_empty() {
            return planerr(out, "partlabel-conflict", &[("names", sh::join_words_comma(&dup))]);
        }
    }
    let (cur, last, last_raw);
    if a.mode == "wipe" {
        // total_mib=${GK3_FAKE_DISK_MIB:-} —— 命令行的 --disk-size-mib 写的就是这个全局变量
        let fake = a.fake_disk_mib.clone().or_else(|| host.env("GK3_FAKE_DISK_MIB")).filter(|s| !s.is_empty());
        let total_mib: i64 = match fake {
            Some(f) => {
                // [ "$total_mib" -gt 0 ] 用的是 test 的整数规则；后面的算术要规范的十进制（偏差 D2）
                if !sh::test_int(f.as_bytes()).is_some_and(|n| n > 0) {
                    return planerr(out, "cannot-size-disk", &[]);
                }
                match sh::canonical_int(&f) {
                    Some(n) => n,
                    None => return planerr(out, "bad-number:--disk-size-mib", &[]),
                }
            }
            None => {
                let p = format!("/sys/block/{}/size", sh::basename(&a.disk));
                let raw = crate::host::cat(host, &p).unwrap_or_else(|| b"0".to_vec());
                let sectors = match sh::arith_int(&raw) {
                    Some(s) => s,
                    None => {
                        diag.note(format!("{p} 不是整数（{}）", String::from_utf8_lossy(&raw)));
                        0
                    }
                };
                sectors / 2048
            }
        };
        if total_mib <= 0 {
            return planerr(out, "cannot-size-disk", &[]);
        }
        cur = 2048;
        last = total_mib * 2048 - 2048; // 尾部给备份 GPT 留 1 MiB
        last_raw = last.to_string();
        out.record(&Record::new("PLAN").raw("op", "wipe").raw("disk", &a.disk))?;
    } else {
        if a.rstart.is_empty() || a.rend.is_empty() {
            return planerr(out, "alongside-needs-region", &[]);
        }
        let Some(rs) = sh::canonical_int(&a.rstart) else {
            return planerr(out, "bad-number:--region-start", &[]);
        };
        let Some(re) = sh::canonical_int(&a.rend) else {
            return planerr(out, "bad-number:--region-end", &[]);
        };
        cur = (rs + 2047) / 2048 * 2048; // 起点向上对齐到 1 MiB
        last = re;
        last_raw = a.rend.clone();
        if a.esp.is_empty() {
            return planerr(out, "alongside-needs-existing-esp", &[]);
        }
        out.record(&Record::new("PLAN").raw("op", "useesp").raw("path", &a.esp).num("need_mib", ESP_NEED_MIB))?;
    }

    let avail_mib = (last - cur + 1) / 2048;
    let mut fixed = MISC_MIB + METADATA_MIB + BOOT_MIB * 2 + SUPER_MIB;
    if a.mode == "wipe" {
        fixed += ESP_MIB;
    }
    if a.rescue == "yes" {
        fixed += RESCUE_MIB;
    }
    let need = fixed + USERDATA_MIN_MIB;
    if avail_mib < need {
        return planerr(
            out,
            "not-enough-space",
            &[("avail_mib", avail_mib.to_string()), ("need_mib", need.to_string()), ("fixed_mib", fixed.to_string())],
        );
    }

    let mut userdata_mib = avail_mib - fixed;
    if !a.ud_mib.is_empty() {
        // 两道 [ -ge ] / [ -le ]：test 的整数规则（不是整数 ⇒ 测试出错 ⇒ 按"假"走）
        let t = sh::test_int(a.ud_mib.as_bytes());
        if !t.is_some_and(|n| n >= USERDATA_MIN_MIB) {
            return planerr(out, "userdata-too-small", &[("min_mib", USERDATA_MIN_MIB.to_string())]);
        }
        if !t.is_some_and(|n| n <= userdata_mib) {
            return planerr(out, "userdata-too-big", &[("max_mib", userdata_mib.to_string())]);
        }
        match sh::canonical_int(&a.ud_mib) {
            Some(n) => userdata_mib = n,
            None => return planerr(out, "bad-number:--userdata-mib", &[]),
        }
    }

    // 顺序即磁盘顺序，userdata 必须最后（installer-lib.sh:489-491）
    let mut gcur = cur;
    let mut emit = |out: &mut Out, name: &str, mib: i64, ty: &str| -> io::Result<()> {
        let start = gcur;
        let end = start + mib * 2048 - 1;
        out.record(
            &Record::new("PLAN")
                .raw("op", "mkpart")
                .raw("disk", &a.disk)
                .raw("num", "0")
                .raw("name", name)
                .num("start", start)
                .num("end", end)
                .num("size_mib", mib)
                .raw("type", ty),
        )?;
        gcur = end + 1;
        Ok(())
    };
    if a.mode == "wipe" {
        emit(out, "esp", ESP_MIB, TYPE_ESP)?;
    }
    emit(out, "misc", MISC_MIB, TYPE_DATA)?;
    emit(out, "metadata", METADATA_MIB, TYPE_DATA)?;
    emit(out, "boot_a", BOOT_MIB, TYPE_DATA)?;
    emit(out, "boot_b", BOOT_MIB, TYPE_DATA)?;
    emit(out, "super", SUPER_MIB, TYPE_DATA)?;
    if a.rescue == "yes" {
        emit(out, "gk3rescue", RESCUE_MIB, TYPE_DATA)?;
    }
    emit(out, "userdata", userdata_mib, TYPE_DATA)?;

    // ★ 最后一条不能越过可用区尾部 —— 独立再验一次（installer-lib.sh:505-510）
    if gcur - 1 > last {
        return planerr(out, "plan-overruns-region", &[("end", (gcur - 1).to_string()), ("limit", last_raw)]);
    }
    out.record(
        &Record::new("PLANSUM")
            .raw("mode", &a.mode)
            .raw("rescue", &a.rescue)
            .num("avail_mib", avail_mib)
            .num("fixed_mib", fixed)
            .num("userdata_mib", userdata_mib),
    )?;
    Ok(0)
}

/// installer-lib.sh:520-565 `gk3__plan_reinstall`：不改分区表，按 PARTLABEL 逐个复用
fn plan_reinstall(host: &dyn Host, a: &Args, out: &mut Out, diag: &mut Diag) -> io::Result<i32> {
    if host.which("sgdisk").is_none() {
        return planerr(out, "no-sgdisk", &[]);
    }
    if a.esp.is_empty() {
        return planerr(out, "reinstall-needs-esp", &[]);
    }
    // table：每行 "<名字> <号>"；后面按 awk 的 $1 / $2 认（名字里有空格时 $1 只是第一个词 —— 照搬）
    let p = gpt::parse_print(&capture(host, &Cmd::new("sgdisk").arg("-p").arg(a.disk.clone()), &[0], diag));
    let mut table: Vec<Vec<u8>> = Vec::new();
    for row in &p.rows {
        let n = String::from_utf8_lossy(&row.num).into_owned();
        let nm = gpt::parse_info(&capture(host, &Cmd::new("sgdisk").arg("-i").arg(n).arg(a.disk.clone()), &[0], diag)).name;
        let mut line = nm;
        line.push(b' ');
        line.extend_from_slice(&row.num);
        table.push(line);
    }
    let field = |line: &[u8], i: usize| -> Vec<u8> { sh::awk_fields(line).get(i).map(|f| f.to_vec()).unwrap_or_default() };
    let mut want = vec!["misc", "metadata", "boot_a", "boot_b", "super", "userdata"];
    if a.rescue == "yes" {
        want.push("gk3rescue");
    }
    let (mut miss, mut dup) = (String::new(), String::new());
    for nm in &want {
        let c = table.iter().filter(|l| field(l, 0) == nm.as_bytes()).count();
        if c == 0 {
            miss.push(' ');
            miss.push_str(nm);
        }
        if c > 1 {
            dup.push(' ');
            dup.push_str(nm);
        }
    }
    if !dup.is_empty() {
        return planerr(out, "reinstall-duplicate", &[("names", sh::join_words_comma(&dup))]);
    }
    if !miss.is_empty() {
        return planerr(out, "reinstall-missing", &[("names", sh::join_words_comma(&miss))]);
    }

    out.record(&Record::new("PLAN").raw("op", "useesp").raw("path", &a.esp).num("need_mib", ESP_REINSTALL_NEED_MIB))?;
    let (mut fixed, mut ud) = (0i64, 0i64);
    for nm in &want {
        let n = table.iter().find(|l| field(l, 0) == nm.as_bytes()).map(|l| field(l, 1)).unwrap_or_default();
        let n = String::from_utf8_lossy(&n).into_owned();
        let info = gpt::parse_info(&capture(host, &Cmd::new("sgdisk").arg("-i").arg(n.clone()).arg(a.disk.clone()), &[0], diag));
        // $(( (en - st + 1) / 2 ))：空值在 bash 算术里是 0（sgdisk 读不到这个分区时就是这样 —— 结果是下面的 part-small）
        let (Some(st), Some(en)) = (sh::arith_int(&info.first), sh::arith_int(&info.last)) else {
            // 偏差 D2：shell 版会把它当变量名 / 八进制算；sgdisk 不会输出这种东西
            return planerr(out, "reinstall-part-unreadable", &[("name", nm.to_string())]);
        };
        let kib = (en - st + 1) / 2;
        let mib = kib / 1024;
        // 下限按 KiB 比：本机的 misc 只有 1007 KiB（installer-lib.sh:546-549）
        let keep = a.keep == "yes";
        let (min, act) = match *nm {
            "super" => (SUPER_MIB * 1024, "write"),
            "boot_a" | "boot_b" => (BOOT_MIB * 1024, "write"),
            "misc" => (1000, "write"),
            "gk3rescue" => (RESCUE_MIB * 1024, "write"),
            "metadata" => (METADATA_MIB * 1024, if keep { "keep" } else { "format" }),
            _ => (USERDATA_MIN_MIB * 1024, if keep { "keep" } else { "format" }),
        };
        if kib < min {
            return planerr(
                out,
                "reinstall-part-small",
                &[("name", nm.to_string()), ("have_kib", kib.to_string()), ("need_kib", min.to_string())],
            );
        }
        out.record(
            &Record::new("PLAN")
                .raw("op", "reuse")
                .raw("name", nm)
                .raw("path", gpt::partpath(&a.disk, &n))
                .raw("num", &n)
                .raw("start", &info.first)
                .raw("end", &info.last)
                .num("size_mib", mib)
                .num("size_kib", kib)
                .raw("action", act),
        )?;
        if *nm == "userdata" {
            ud = mib;
        } else {
            fixed += mib;
        }
    }
    out.record(
        &Record::new("PLANSUM")
            .raw("mode", "reinstall")
            .raw("rescue", &a.rescue)
            .raw("keep_data", &a.keep)
            .num("avail_mib", fixed + ud)
            .num("fixed_mib", fixed)
            .num("userdata_mib", ud),
    )?;
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::fake::FakeHost;

    fn run(h: &FakeHost, args: &[&str]) -> (i32, String) {
        let (mut o, mut e) = (Vec::new(), Vec::new());
        let args: Vec<String> = args.iter().map(|s| s.to_string()).collect();
        let rc = plan(h, &args, &mut Out::new(&mut o, &mut e), &mut Diag::default()).unwrap();
        (rc, String::from_utf8(o).unwrap())
    }

    /// 不变量（与 scripts/live/test-plan.sh 相同）：不重叠、不越界、1 MiB 对齐、名字齐全
    fn check(out: &str, lo: i64, hi: i64, names: &[&str]) {
        let mut prev = lo - 1;
        let mut got = Vec::new();
        for l in out.lines().filter(|l| l.starts_with("PLAN op=mkpart")) {
            let f = |k: &str| l.split(' ').find_map(|t| t.strip_prefix(&format!("{k}="))).unwrap().to_string();
            let (s, e): (i64, i64) = (f("start").parse().unwrap(), f("end").parse().unwrap());
            assert!(s > prev && s >= lo && e <= hi && s % 2048 == 0, "{l}");
            prev = e;
            got.push(f("name"));
        }
        assert_eq!(got, names);
    }

    #[test]
    fn wipe_with_rescue() {
        let (rc, o) =
            run(&FakeHost::default(), &["--disk", "/dev/nvme0n1", "--mode", "wipe", "--rescue", "yes", "--disk-size-mib", "476940"]);
        assert_eq!(rc, 0);
        assert!(o.starts_with("PLAN op=wipe disk=/dev/nvme0n1\nPLAN op=mkpart disk=/dev/nvme0n1 num=0 name=esp start=2048 end=616447 size_mib=300 type=ef00\n"), "{o}");
        check(&o, 2048, 476940 * 2048 - 2048, &["esp", "misc", "metadata", "boot_a", "boot_b", "super", "gk3rescue", "userdata"]);
        assert!(o.ends_with("PLANSUM mode=wipe rescue=yes avail_mib=476938 fixed_mib=13776 userdata_mib=463162\n"), "{o}");
    }

    #[test]
    fn alongside_and_errors() {
        let rs = 100_000_000i64;
        let re = rs + 25 * 1024 * 2048 - 1;
        let (rc, o) = run(
            &FakeHost::default(),
            &[
                "--disk",
                "/dev/nvme0n1",
                "--mode",
                "alongside",
                "--rescue",
                "no",
                "--region-start",
                &rs.to_string(),
                "--region-end",
                &re.to_string(),
                "--esp",
                "/dev/nvme0n1p1",
            ],
        );
        assert_eq!(rc, 0);
        assert!(o.starts_with("PLAN op=useesp path=/dev/nvme0n1p1 need_mib=150\n"));
        check(&o, rs, re, &["misc", "metadata", "boot_a", "boot_b", "super", "userdata"]);

        let re2 = rs + 10 * 1024 * 2048 - 1;
        let (rc, o) = run(
            &FakeHost::default(),
            &[
                "--disk",
                "/dev/x",
                "--mode",
                "alongside",
                "--region-start",
                &rs.to_string(),
                "--region-end",
                &re2.to_string(),
                "--esp",
                "/dev/x1",
            ],
        );
        assert_eq!(rc, 1);
        assert_eq!(
            o,
            "PLAN op=useesp path=/dev/x1 need_mib=150\nPLANERR msg=not-enough-space avail_mib=10239 need_mib=20644 fixed_mib=12452\n"
        );

        let (rc, o) = run(&FakeHost::default(), &["--disk", "/dev/x", "--mode", "alongside", "--region-start", "1", "--region-end", "2"]);
        assert_eq!((rc, o.as_str()), (1, "PLANERR msg=alongside-needs-existing-esp\n"));
        let (_, o) = run(&FakeHost::default(), &["--disk", "/dev/x", "--mode", "alongside"]);
        assert_eq!(o, "PLANERR msg=alongside-needs-region\n");
        let (_, o) = run(&FakeHost::default(), &["--mode", "wipe"]);
        assert_eq!(o, "PLANERR msg=no-disk\n");
        let (_, o) = run(&FakeHost::default(), &["--disk", "/dev/x", "--bogus", "1"]);
        assert_eq!(o, "PLANERR msg=unknown-arg:--bogus\n");
        // 偏差 D1：shell 版在这里死循环
        let (rc, o) = run(&FakeHost::default(), &["--disk", "/dev/x", "--mode"]);
        assert_eq!((rc, o.as_str()), (1, "PLANERR msg=missing-value:--mode\n"));
    }

    #[test]
    fn userdata_bounds() {
        let base = ["--disk", "/dev/x", "--mode", "wipe", "--disk-size-mib", "40960"];
        let with = |ud: &str| {
            let mut v = base.to_vec();
            v.extend(["--userdata-mib", ud]);
            run(&FakeHost::default(), &v).1
        };
        assert!(with("8191").ends_with("PLANERR msg=userdata-too-small min_mib=8192\n"));
        assert!(with("abc").ends_with("PLANERR msg=userdata-too-small min_mib=8192\n")); // test 出错 ⇒ 假，与 shell 相同
        assert!(with("999999").ends_with("PLANERR msg=userdata-too-big max_mib=28206\n"));
        assert!(with("9000").contains("name=userdata start=26118144 end=44550143 size_mib=9000 "));
    }

    #[test]
    fn partlabel_conflict_and_reinstall() {
        let p = "First usable sector is 34, last usable sector is 83886046\n   1   2048   616447   300 MiB EF00 esp\n   2  616448  624639  4 MiB 8300 misc\n   3  624640  690175  32 MiB 8300 metadata\n";
        let h = FakeHost::default()
            .tool("sgdisk")
            .cmd("sgdisk -p /dev/x", 0, p)
            .cmd("sgdisk -i 1 /dev/x", 0, "Partition name: 'esp'\n")
            .cmd("sgdisk -i 2 /dev/x", 0, "First sector: 616448 (at x)\nLast sector: 624639 (at y)\nPartition name: 'misc'\n")
            .cmd("sgdisk -i 3 /dev/x", 0, "First sector: 624640 (at x)\nLast sector: 690175 (at y)\nPartition name: 'metadata'\n");
        let (rc, o) = run(&h, &["--disk", "/dev/x", "--mode", "alongside", "--region-start", "1", "--region-end", "2", "--esp", "/dev/x1"]);
        assert_eq!((rc, o.as_str()), (1, "PLANERR msg=partlabel-conflict names=misc,metadata\n"));
        let (rc, o) = run(&h, &["--disk", "/dev/x", "--mode", "reinstall", "--esp", "/dev/x1"]);
        assert_eq!((rc, o.as_str()), (1, "PLANERR msg=reinstall-missing names=boot_a,boot_b,super,userdata\n"));
        let (_, o) = run(&h, &["--disk", "/dev/x", "--mode", "reinstall"]);
        assert_eq!(o, "PLANERR msg=reinstall-needs-esp\n");
    }

    /// gdisk 1.0.10 对 sfdisk 建的 dos 盘的 `sgdisk -p`（2026-10-06 test-env 容器实录；那句提示在 stdout 上）
    const P_MBR: &str = "
***************************************************************
Found invalid GPT and valid MBR; converting MBR to GPT format
in memory. 
***************************************************************

Disk /dev/x: 62914560 sectors, 30.0 GiB
First usable sector is 34, last usable sector is 62914526

Number  Start (sector)    End (sector)  Size       Code  Name
   1            2048          206847   100.0 MiB   0700  Microsoft basic data
";

    #[test]
    fn mbr_disk_refused_except_wipe() {
        // S2（2026-10-06 修）：原来找 "MBR only"、从不触发。现在 blkid 说 dos 或者 sgdisk 说要转换 ⇒ mbr-disk
        let h = FakeHost::default().tool("sgdisk").cmd("sgdisk -p /dev/x", 0, P_MBR).cmd("blkid -p -o value -s PTTYPE /dev/x", 0, "dos\n");
        let along = ["--disk", "/dev/x", "--mode", "alongside", "--region-start", "206848", "--region-end", "62914526", "--esp", "/dev/x1"];
        assert_eq!(run(&h, &along), (1, "PLANERR msg=mbr-disk\n".to_string()));
        // 重新安装原来在这道检查之前就分岔走了
        assert_eq!(run(&h, &["--disk", "/dev/x", "--mode", "reinstall", "--esp", "/dev/x1"]), (1, "PLANERR msg=mbr-disk\n".to_string()));
        // 整盘清空是 MBR 盘唯一能走的路：照常出方案，而且不去读盘
        let (rc, o) = run(&h, &["--disk", "/dev/x", "--mode", "wipe", "--disk-size-mib", "40960"]);
        assert_eq!(rc, 0, "{o}");
        // 只有 blkid 认出来（sgdisk 换了措辞）、只有 sgdisk 那句（没有 blkid）：都算
        let mut only_blkid = h;
        only_blkid
            .cmds
            .insert("sgdisk -p /dev/x".into(), (0, b"First usable sector is 34, last usable sector is 62914526\n".to_vec(), vec![]));
        assert_eq!(run(&only_blkid, &along).1, "PLANERR msg=mbr-disk\n");
        let only_banner = FakeHost::default().tool("sgdisk").cmd("sgdisk -p /dev/x", 0, P_MBR);
        assert_eq!(run(&only_banner, &along).1, "PLANERR msg=mbr-disk\n");
        // 原来的判据那句 "MBR only" 不再有意义：GPT 盘上照常出方案
        let gpt = FakeHost::default()
            .tool("sgdisk")
            .cmd("sgdisk -p /dev/x", 0, "  MBR: MBR only\nFirst usable sector is 34, last usable sector is 62914526\n")
            .cmd("blkid -p -o value -s PTTYPE /dev/x", 0, "gpt\n");
        assert_eq!(run(&gpt, &along).0, 0);
    }

    #[test]
    fn unreadable_disk_is_not_planned_against_but_not_refused_here() {
        // 读不出的盘：方案照算（纯计算 —— 自测拿不存在的盘算），由 gk3_apply 的 gk3__table_guard 在动盘前拦
        let h = FakeHost::default().tool("sgdisk");
        let (rc, _) = run(
            &h,
            &["--disk", "/dev/x", "--mode", "alongside", "--region-start", "206848", "--region-end", "62914526", "--esp", "/dev/x1"],
        );
        assert_eq!(rc, 0);
    }
}
