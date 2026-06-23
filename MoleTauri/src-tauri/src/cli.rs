//! `mo` CLI 命令运行器。
//!
//! 所有 Tauri 命令都通过这里调用 `mo`，统一处理：
//! - `MOLE_NON_INTERACTIVE=1` 防止 CLI 进入 TTY 交互模式（在 GUI 后台会卡死）。
//! - stdin 重定向到 `/dev/null`，防止 CLI 把字节当成用户输入（参考 AGENTS.md
//!   中 `bats heredoc steals bytes from read -n1` 的同类问题）。
//! - 路径校验：`validate_path` 拒绝相对路径、含 `..` 的路径、含 null 字节的路径。
//! - 流式输出：通过 `tauri::ipc::Channel` 逐行推送，前端可实时显示进度。

use crate::models::CommandOutput;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// 默认附加到所有清理类命令的环境变量。
///
/// `MOLE_NON_INTERACTIVE=1` 让 `mo` 跳过所有交互式 prompt，直接执行或返回。
/// 这对 GUI 后台调用至关重要：Tauri 命令没有 TTY，任何 `read` 调用都会立即
/// 拿到 EOF，但 CLI 仍可能尝试 prompt，浪费一次循环甚至误判输入。
const NON_INTERACTIVE_ENV: (&str, &str) = ("MOLE_NON_INTERACTIVE", "1");

/// 运行 `mo` 并捕获全部输出后返回。
///
/// 自动附加 `MOLE_NON_INTERACTIVE=1` 并把 stdin 重定向到 `/dev/null`。
pub fn run_mo(args: &[&str]) -> CommandOutput {
    run_mo_with_env(args, &[])
}

/// 带额外环境变量运行 `mo`。
///
/// `env` 中的变量会附加到默认的 `MOLE_NON_INTERACTIVE=1` 之上；同名键以
/// 调用者传入的值为准。
pub fn run_mo_with_env(args: &[&str], env: &[(&str, &str)]) -> CommandOutput {
    run_binary("mo", args, env, false, |_| {})
}

/// 流式运行 `mo`：每读到一个完整行就调用 `on_line`。
///
/// 仍然返回最终的 `CommandOutput`，方便调用者拿到退出码和完整 stderr。
/// stdout 在流式过程中通过回调推送，最终 `CommandOutput.stdout` 也会包含
/// 完整内容（按行拼接），便于前端在流式不可用时降级。
pub fn run_mo_streaming<F>(args: &[&str], env: &[(&str, &str)], on_line: F) -> CommandOutput
where
    F: Fn(String),
{
    run_binary("mo", args, env, true, on_line)
}

/// 通用命令运行器。`streaming=true` 时逐行回调，否则一次性捕获。
fn run_binary<F>(bin: &str, args: &[&str], env: &[(&str, &str)], streaming: bool, on_line: F) -> CommandOutput
where
    F: Fn(String),
{
    let mut cmd = match Command::new(bin) {
        c => c,
    };
    cmd.args(args);
    cmd.env(NON_INTERACTIVE_ENV.0, NON_INTERACTIVE_ENV.1);
    for (k, v) in env {
        cmd.env(k, v);
    }
    // stdin 必须重定向到 /dev/null，防止 CLI 把后续字节当成用户输入。
    cmd.stdin(Stdio::null());
    cmd.stdout(Stdio::piped());
    cmd.stderr(Stdio::piped());

    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            return CommandOutput {
                success: false,
                stdout: String::new(),
                stderr: format!("无法启动 {}: {}", bin, e),
                exit_code: -1,
            };
        }
    };

    let stdout_handle = child.stdout.take();
    let stderr_handle = child.stderr.take();

    // stderr 始终一次性读完；流式只针对 stdout。
    let stderr = match stderr_handle {
        Some(s) => String::from_utf8_lossy(&read_all_to_end(s)).to_string(),
        None => String::new(),
    };

    let stdout = if streaming {
        let mut buf = String::new();
        if let Some(out) = stdout_handle {
            let reader = BufReader::new(out);
            for line in reader.lines() {
                match line {
                    Ok(l) => {
                        on_line(l.clone());
                        buf.push_str(&l);
                        buf.push('\n');
                    }
                    Err(_) => break,
                }
            }
        }
        buf
    } else {
        match stdout_handle {
            Some(s) => String::from_utf8_lossy(&read_all_to_end(s)).to_string(),
            None => String::new(),
        }
    };

    let status = match child.wait() {
        Ok(s) => s,
        Err(e) => {
            return CommandOutput {
                success: false,
                stdout,
                stderr: format!("等待进程退出失败: {}", e),
                exit_code: -1,
            };
        }
    };

    let code = status.code().unwrap_or(-1);
    CommandOutput {
        success: status.success(),
        stdout,
        stderr,
        exit_code: code,
    }
}

fn read_all_to_end<R: std::io::Read>(mut r: R) -> Vec<u8> {
    let mut v = Vec::new();
    let _ = r.read_to_end(&mut v);
    v
}

/// 校验用户提供的路径，返回规范化的绝对路径。
///
/// 拒绝：
/// - 含 null 字节的路径（防止命令注入截断）。
/// - 相对路径（必须以 `/` 开头，或 `~/` 开头会被展开）。
/// - 含 `..` 段的路径（防止目录穿越）。
///
/// `~` 开头的路径会展开为 `$HOME/...`，便于前端传 `~/Downloads` 这种形式。
pub fn validate_path(path: &str) -> Result<String, String> {
    if path.contains('\0') {
        return Err("路径包含 null 字节".to_string());
    }
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return Err("路径为空".to_string());
    }

    // 展开 `~` 前缀。
    let expanded = expand_tilde(trimmed)?;

    if !expanded.starts_with('/') {
        return Err(format!("路径必须是绝对路径: {}", path));
    }

    // 拒绝任何 `..` 段。这里逐段检查而不是用 Path::components，因为
    // 我们要拒绝 *任何* `..` 出现，包括 `foo/../bar` 这种合法但可疑的。
    for comp in Path::new(&expanded).components() {
        if let std::path::Component::ParentDir = comp {
            return Err(format!("路径不能包含 .. 段: {}", path));
        }
    }

    // 规范化多余的分隔符和 `.` 段（不解析符号链接，保持与 CLI 一致）。
    let normalized = normalize_path(&expanded);
    Ok(normalized)
}

/// 把 `~` 或 `~/...` 展开为绝对路径。其它路径原样返回。
fn expand_tilde(path: &str) -> Result<String, String> {
    if path == "~" {
        return home_dir();
    }
    if let Some(rest) = path.strip_prefix("~/") {
        let home = home_dir()?;
        // 注意：`rest` 可能本身含 `~`，但那种情况极少见且会被后续 `..` 检查兜住。
        return Ok(format!("{}/{}", home.trim_end_matches('/'), rest));
    }
    Ok(path.to_string())
}

fn home_dir() -> Result<String, String> {
    std::env::var("HOME").map_err(|_| "无法解析 $HOME".to_string())
}

/// 规范化路径：合并连续 `/`、移除 `.` 段。不解析符号链接。
fn normalize_path(path: &str) -> String {
    let mut parts: Vec<String> = Vec::new();
    for comp in Path::new(path).components() {
        match comp {
            std::path::Component::RootDir => {}
            std::path::Component::Normal(s) => {
                parts.push(s.to_string_lossy().to_string());
            }
            std::path::Component::CurDir => {} // 跳过 `.`
            // ParentDir 已在 validate_path 中拒绝，这里不处理。
            _ => {}
        }
    }
    let mut out = String::from("/");
    out.push_str(&parts.join("/"));
    out
}

/// 检查 `mo` 命令是否在 `$PATH` 中可用。
///
/// 用 `which mo` 实现，避免实际执行 `mo`（启动开销更小，也不会触发 CLI
/// 的初始化逻辑）。
pub fn check_cli_available() -> bool {
    Command::new("which")
        .arg("mo")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// 把一个字符串写入子进程的 stdin（用于 `pbcopy` 等）。
///
/// 调用方负责确保 `bin` 存在；失败时静默返回，因为这些都是非关键 UX 功能。
pub fn pipe_to_stdin(bin: &str, arg: Option<&str>, data: &[u8]) {
    let mut cmd = Command::new(bin);
    if let Some(a) = arg {
        cmd.arg(a);
    }
    cmd.stdin(Stdio::piped());
    cmd.stdout(Stdio::null());
    cmd.stderr(Stdio::null());
    if let Ok(mut child) = cmd.spawn() {
        if let Some(stdin) = child.stdin.as_mut() {
            let _ = stdin.write_all(data);
        }
        let _ = child.wait();
    }
}

/// 解析 `$HOME`，失败时返回 `.`（避免 panic）。
pub fn home_path() -> PathBuf {
    PathBuf::from(home_dir().unwrap_or_else(|_| ".".to_string()))
}
