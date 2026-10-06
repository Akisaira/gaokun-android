//! shell 语义的小零件：Rust 版要与 installer-lib.sh 逐字节相同，就得把 `$(…)`、`cut`、`[ -gt ]`、`basename` 这些
//! 的边角行为照搬过来。每个函数注明它模仿的是哪一种 shell 行为；不照搬的地方（会让 shell 版挂死 / 算错的输入）
//! 返回 `None`，由调用方变成一个明确的错误（设计稿 §3.3 的偏差表）。

/// `$(…)` 的结果：去掉【全部】结尾换行；bash 还会丢掉 NUL 字节（并警告）
pub fn subst(mut v: Vec<u8>) -> Vec<u8> {
    v.retain(|&c| c != 0);
    while v.last() == Some(&b'\n') {
        v.pop();
    }
    v
}

/// 按 `\n` 切行（最后一个空行不算，与 `while read` / sed / awk 一致）
pub fn lines(v: &[u8]) -> Vec<&[u8]> {
    let mut out: Vec<&[u8]> = v.split(|&c| c == b'\n').collect();
    if out.last().is_some_and(|l| l.is_empty()) {
        out.pop();
    }
    out
}

/// awk 默认的字段切分（空格 / 制表符 / 换行，忽略开头的空白）
pub fn awk_fields(line: &[u8]) -> Vec<&[u8]> {
    line.split(|&c| c == b' ' || c == b'\t' || c == b'\n').filter(|f| !f.is_empty()).collect()
}

/// `cut -d"<d>" -f2`：行里没有分隔符 ⇒ 整行原样（cut 不带 -s 时的行为）；有 ⇒ 第一个与第二个分隔符之间
pub fn cut_f2(line: &[u8], d: u8) -> &[u8] {
    match line.iter().position(|&c| c == d) {
        None => line,
        Some(i) => {
            let rest = line.get(i + 1..).unwrap_or(&[]);
            match rest.iter().position(|&c| c == d) {
                None => rest,
                Some(j) => rest.get(..j).unwrap_or(&[]),
            }
        }
    }
}

/// `[ "$x" -gt … ]` 等整数测试对操作数的解析（bash 的 legal_number：可带首尾空白、可带正负号、十进制）。
/// 不是整数 ⇒ None（bash 打一行错误、测试返回 2，`&&` / `||` 按"假"走）
pub fn test_int(v: &[u8]) -> Option<i64> {
    let s = std::str::from_utf8(v).ok()?;
    let t = s.trim_matches(|c: char| c == ' ' || c == '\t' || c == '\n');
    if t.is_empty() {
        return None;
    }
    let (neg, digits) = match t.as_bytes().first() {
        Some(b'-') => (true, t.get(1..)?),
        Some(b'+') => (false, t.get(1..)?),
        _ => (false, t),
    };
    if digits.is_empty() || !digits.bytes().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let n: i64 = digits.parse().ok()?;
    Some(if neg { -n } else { n })
}

/// 前端传进来的数字参数（`--region-start 616448`）：只收规范的十进制（可带负号，不带前导零）。
/// ⚠️ 不照搬 bash 的算术求值：那里 `010` 是八进制、`1+1` 是表达式、`abc` 是一个值为 0 的变量 ——
///   这些输入在 shell 版里会算出错的分区边界（偏差 D2）。前端从来只传探测结果里的十进制。
pub fn canonical_int(v: &str) -> Option<i64> {
    let digits = v.strip_prefix('-').unwrap_or(v);
    if digits.is_empty() || !digits.bytes().all(|c| c.is_ascii_digit()) {
        return None;
    }
    if digits.len() > 1 && digits.starts_with('0') {
        return None;
    }
    v.parse().ok()
}

/// sysfs 里读出来、在 `$(( … ))` 里用的数（`sectors=$(cat …/size)`）：bash 算术里空串 = 0。
/// 其它非十进制写法 ⇒ None（偏差 D2：shell 版会按变量名 / 八进制解释）
pub fn arith_int(v: &[u8]) -> Option<i64> {
    let s = std::str::from_utf8(v).ok()?;
    let t = s.trim_matches(|c: char| c == ' ' || c == '\t' || c == '\n');
    if t.is_empty() {
        return Some(0);
    }
    canonical_int(t)
}

/// coreutils `basename`（只取最后一个路径分量，结尾的 / 不算）
pub fn basename(p: &str) -> &str {
    let t = p.trim_end_matches('/');
    if t.is_empty() {
        return if p.is_empty() { "" } else { "/" };
    }
    match t.rfind('/') {
        Some(i) => t.get(i + 1..).unwrap_or(t),
        None => t,
    }
}

/// `sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'`（POSIX 的 [[:space:]]：空格 \t \n \v \f \r）
pub fn trim_space(v: &[u8]) -> &[u8] {
    let sp = |c: &u8| matches!(c, b' ' | b'\t' | b'\n' | 0x0b | 0x0c | b'\r');
    let start = v.iter().position(|c| !sp(c)).unwrap_or(v.len());
    let end = v.iter().rposition(|c| !sp(c)).map_or(start, |i| i + 1);
    v.get(start..end).unwrap_or(&[])
}

/// 在 `hay` 里找 `needle` 最后一次出现的位置（模仿 sed 里贪婪的 `.*needle`）
pub fn rfind(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.len() > hay.len() {
        return None;
    }
    (0..=hay.len() - needle.len()).rev().find(|&i| hay.get(i..i + needle.len()) == Some(needle))
}

/// 在 `hay` 里找 `needle` 第一次出现的位置
pub fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.len() > hay.len() {
        return None;
    }
    (0..=hay.len() - needle.len()).find(|&i| hay.get(i..i + needle.len()) == Some(needle))
}

/// `echo $words | tr ' ' ','`：按 IFS（空格 / 制表符 / 换行）切词、逗号连接
pub fn join_words_comma(words: &str) -> String {
    words.split([' ', '\t', '\n']).filter(|w| !w.is_empty()).collect::<Vec<_>>().join(",")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn subst_strips_all_trailing_newlines_and_nul() {
        assert_eq!(subst(b"abc\n\n\n".to_vec()), b"abc");
        assert_eq!(subst(b"a\nb\n".to_vec()), b"a\nb");
        assert_eq!(subst(b"a\0b\n".to_vec()), b"ab");
        assert_eq!(subst(b"\n".to_vec()), b"");
    }

    #[test]
    fn cut_semantics() {
        assert_eq!(cut_f2(b"Partition name: 'EFI system partition'", b'\''), b"EFI system partition");
        assert_eq!(cut_f2(b"Partition name: 'it's x'", b'\''), b"it");
        assert_eq!(cut_f2(b"no delimiter here", b'\''), b"no delimiter here");
        assert_eq!(cut_f2(b"one 'quote", b'\''), b"quote");
        assert_eq!(cut_f2(b"Partition name: ''", b'\''), b"");
    }

    #[test]
    fn ints() {
        assert_eq!(test_int(b"83886080"), Some(83886080));
        assert_eq!(test_int(b" 5 "), Some(5));
        assert_eq!(test_int(b"-3"), Some(-3));
        assert_eq!(test_int(b"010"), Some(10)); // [ ] 是十进制
        assert_eq!(test_int(b""), None);
        assert_eq!(test_int(b"0x10"), None);
        assert_eq!(test_int(b"12abc"), None);
        assert_eq!(canonical_int("616448"), Some(616448));
        assert_eq!(canonical_int("0"), Some(0));
        assert_eq!(canonical_int("-5"), Some(-5));
        assert_eq!(canonical_int("010"), None);
        assert_eq!(canonical_int("1+1"), None);
        assert_eq!(canonical_int(""), None);
        assert_eq!(arith_int(b""), Some(0));
        assert_eq!(arith_int(b"4194304"), Some(4194304));
    }

    #[test]
    fn basename_like_coreutils() {
        assert_eq!(basename("/dev/nvme0n1"), "nvme0n1");
        assert_eq!(basename("/dev/loop0/"), "loop0");
        assert_eq!(basename("sda"), "sda");
        assert_eq!(basename("/"), "/");
    }

    #[test]
    fn trim_and_words() {
        assert_eq!(trim_space(b"  SAMSUNG MZ9L4512HBLU-00B07              "), b"SAMSUNG MZ9L4512HBLU-00B07");
        assert_eq!(trim_space(b"   "), b"");
        assert_eq!(join_words_comma(" super  userdata\tmisc "), "super,userdata,misc");
        assert_eq!(awk_fields(b"   1            2048          206847   100.0 MiB"), vec![&b"1"[..], b"2048", b"206847", b"100.0", b"MiB"]);
        assert_eq!(rfind(b"a, BIOS 1, BIOS 2", b", BIOS "), Some(9));
        assert_eq!(find(b"abcabc", b"bc"), Some(1));
        assert_eq!(lines(b"a\nb\n"), vec![&b"a"[..], b"b"]);
    }
}
