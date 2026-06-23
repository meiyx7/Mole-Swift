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
use std::sync::OnceLock;

/// 默认附加到所有清理类命令的环境变量。
///
/// `MOLE_NON_INTERACTIVE=1` 让 `mo` 跳过所有交互式 prompt，直接执行或返回。
/// 这对 GUI 后台调用至关重要：Tauri 命令没有 TTY，任何 `read` 调用都会立即
/// 拿到 EOF，但 CLI 仍可能尝试 prompt，浪费一次循环甚至误判输入。
const NON_INTERACTIVE_ENV: (&str, &str) = ("MOLE_NON_INTERACTIVE", "1");

/// 缓存的完整 PATH（从 login shell 解析）。
///
/// macOS GUI 应用从 Finder/Dock 启动时只继承最小 PATH
/// (`/usr/bin:/bin:/usr/sbin:/sbin`)，不含 Homebrew (`/opt/homebrew/bin`)、
/// `~/.local/bin` 等。这里通过 login shell 解析用户真实 PATH 并缓存，
/// 让子进程能找到 `mo` 及其依赖。
static FULL_PATH: OnceLock<String> = OnceLock::new();

/// 缓存的 `mo` 二进制完整路径。
static MO_PATH: OnceLock<Option<String>> = OnceLock::new();

/// 获取用户完整 PATH（从 login shell 解析，缓存）。
fn full_path() -> &'static str {
    FULL_PATH.get_or_init(|| {
        // 依次尝试 zsh（macOS 默认）和 bash。
        for shell in ["/bin/zsh", "/bin/bash"] {
            if let Ok(output) = Command::new(shell)
                .args(["-l", "-c", "printf '%s' \"$PATH\""])
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .output()
            {
                if output.status.success() {
                    let p = String::from_utf8_lossy(&output.stdout).to_string();
                    if !p.is_empty() && p.contains('/') {
                        return p;
                    }
                }
            }
        }
        // 回退：常见 macOS 路径。
        let home = std::env::var("HOME").unwrap_or_default();
        format!(
            "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:{}/.local/bin",
            home
        )
    })
}

/// 解析 `mo` 二进制的完整路径（缓存）。
///
/// 依次在 login shell PATH 和常见安装路径中查找可执行文件。
fn resolve_mo() -> Option<&'static str> {
    MO_PATH.get_or_init(|| {
        let path = full_path();
        // 在 PATH 各目录中搜索 `mo`。
        for dir in path.split(':') {
            if dir.is_empty() {
                continue;
            }
            let candidate = format!("{}/mo", dir);
            if is_executable(&candidate) {
                return Some(candidate);
            }
        }
        // 常见安装路径回退。
        let home = std::env::var("HOME").unwrap_or_default();
        let fallbacks = [
            "/opt/homebrew/bin/mo".to_string(),
            "/usr/local/bin/mo".to_string(),
            format!("{}/.local/bin/mo", home),
        ];
        for f in &fallbacks {
            if is_executable(f) {
                return Some(f.clone());
            }
        }
        None
    })
    .as_deref()
}

/// 返回 `mo` 的完整路径，找不到时回退为 `"mo"`。
pub fn mo_bin() -> String {
    resolve_mo().map(|s| s.to_string()).unwrap_or_else(|| "mo".to_string())
}

#[cfg(unix)]
fn is_executable(path: &str) -> bool {
    use std::os::unix::fs::PermissionsExt;
    if let Ok(meta) = std::fs::metadata(path) {
        meta.is_file() && (meta.permissions().mode() & 0o111 != 0)
    } else {
        false
    }
}

#[cfg(not(unix))]
fn is_executable(path: &str) -> bool {
    Path::new(path).is_file()
}

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
    // 对 `mo` 命令，解析完整路径并设置 login shell PATH，确保 GUI 环境下也能找到。
    let resolved = if bin == "mo" { resolve_mo() } else { None };
    let actual_bin = resolved.unwrap_or(bin);

    // 记录命令调用日志
    let args_str = args.join(" ");
    crate::logger::log(
        crate::logger::LogLevel::Info,
        &format!("执行命令: {} {}", actual_bin, args_str),
    );

    let mut cmd = Command::new(actual_bin);
    cmd.args(args);
    cmd.env(NON_INTERACTIVE_ENV.0, NON_INTERACTIVE_ENV.1);
    // 为 `mo` 子进程设置完整 PATH，让 CLI 能找到 brew/python3 等依赖。
    if bin == "mo" {
        cmd.env("PATH", full_path());
    }
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
            let msg = format!("无法启动 {}: {}", bin, e);
            crate::logger::log(crate::logger::LogLevel::Error, &msg);
            return CommandOutput {
                success: false,
                stdout: String::new(),
                stderr: msg,
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
            let msg = format!("等待进程退出失败: {}", e);
            crate::logger::log(crate::logger::LogLevel::Error, &msg);
            return CommandOutput {
                success: false,
                stdout,
                stderr: msg,
                exit_code: -1,
            };
        }
    };

    let code = status.code().unwrap_or(-1);
    let success = status.success();

    // 记录命令结果日志（失败时记录 stderr）
    if !success {
        let stderr_preview = if stderr.len() > 500 {
            format!("{}...(截断)", &stderr[..500])
        } else {
            stderr.clone()
        };
        crate::logger::log(
            crate::logger::LogLevel::Warn,
            &format!("命令失败 (exit={}): {} {} | stderr: {}", code, bin, args_str, stderr_preview),
        );
    }

    CommandOutput {
        success,
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

/// 检查 `mo` 命令是否可用。
///
/// 通过 login shell PATH 和常见安装路径解析，避免 macOS GUI 应用
/// 因最小 PATH 而误判 CLI 不可用。
pub fn check_cli_available() -> bool {
    resolve_mo().is_some()
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
