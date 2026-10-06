//! `gk3-installer <函数> [参数…]` —— 与 `bash -c '. installer-lib.sh && "$@"' installer-lib.sh <函数> [参数…]` 同一个接口。
//!
//!   gk3-installer --version
//!   gk3-installer --list          # 已实现的入口，一行一个
//!   GK3_TRACE=<文件>              # 每次执行外部命令追加一行（命令行、结果、耗时）

use std::io::{self, Write};
use std::process::ExitCode;

use gk3_installer::host::{Diag, RealHost};
use gk3_installer::protocol::{current_touched, Failure, Out};
use gk3_installer::{dispatch, IMPLEMENTED};

fn main() -> ExitCode {
    // ★ 万一哪里 panic 了（lint 已经禁了 unwrap / expect / panic / 下标，剩下的是整数溢出这类）：
    //   先把一条 ERR 打到 stderr —— 前端靠它显示"出错了"，在写盘入口里还带着 touched（盘动过没有）。
    //   panic 不许变成一个只有 Rust 回溯、前端认不出的失败。
    std::panic::set_hook(Box::new(|info| {
        let msg = info.to_string();
        let f = Failure {
            code: "internal-panic".into(),
            fields: vec![],
            touched: current_touched(),
            human: format!("gk3-installer 内部错误：{msg}"),
        };
        let mut e = io::stderr().lock();
        let mut line = f.err_line();
        line.extend_from_slice(b"\n!! ");
        line.extend_from_slice(f.human.as_bytes());
        line.push(b'\n');
        gk3_installer_discard(e.write_all(&line));
    }));

    let args: Vec<String> = std::env::args().skip(1).collect();
    let (stdout, stderr) = (io::stdout(), io::stderr());
    let (mut so, mut se) = (stdout.lock(), stderr.lock());
    let Some((func, rest)) = args.split_first() else {
        gk3_installer_discard(writeln!(se, "!! 用法：gk3-installer <函数> [参数…]（--list 列出已实现的函数）"));
        return ExitCode::from(2);
    };
    match func.as_str() {
        "--version" => {
            return if writeln!(so, "gk3-installer {}", env!("CARGO_PKG_VERSION")).is_ok() { ExitCode::SUCCESS } else { ExitCode::FAILURE };
        }
        "--list" => {
            return if IMPLEMENTED.iter().try_for_each(|f| writeln!(so, "{f}")).is_ok() { ExitCode::SUCCESS } else { ExitCode::FAILURE };
        }
        _ => {}
    }

    let host = RealHost::new();
    let mut diag = Diag::default();
    let mut out = Out::new(&mut so, &mut se);
    let rc = dispatch(&host, func, rest, &mut out, &mut diag);
    // 被 shell 语义吞掉的失败：输出照旧，但在这里说出来（设计稿 §3.2）
    for n in diag.notes() {
        gk3_installer_discard(out.log(&format!("gk3-installer: 注意：{n}")));
    }
    match rc {
        Ok(Some(c)) => ExitCode::from(u8::try_from(c).unwrap_or(1)),
        Ok(None) => {
            // 与 bash 找不到命令时同一个退出码
            gk3_installer_discard(out.die(&format!("gk3-installer：不认识的函数 {func}（Rust 版还没实现它；--list 看已实现的）")));
            ExitCode::from(127)
        }
        Err(e) => {
            // 输出写不出去：stdout 多半已经断了，stderr 还能试一次
            gk3_installer_discard(out.die(&format!("gk3-installer：输出写不出去（{e}）")));
            ExitCode::from(1)
        }
    }
}

/// 写 stderr 失败时已经没有别的地方可以报了 —— 只有这几处允许忽略
fn gk3_installer_discard<T, E>(_: Result<T, E>) {}
