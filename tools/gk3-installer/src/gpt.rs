//! 读分区表：解析 `sgdisk -p` / `sgdisk -i <号>` 的输出，与 installer-lib.sh 里那几条 sed / awk / cut 逐个对应。
//!
//! ★ 兼容阶段（设计稿 §5 阶段 1）故意【不】自己解析 GPT：数据来源与 shell 版是同一个 sgdisk，
//!   对拍出的差异就只能来自逻辑，不会来自"两个解析器对同一块盘理解不同"。
//!   自己读 GPT（并与 sgdisk 交叉核对）是阶段 3 的事。
//!
//! 实测的输出样本（2026-10-06，test-env 容器里的 gdisk 1.0.10）见本文件末尾的测试。

use crate::exec::{Cmd, Status};
use crate::host::Host;
use crate::sh;

/// `sgdisk -p <盘>` 里我们用到的东西
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Print {
    /// `sed -n 's/^First usable sector is \([0-9]*\).*/\1/p'` 的结果（经 `$(…)`）
    pub first_usable: Vec<u8>,
    /// `sed -n 's/.*last usable sector is \([0-9]*\).*/\1/p'`
    pub last_usable: Vec<u8>,
    /// `awk '/^ *[0-9]+ /{print $1" "$2" "$3}'`，原顺序（分区号顺序）
    pub rows: Vec<Row>,
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Row {
    pub num: Vec<u8>,
    pub start: Vec<u8>,
    pub end: Vec<u8>,
}

/// `^ *[0-9]+ `：行首若干空格、至少一个数字、紧跟一个空格
fn is_part_row(line: &[u8]) -> bool {
    let rest = match line.iter().position(|&c| c != b' ') {
        Some(i) => line.get(i..).unwrap_or(&[]),
        None => return false,
    };
    let nd = rest.iter().take_while(|c| c.is_ascii_digit()).count();
    nd > 0 && rest.get(nd) == Some(&b' ')
}

/// sed 的 `\([0-9]*\)`：取开头的数字（可能为空）
fn leading_digits(v: &[u8]) -> &[u8] {
    let n = v.iter().take_while(|c| c.is_ascii_digit()).count();
    v.get(..n).unwrap_or(&[])
}

/// sed -n 's/…/\1/p' 对每个匹配行打印一行，再经 `$(…)`：用 \n 连起来、去掉结尾换行
fn join_subst(parts: Vec<&[u8]>) -> Vec<u8> {
    let mut v = Vec::new();
    for p in parts {
        v.extend_from_slice(p);
        v.push(b'\n');
    }
    sh::subst(v)
}

pub fn parse_print(out: &[u8]) -> Print {
    const FIRST: &[u8] = b"First usable sector is ";
    const LAST: &[u8] = b"last usable sector is ";
    let mut firsts = Vec::new();
    let mut lasts = Vec::new();
    let mut rows = Vec::new();
    for line in sh::lines(out) {
        if let Some(rest) = line.strip_prefix(FIRST) {
            firsts.push(leading_digits(rest));
        }
        if let Some(i) = sh::rfind(line, LAST) {
            lasts.push(leading_digits(line.get(i + LAST.len()..).unwrap_or(&[])));
        }
        if is_part_row(line) {
            let f = sh::awk_fields(line);
            let g = |i: usize| f.get(i).map(|x| x.to_vec()).unwrap_or_default();
            rows.push(Row { num: g(0), start: g(1), end: g(2) });
        }
    }
    Print { first_usable: join_subst(firsts), last_usable: join_subst(lasts), rows }
}

/// `sort -k2 -n` 之后的顺序：按第二个字段的数值，相等时按整行字节序（sort 的最后手段比较；C 区域）。
/// 第二个字段不是数 ⇒ 数值按 0（sort -n 的规则）
pub fn sorted_by_start(rows: &[Row]) -> Vec<Row> {
    fn numval(v: &[u8]) -> (bool, Vec<u8>) {
        // sort -n：可选负号 + 数字；用"去掉前导零的数字串"按长度再按字典序比，避免任何溢出
        let (neg, d) = match v.first() {
            Some(b'-') => (true, v.get(1..).unwrap_or(&[])),
            _ => (false, v),
        };
        let d = leading_digits(d);
        let z = d.iter().take_while(|&&c| c == b'0').count();
        let d = d.get(z..).unwrap_or(&[]).to_vec();
        (neg && !d.is_empty(), d)
    }
    fn cmp_num(a: &[u8], b: &[u8]) -> std::cmp::Ordering {
        let (an, ad) = numval(a);
        let (bn, bd) = numval(b);
        let mag = ad.len().cmp(&bd.len()).then_with(|| ad.cmp(&bd));
        match (an, bn) {
            (false, false) => mag,
            (true, true) => mag.reverse(),
            (true, false) => std::cmp::Ordering::Less,
            (false, true) => std::cmp::Ordering::Greater,
        }
    }
    let line = |r: &Row| {
        let mut v = r.num.clone();
        v.push(b' ');
        v.extend_from_slice(&r.start);
        v.push(b' ');
        v.extend_from_slice(&r.end);
        v
    };
    let mut v = rows.to_vec();
    v.sort_by(|a, b| cmp_num(&a.start, &b.start).then_with(|| line(a).cmp(&line(b))));
    v
}

/// `sgdisk -i <号> <盘>` 里我们用到的东西
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Info {
    /// `sed -n 's/^Partition GUID code: \([0-9A-Fa-f-]*\).*/\1/p'`
    pub type_guid: Vec<u8>,
    /// `grep "^Partition name:" | cut -d"'" -f2`
    pub name: Vec<u8>,
    /// `awk '/^First sector:/{print $3}'`
    pub first: Vec<u8>,
    /// `awk '/^Last sector:/{print $3}'`
    pub last: Vec<u8>,
}

pub fn parse_info(out: &[u8]) -> Info {
    const GUID: &[u8] = b"Partition GUID code: ";
    let mut guids = Vec::new();
    let mut names = Vec::new();
    let mut firsts = Vec::new();
    let mut lasts = Vec::new();
    for line in sh::lines(out) {
        if let Some(rest) = line.strip_prefix(GUID) {
            let n = rest.iter().take_while(|c| c.is_ascii_hexdigit() || **c == b'-').count();
            guids.push(rest.get(..n).unwrap_or(&[]));
        }
        if line.starts_with(b"Partition name:") {
            names.push(sh::cut_f2(line, b'\''));
        }
        if line.starts_with(b"First sector:") {
            firsts.push(sh::awk_fields(line).get(2).copied().unwrap_or(&[]));
        }
        if line.starts_with(b"Last sector:") {
            lasts.push(sh::awk_fields(line).get(2).copied().unwrap_or(&[]));
        }
    }
    Info { type_guid: join_subst(guids), name: join_subst(names), first: join_subst(firsts), last: join_subst(lasts) }
}

/// 分区表是什么、读不读得出来（installer-lib.sh `gk3__read_table`；设计稿 §3.2 的 S1 / S2，2026-10-06 修）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Gpt,
    /// 我们只写 GPT；sgdisk 不带 -g 拒绝写 MBR 盘（rc 3）⇒ 只有整盘清空能走
    Mbr,
    /// 读不出：不列分区与空闲区、不往上写
    Unreadable,
    /// 没有 sgdisk
    Unknown,
}

impl Kind {
    /// 协议里的写法（DISK 记录的 `table=`）
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Gpt => "gpt",
            Kind::Mbr => "mbr",
            Kind::Unreadable => "unreadable",
            Kind::Unknown => "unknown",
        }
    }
}

/// 读一次分区表的结果
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Table {
    pub kind: Kind,
    /// `sgdisk -p` 的 stdout（经 `$(…)`）
    pub print: Vec<u8>,
    /// [`Kind::Unreadable`] 的原因（给人看的，只进 `!!`）
    pub why: String,
}

/// sgdisk 在 stderr 上报读错误的两种说法（gdisk 1.0.10 实录）："Warning! Read error 5; strange behavior now likely!"
/// 与 "Warning! Error 5 reading partition table for CRC check!"。shell 版：`grep -Eqi 'read error|error [0-9]+ reading'`（逐行）
fn read_error_line(stderr: &[u8]) -> Option<&[u8]> {
    sh::lines(stderr).into_iter().find(|line| {
        let l = line.to_ascii_lowercase();
        if sh::find(&l, b"read error").is_some() {
            return true;
        }
        // error [0-9]+ reading：每一处 "error " 后面跟一串数字、再跟 " reading"
        let mut from = 0usize;
        while let Some(i) = l.get(from..).and_then(|rest| sh::find(rest, b"error ")) {
            let after = l.get(from + i + 6..).unwrap_or(&[]);
            let nd = after.iter().take_while(|c| c.is_ascii_digit()).count();
            if nd > 0 && after.get(nd..).is_some_and(|r| r.starts_with(b" reading")) {
                return true;
            }
            from += i + 1;
        }
        false
    })
}

/// `grep -Eq '^First usable sector is [0-9]+, last usable sector is [0-9]+'`
fn has_usable_range(print: &[u8]) -> bool {
    sh::lines(print).into_iter().any(|line| {
        let Some(rest) = line.strip_prefix(b"First usable sector is ".as_slice()) else { return false };
        let nd = rest.iter().take_while(|c| c.is_ascii_digit()).count();
        let Some(rest) = rest.get(nd..).and_then(|r| r.strip_prefix(b", last usable sector is ".as_slice())) else { return false };
        nd > 0 && rest.first().is_some_and(u8::is_ascii_digit)
    })
}

/// sgdisk 说它要把 MBR 在内存里转成 GPT 的那句（stdout 上、行首；shell 版对 stdout 与 stderr 一起 grep）
const MBR_BANNER: &[u8] = b"Found invalid GPT and valid MBR; converting MBR to GPT format";

/// 判据的纯函数部分（与 `gk3__read_table` 的 if / elif 同序）。`exit` = sgdisk 的退出码（起不来 / 超时 / 被杀 ⇒ None）；
/// `pttype` 是惰性的：前面几条已经定了就不去问 blkid（shell 版的 elif 也不会跑它）
pub fn classify(exit: Option<i32>, print: &[u8], stderr: &[u8], pttype: impl FnOnce() -> Vec<u8>) -> (Kind, String) {
    match exit {
        Some(0) => {}
        Some(c) => {
            let first = sh::lines(stderr).first().map(|l| String::from_utf8_lossy(l).into_owned()).unwrap_or_default();
            return (Kind::Unreadable, format!("sgdisk -p 退出码 {c}：{first}"));
        }
        None => return (Kind::Unreadable, "sgdisk -p 没有正常结束（起不来 / 超时 / 被信号杀）".into()),
    }
    if let Some(l) = read_error_line(stderr) {
        return (Kind::Unreadable, format!("读盘出错：{}", String::from_utf8_lossy(l)));
    }
    if !has_usable_range(print) {
        return (Kind::Unreadable, "sgdisk -p 的输出里没有可用扇区的范围".into());
    }
    let banner = sh::lines(print).into_iter().chain(sh::lines(stderr)).any(|l| l.starts_with(MBR_BANNER));
    if pttype() == b"dos" || banner {
        return (Kind::Mbr, String::new());
    }
    (Kind::Gpt, String::new())
}

/// installer-lib.sh `gk3__read_table`：跑一次 `sgdisk -p`，必要时问 `blkid -p -o value -s PTTYPE`。
/// ★ 这里的失败【不】进 Diag：读不出是结论本身（Kind::Unreadable），由调用方明确报出去（S1 之前是静默按空盘算）
pub fn read_table(host: &dyn Host, disk: &str) -> Table {
    if host.which("sgdisk").is_none() {
        return Table { kind: Kind::Unknown, print: Vec::new(), why: "缺 sgdisk".into() };
    }
    let (exit, print, stderr) = match host.run(&Cmd::new("sgdisk").arg("-p").arg(disk)) {
        Ok(o) => {
            let exit = match o.status {
                Status::Exited(c) if !o.truncated => Some(c),
                _ => None,
            };
            (exit, sh::subst(o.stdout), o.stderr)
        }
        Err(_) => (None, Vec::new(), Vec::new()),
    };
    let pttype = || match host.run(&Cmd::new("blkid").args(["-p", "-o", "value", "-s", "PTTYPE"]).arg(disk)) {
        // `$(blkid … 2>/dev/null)`：退出码不看（没有分区表时是 2），blkid 起不来 ⇒ 空串
        Ok(o) => sh::subst(o.stdout),
        Err(_) => Vec::new(),
    };
    let (kind, why) = classify(exit, &print, &stderr, pttype);
    Table { kind, print, why }
}

/// installer-lib.sh:249-255 `gk3_partpath`：盘名以数字结尾（nvme0n1、loop0）⇒ 加 p
pub fn partpath(disk: &str, num: &str) -> String {
    if disk.as_bytes().last().is_some_and(u8::is_ascii_digit) {
        format!("{disk}p{num}")
    } else {
        format!("{disk}{num}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // 2026-10-06 在 test-env 容器里实录（gdisk 1.0.10），见设计稿 §6.1
    const P_GPT: &str = "Disk /dev/loop0: 4194304 sectors, 2.0 GiB
Sector size (logical/physical): 512/512 bytes
Disk identifier (GUID): 8DBA3819-7BDC-4312-B13E-E728F523DD16
Partition table holds up to 128 entries
Main partition table begins at sector 2 and ends at sector 33
First usable sector is 34, last usable sector is 4194270
Partitions will be aligned on 2048-sector boundaries
Total free space is 3579837 sectors (1.7 GiB)

Number  Start (sector)    End (sector)  Size       Code  Name
   2          206848          616447   200.0 MiB   8300  it's x
   1            2048          206847   100.0 MiB   EF00  EFI system partition
";
    const I_ESP: &str = "Partition GUID code: C12A7328-F81F-11D2-BA4B-00A0C93EC93B (EFI system partition)
Partition unique GUID: B3632403-1A98-4F84-9522-CBFA804CF0B4
First sector: 2048 (at 1024.0 KiB)
Last sector: 206847 (at 101.0 MiB)
Partition size: 204800 sectors (100.0 MiB)
Attribute flags: 0000000000000000
Partition name: 'EFI system partition'
";

    #[test]
    fn print() {
        let p = parse_print(P_GPT.as_bytes());
        assert_eq!(p.first_usable, b"34");
        assert_eq!(p.last_usable, b"4194270");
        assert_eq!(p.rows.len(), 2);
        assert_eq!(p.rows[0].num, b"2");
        let s = sorted_by_start(&p.rows);
        assert_eq!(s[0].num, b"1");
        assert_eq!(s[0].start, b"2048");
        assert_eq!(s[1].end, b"616447");
    }

    #[test]
    fn print_blank_and_missing() {
        let p = parse_print(b"Creating new GPT entries in memory.\nFirst usable sector is 34, last usable sector is 4194270\n\nNumber  Start (sector)    End (sector)  Size       Code  Name\n");
        assert!(p.rows.is_empty());
        let p = parse_print(b"");
        assert_eq!(p, Print::default());
    }

    #[test]
    fn info() {
        let i = parse_info(I_ESP.as_bytes());
        assert_eq!(i.type_guid, b"C12A7328-F81F-11D2-BA4B-00A0C93EC93B");
        assert_eq!(i.name, b"EFI system partition");
        assert_eq!(i.first, b"2048");
        assert_eq!(i.last, b"206847");
        // 分区不存在：sgdisk 说一句话、退出码 0、什么字段都没有
        assert_eq!(parse_info(b"Partition #9 does not exist.\n"), Info::default());
    }

    #[test]
    fn sort_is_numeric_with_line_tiebreak() {
        let r = |n: &str, s: &str| Row { num: n.into(), start: s.into(), end: b"9".to_vec() };
        let s = sorted_by_start(&[r("3", "100000"), r("1", "34"), r("2", "2048"), r("4", "x")]);
        let nums: Vec<_> = s.iter().map(|r| String::from_utf8(r.num.clone()).unwrap()).collect();
        assert_eq!(nums, ["4", "1", "2", "3"]); // "x" 按 0
    }

    /// 2026-10-06 test-env 容器实录（gdisk 1.0.10、util-linux 2.41.5），每种盘：(退出码, stdout, stderr, blkid PTTYPE) → 结论
    #[test]
    fn classify_recorded_disks() {
        let usable = "First usable sector is 34, last usable sector is 6291422\n";
        let mbr_banner = "\n***\nFound invalid GPT and valid MBR; converting MBR to GPT format\nin memory. \n***\n\n";
        let c =
            |exit: Option<i32>, out: &str, err: &str, pt: &str| classify(exit, out.as_bytes(), err.as_bytes(), || pt.as_bytes().to_vec()).0;
        // sfdisk 建的 dos 盘（有分区 / 空表）：横幅在 stdout，blkid 说 dos
        assert_eq!(c(Some(0), &format!("{mbr_banner}{usable}"), "", "dos"), Kind::Mbr);
        // 两样里只有一样也算
        assert_eq!(c(Some(0), &format!("{mbr_banner}{usable}"), "", ""), Kind::Mbr);
        assert_eq!(c(Some(0), usable, "", "dos"), Kind::Mbr);
        // GPT、混合 MBR（sgdisk -h）、坏了主 GPT 头（stderr 一堆 Caution / Warning，但没有读错误）：gpt
        assert_eq!(c(Some(0), usable, "", "gpt"), Kind::Gpt);
        let bad_main = "Caution: invalid main GPT header, but valid backup; regenerating main header\nfrom backup!\n\nWarning: Invalid CRC on main header data; loaded backup partition table.\nWarning! One or more CRCs don't match. You should repair the disk!\n";
        assert_eq!(c(Some(0), usable, bad_main, "gpt"), Kind::Gpt);
        // 没有分区表 / 只剩保护性 MBR：sgdisk 在内存里建空表，blkid 退出码 2 / PMBR
        let blank = format!("Creating new GPT entries in memory.\n{usable}");
        assert_eq!(c(Some(0), &blank, "", ""), Kind::Gpt);
        assert_eq!(c(Some(0), &blank, "", "PMBR"), Kind::Gpt);
        // 读不出：打不开（rc 2）、整块 EIO（rc 0 + 空表 + stderr 读错误）、备份 GPT 读不到、起不来
        assert_eq!(c(Some(2), "", "Problem opening /dev/x for reading! Error is 2.\n", ""), Kind::Unreadable);
        assert_eq!(c(Some(0), &blank, "Warning! Read error 5; strange behavior now likely!\n", ""), Kind::Unreadable);
        assert_eq!(c(Some(0), usable, "Warning! Error 5 reading partition table for CRC check!\n", "gpt"), Kind::Unreadable);
        assert_eq!(c(None, "", "", "gpt"), Kind::Unreadable);
        assert_eq!(c(Some(0), "", "", "gpt"), Kind::Unreadable);
        // unreadable 优先于 mbr；"error 5x reading" / "error  reading" 不是读错误的说法
        assert_eq!(c(Some(0), mbr_banner, "", "dos"), Kind::Unreadable);
        assert_eq!(c(Some(0), usable, "error 5x reading\nerror  reading\n", "gpt"), Kind::Gpt);
        // 横幅要在行首（分区名里出现这句话不算）
        assert_eq!(
            c(
                Some(0),
                &format!("{usable}   1  2048  4095  1 MiB  8300  Found invalid GPT and valid MBR; converting MBR to GPT format\n"),
                "",
                "gpt"
            ),
            Kind::Gpt
        );
    }

    #[test]
    fn classify_does_not_ask_blkid_when_already_decided() {
        let asked = std::cell::Cell::new(false);
        let (k, _) = classify(Some(2), b"", b"", || {
            asked.set(true);
            Vec::new()
        });
        assert_eq!((k, asked.get()), (Kind::Unreadable, false));
    }

    #[test]
    fn partpath_rule() {
        assert_eq!(partpath("/dev/nvme0n1", "3"), "/dev/nvme0n1p3");
        assert_eq!(partpath("/dev/loop7", "1"), "/dev/loop7p1");
        assert_eq!(partpath("/dev/sda", "1"), "/dev/sda1");
    }
}
