//! 宿主：这台机器上的文件、环境变量、外部命令。入口函数只经这个 trait 看世界 ——
//! 单元测试换成 [`fake::FakeHost`]（一张"路径 → 内容""命令行 → 输出"的表），不用 root、不用 loop 设备。
//!
//! 另有 [`Diag`]：shell 版里被 `2>/dev/null` / `|| echo 0` 吞掉的失败，在兼容阶段（设计稿 §5 阶段 1）
//! 输出仍按 shell 版的语义走（对拍要逐字节相同），但每一处都记一笔，最后作为人看的日志打到 stderr ——
//! "照旧处理"可以，"没人知道"不行。

use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Instant;

use crate::exec::{Cmd, ExecError, Output, Status};
use crate::sh;

pub trait Host {
    fn env(&self, k: &str) -> Option<String>;
    /// `cat <path>`
    fn read(&self, p: &str) -> io::Result<Vec<u8>>;
    /// `[ -e ]`（跟随符号链接）
    fn exists(&self, p: &str) -> bool;
    /// `[ -d ]`
    fn is_dir(&self, p: &str) -> bool;
    /// `[ -b ]`
    fn is_block(&self, p: &str) -> bool;
    /// `[ -r ]`（近似：能 open 就算可读 —— sysfs 的属性常常 open 得开、read 才报错，那正是 -r 与 cat 不一致的情形）
    fn readable(&self, p: &str) -> bool;
    /// `"$dir"/*`：完整路径、按字节序、不含点开头的名字；目录不存在 / 空 ⇒ 空表
    /// （bash 此时给的是字面量 `dir/*`，后面对它的 cat 全失败 —— 效果同空表）
    fn glob(&self, dir: &str) -> Vec<String>;
    /// `readlink -f`：除最后一个分量外都要存在；解析不了 ⇒ None（readlink 失败、什么都不打印）
    fn readlink_f(&self, p: &str) -> Option<String>;
    /// `command -v <prog>`
    fn which(&self, prog: &str) -> Option<String>;
    /// 执行外部命令（exec.rs），并留下追踪记录
    fn run(&self, cmd: &Cmd) -> Result<Output, ExecError>;
}

/// 被 shell 语义吞掉、但这里不许吞的失败（兼容阶段打到 stderr，见模块注释）
#[derive(Debug, Default)]
pub struct Diag {
    notes: Vec<String>,
}

impl Diag {
    pub fn note(&mut self, s: impl Into<String>) {
        self.notes.push(s.into());
    }
    pub fn notes(&self) -> &[String] {
        &self.notes
    }
    pub fn is_empty(&self) -> bool {
        self.notes.is_empty()
    }
}

/// shell 版 `$(cmd 2>/dev/null)` 的等价物：返回 stdout（经 `$(…)` 的处理），不管退出码 ——
/// 但退出码不在 `accept` 里、超时、被信号杀、起不来，都记进 `diag`。
pub fn capture(host: &dyn Host, cmd: &Cmd, accept: &[i32], diag: &mut Diag) -> Vec<u8> {
    match host.run(cmd) {
        Ok(o) => {
            let ok = matches!(o.status, Status::Exited(c) if accept.contains(&c)) && !o.truncated;
            if !ok {
                diag.note(ExecError::Status(Box::new(o.clone())).to_string());
            }
            sh::subst(o.stdout)
        }
        Err(e) => {
            diag.note(e.to_string());
            Vec::new()
        }
    }
}

/// 同上，但 stdout 与 stderr 合在一起（shell 版的 `2>&1`）。⚠️ 两条流的交错顺序丢了 —— 只给"有没有某个子串"用
pub fn capture_both(host: &dyn Host, cmd: &Cmd, accept: &[i32], diag: &mut Diag) -> Vec<u8> {
    match host.run(cmd) {
        Ok(o) => {
            let ok = matches!(o.status, Status::Exited(c) if accept.contains(&c)) && !o.truncated;
            if !ok {
                diag.note(ExecError::Status(Box::new(o.clone())).to_string());
            }
            let mut v = o.stdout;
            v.extend_from_slice(&o.stderr);
            v
        }
        Err(e) => {
            diag.note(e.to_string());
            Vec::new()
        }
    }
}

/// `$(cat <path> 2>/dev/null)`：读不到 ⇒ None（调用方决定 `|| echo 0` 之类的默认值）
pub fn cat(host: &dyn Host, p: &str) -> Option<Vec<u8>> {
    host.read(p).ok().map(sh::subst)
}

/// 真的宿主
#[derive(Debug)]
pub struct RealHost {
    trace: Option<Mutex<File>>,
    t0: Instant,
}

impl RealHost {
    /// `GK3_TRACE=<文件>`：每次执行外部命令追加一行（命令行、结果、耗时、输出长度）
    pub fn new() -> Self {
        let trace = std::env::var_os("GK3_TRACE")
            .filter(|p| !p.is_empty())
            .and_then(|p| OpenOptions::new().create(true).append(true).open(p).ok())
            .map(Mutex::new);
        RealHost { trace, t0: Instant::now() }
    }

    fn trace_line(&self, line: &str) {
        if let Some(m) = &self.trace {
            if let Ok(mut f) = m.lock() {
                // 追踪日志写不进去不影响安装本身：它是旁路的诊断，失败不升级成错误
                crate::discard(writeln!(f, "[+{} ms] {line}", self.t0.elapsed().as_millis()));
            }
        }
    }
}

impl Default for RealHost {
    fn default() -> Self {
        Self::new()
    }
}

/// bash 在 PATH 没设时用的默认值（config-top.h 的 DEFAULT_PATH_VALUE）
const DEFAULT_PATH: &str = "/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:.";

impl Host for RealHost {
    fn env(&self, k: &str) -> Option<String> {
        std::env::var(k).ok()
    }
    fn read(&self, p: &str) -> io::Result<Vec<u8>> {
        fs::read(p)
    }
    fn exists(&self, p: &str) -> bool {
        Path::new(p).exists()
    }
    fn is_dir(&self, p: &str) -> bool {
        Path::new(p).is_dir()
    }
    fn readable(&self, p: &str) -> bool {
        File::open(p).is_ok()
    }
    fn is_block(&self, p: &str) -> bool {
        use std::os::unix::fs::FileTypeExt;
        fs::metadata(p).map(|m| m.file_type().is_block_device()).unwrap_or(false)
    }
    fn glob(&self, dir: &str) -> Vec<String> {
        let mut names: Vec<Vec<u8>> = match fs::read_dir(dir) {
            Ok(rd) => rd
                .filter_map(Result::ok)
                .map(|e| {
                    use std::os::unix::ffi::OsStrExt;
                    e.file_name().as_bytes().to_vec()
                })
                .filter(|n| n.first() != Some(&b'.'))
                .collect(),
            Err(_) => return Vec::new(),
        };
        names.sort();
        let base = if dir.ends_with('/') { dir.to_string() } else { format!("{dir}/") };
        names.into_iter().map(|n| format!("{base}{}", String::from_utf8_lossy(&n))).collect()
    }
    fn readlink_f(&self, p: &str) -> Option<String> {
        if p.is_empty() {
            return None;
        }
        let path = Path::new(p);
        if let Ok(c) = fs::canonicalize(path) {
            return Some(c.to_string_lossy().into_owned());
        }
        // 最后一个分量可以不存在（readlink -f 的规则）
        let parent = match path.parent() {
            Some(pp) if !pp.as_os_str().is_empty() => pp.to_path_buf(),
            _ => PathBuf::from("."),
        };
        let name = path.file_name()?;
        let cp = fs::canonicalize(parent).ok()?;
        Some(cp.join(name).to_string_lossy().into_owned())
    }
    fn which(&self, prog: &str) -> Option<String> {
        if prog.contains('/') {
            return is_exec(Path::new(prog)).then(|| prog.to_string());
        }
        let path = std::env::var("PATH").unwrap_or_else(|_| DEFAULT_PATH.to_string());
        path.split(':')
            .map(|d| if d.is_empty() { "." } else { d })
            .map(|d| Path::new(d).join(prog))
            .find(|c| is_exec(c))
            .map(|c| c.to_string_lossy().into_owned())
    }
    fn run(&self, cmd: &Cmd) -> Result<Output, ExecError> {
        let r = cmd.run();
        match &r {
            Ok(o) => self.trace_line(&format!(
                "{} → {}（{} ms，stdout {} B，stderr {} B{}）",
                o.argv,
                o.status,
                o.elapsed.as_millis(),
                o.stdout.len(),
                o.stderr.len(),
                if o.truncated { "，没收全" } else { "" }
            )),
            Err(e) => self.trace_line(&e.to_string()),
        }
        r
    }
}

fn is_exec(p: &Path) -> bool {
    fs::metadata(p).map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0).unwrap_or(false)
}

#[cfg(test)]
pub mod fake {
    //! 测试用的宿主：文件表 + 命令表。没登记的命令 ⇒ 起不来（NotFound），与"没装这个工具"相同。
    use super::*;
    use std::cell::RefCell;
    use std::collections::BTreeMap;
    use std::time::Duration;

    #[derive(Debug, Default)]
    pub struct FakeHost {
        pub env: BTreeMap<String, String>,
        pub files: BTreeMap<String, Vec<u8>>,
        pub dirs: Vec<String>,
        pub blocks: Vec<String>,
        pub links: BTreeMap<String, String>,
        pub tools: Vec<String>,
        /// 命令行（Cmd::display）→（退出码，stdout，stderr）
        pub cmds: BTreeMap<String, (i32, Vec<u8>, Vec<u8>)>,
        pub ran: RefCell<Vec<String>>,
    }

    impl FakeHost {
        pub fn file(mut self, p: &str, v: &str) -> Self {
            self.files.insert(p.to_string(), v.as_bytes().to_vec());
            self
        }
        pub fn tool(mut self, t: &str) -> Self {
            self.tools.push(t.to_string());
            self
        }
        pub fn cmd(mut self, argv: &str, code: i32, out: &str) -> Self {
            self.cmds.insert(argv.to_string(), (code, out.as_bytes().to_vec(), Vec::new()));
            self
        }
        pub fn block(mut self, p: &str) -> Self {
            self.blocks.push(p.to_string());
            self
        }
    }

    impl Host for FakeHost {
        fn env(&self, k: &str) -> Option<String> {
            self.env.get(k).cloned()
        }
        fn read(&self, p: &str) -> io::Result<Vec<u8>> {
            self.files.get(p).cloned().ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))
        }
        fn exists(&self, p: &str) -> bool {
            self.files.contains_key(p) || self.dirs.iter().any(|d| d == p) || self.blocks.iter().any(|b| b == p)
        }
        fn is_dir(&self, p: &str) -> bool {
            self.dirs.iter().any(|d| d == p)
        }
        fn is_block(&self, p: &str) -> bool {
            self.blocks.iter().any(|b| b == p)
        }
        fn readable(&self, p: &str) -> bool {
            self.exists(p)
        }
        fn glob(&self, dir: &str) -> Vec<String> {
            let pre = format!("{}/", dir.trim_end_matches('/'));
            let mut out: Vec<String> = self
                .files
                .keys()
                .chain(self.dirs.iter())
                .filter_map(|k| k.strip_prefix(&pre).map(|rest| rest.split('/').next().unwrap_or("").to_string()))
                .filter(|n| !n.is_empty() && !n.starts_with('.'))
                .map(|n| format!("{pre}{n}"))
                .collect();
            out.sort();
            out.dedup();
            out
        }
        fn readlink_f(&self, p: &str) -> Option<String> {
            if p.is_empty() {
                return None;
            }
            Some(self.links.get(p).cloned().unwrap_or_else(|| p.to_string()))
        }
        fn which(&self, prog: &str) -> Option<String> {
            self.tools.iter().any(|t| t == prog).then(|| format!("/usr/bin/{prog}"))
        }
        fn run(&self, cmd: &Cmd) -> Result<Output, ExecError> {
            let argv = cmd.display();
            self.ran.borrow_mut().push(argv.clone());
            match self.cmds.get(&argv) {
                Some((c, o, e)) => Ok(Output {
                    argv,
                    status: Status::Exited(*c),
                    stdout: o.clone(),
                    stderr: e.clone(),
                    truncated: false,
                    elapsed: Duration::ZERO,
                }),
                None => Err(ExecError::Spawn { argv, kind: io::ErrorKind::NotFound, msg: "fake: 没登记".into() }),
            }
        }
    }
}
