//! 所有 `#[tauri::command]` 函数。
//!
//! 命令签名与前端 `invoke` 调用保持兼容。新增的流式命令使用
//! `tauri::ipc::Channel` 逐行推送输出，前端可通过 `Channel` API 实时接收。
//!
//! 所有 I/O 密集型命令（子进程调用、文件系统扫描、网络请求）均为
//! `async fn`，通过 `tauri::async_runtime::spawn_blocking` 在后台线程
//! 执行，避免阻塞 Tauri 主线程导致 UI 卡死。
//!
//! 安全约束：
//! - 所有清理类命令自动附加 `MOLE_NON_INTERACTIVE=1`（在 `cli.rs` 中实现）。
//! - stdin 重定向到 `/dev/null`（在 `cli.rs` 中实现）。
//! - 涉及路径的命令先通过 `validate_path` 校验。
//! - 删除走 Trash 路由（`trash.rs`），不直接 `rm -rf`。

use crate::cli;
use crate::installer;
use crate::logger;
use crate::models::{
    AppListEntry, CommandOutput, InstallerScanResult, PurgeScanResult, UpdateInfo,
};
use crate::purge;
use crate::trash;
use crate::update;
use std::process::{Command, Stdio};
use tauri::ipc::Channel;

/// `spawn_blocking` 失败时的回退 `CommandOutput`。
fn blocking_error() -> CommandOutput {
    CommandOutput {
        success: false,
        stdout: String::new(),
        stderr: "后台任务执行失败".to_string(),
        exit_code: -1,
    }
}

// ---------------------------------------------------------------------------
// Mole 操作日志（oplog）写入
// 与 lib/core/log.sh 的 log_operation 格式保持一致，使 mo history 能解析。
// 日志路径：~/Library/Logs/mole/operations.log
// ---------------------------------------------------------------------------

fn oplog_file_path() -> std::path::PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    std::path::PathBuf::from(home)
        .join("Library/Logs/mole/operations.log")
}

fn oplog_timestamp() -> String {
    // 与 lib/core/log.sh 的 get_timestamp 一致：YYYY-MM-DD HH:MM:SS
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    let secs = now.as_secs();
    // 简单的 epoch → 本地时间转换（使用 libc localtime）
    unsafe {
        let mut tm: libc_tm = std::mem::zeroed();
        let tt = secs as i64;
        localtime_r(&tt, &mut tm);
        format!(
            "{:04}-{:02}-{:02} {:02}:{:02}:{:02}",
            tm.tm_year + 1900,
            tm.tm_mon + 1,
            tm.tm_mday,
            tm.tm_hour,
            tm.tm_min,
            tm.tm_sec
        )
    }
}

/// libc tm 结构体（用于 localtime_r）
#[repr(C)]
struct libc_tm {
    tm_sec: i32,
    tm_min: i32,
    tm_hour: i32,
    tm_mday: i32,
    tm_mon: i32,
    tm_year: i32,
    tm_wday: i32,
    tm_yday: i32,
    tm_isdst: i32,
    tm_gmtoff: i64,
    tm_zone: *const i8,
}

extern "C" {
    fn localtime_r(timep: *const i64, result: *mut libc_tm) -> *mut libc_tm;
}

fn oplog_append(line: &str) {
    let path = oplog_file_path();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        let _ = writeln!(f, "{}", line);
    }
}

/// 写入 session 开始标记
fn oplog_session_start(command: &str) {
    let ts = oplog_timestamp();
    oplog_append(&format!(
        "# ========== {} session started at {} ==========",
        command, ts
    ));
}

/// 写入单条操作记录
/// action: TRASHED / REMOVED / SKIPPED / FAILED / REBUILT
fn oplog_operation(command: &str, action: &str, path: &str) {
    let ts = oplog_timestamp();
    oplog_append(&format!("[{}] [{}] {} {}", ts, command, action, path));
}

/// 写入 session 结束标记
fn oplog_session_end(command: &str, items: usize, _size_bytes: usize) {
    let ts = oplog_timestamp();
    oplog_append(&format!(
        "# ========== {} session ended at {}, {} items, 0B ==========",
        command, ts, items
    ));
}

// ---------------------------------------------------------------------------
// 清理类命令
// ---------------------------------------------------------------------------

/// `mo clean`：深度清理系统缓存、浏览器缓存、开发工具缓存等。
#[tauri::command]
pub async fn run_clean(dry_run: bool, verbose: bool) -> CommandOutput {
    tauri::async_runtime::spawn_blocking(move || {
        let mut args = vec!["clean"];
        if dry_run {
            args.push("--dry-run");
        }
        if verbose {
            args.push("--verbose");
        }
        cli::run_mo(&args)
    })
    .await
    .unwrap_or_else(|_| blocking_error())
}

/// `mo clean` 的流式版本：每读出一行 stdout 就通过 `on_line` 推送给前端。
#[tauri::command]
pub async fn run_clean_streaming(
    dry_run: bool,
    verbose: bool,
    on_line: Channel<String>,
) -> CommandOutput {
    tauri::async_runtime::spawn_blocking(move || {
        let mut args = vec!["clean"];
        if dry_run {
            args.push("--dry-run");
        }
        if verbose {
            args.push("--verbose");
        }
        cli::run_mo_streaming(&args, &[], |line| {
            let _ = on_line.send(line);
        })
    })
    .await
    .unwrap_or_else(|_| blocking_error())
}

/// `mo analyze --json`：磁盘分析，返回 JSON 字符串。
#[tauri::command]
pub async fn run_analyze(path: Option<String>) -> CommandOutput {
    tauri::async_runtime::spawn_blocking(move || {
        let mut args = vec!["analyze", "--json"];
        let path_str = path.unwrap_or_default();
        if !path_str.is_empty() {
            args.push(&path_str);
        }
        cli::run_mo(&args)
    })
    .await
    .unwrap_or_else(|_| blocking_error())
}

/// `mo status`：健康仪表盘。`json=true` 时返回 JSON 输出供前端解析。
#[tauri::command]
pub async fn run_status(json: bool) -> CommandOutput {
    tauri::async_runtime::spawn_blocking(move || {
        let mut args = vec!["status"];
        if json {
            args.push("--json");
        }
        cli::run_mo(&args)
    })
    .await
    .unwrap_or_else(|_| blocking_error())
}

/// `mo optimize`：维护任务。
#[tauri::command]
pub async fn run_optimize(dry_run: bool) -> CommandOutput {
    tauri::async_runtime::spawn_blocking(move || {
        let mut args = vec!["optimize"];
        if dry_run {
            args.push("--dry-run");
        }
        cli::run_mo(&args)
    })
    .await
    .unwrap_or_else(|_| blocking_error())
}

/// `mo optimize` 的流式版本。
#[tauri::command]
pub async fn run_optimize_streaming(dry_run: bool, on_line: Channel<String>) -> CommandOutput {
    tauri::async_runtime::spawn_blocking(move || {
        let mut args = vec!["optimize"];
        if dry_run {
            args.push("--dry-run");
        }
        cli::run_mo_streaming(&args, &[], |line| {
            let _ = on_line.send(line);
        })
    })
    .await
    .unwrap_or_else(|_| blocking_error())
}

/// `mo uninstall`：安全卸载应用及残留。
#[tauri::command]
pub async fn run_uninstall(
    dry_run: bool,
    permanent: Option<bool>,
    non_interactive: Option<bool>,
) -> CommandOutput {
    tauri::async_runtime::spawn_blocking(move || {
        let mut args = vec!["uninstall"];
        if dry_run {
            args.push("--dry-run");
        }
        if permanent.unwrap_or(false) {
            args.push("--permanent");
        }
        if non_interactive.unwrap_or(false) {
            args.push("--non-interactive");
        }
        cli::run_mo(&args)
    })
    .await
    .unwrap_or_else(|_| blocking_error())
}

/// `mo uninstall` 的流式版本。
#[tauri::command]
pub async fn run_uninstall_streaming(
    dry_run: bool,
    permanent: Option<bool>,
    non_interactive: Option<bool>,
    on_line: Channel<String>,
) -> CommandOutput {
    tauri::async_runtime::spawn_blocking(move || {
        let mut args = vec!["uninstall"];
        if dry_run {
            args.push("--dry-run");
        }
        if permanent.unwrap_or(false) {
            args.push("--permanent");
        }
        if non_interactive.unwrap_or(false) {
            args.push("--non-interactive");
        }
        cli::run_mo_streaming(&args, &[], |line| {
            let _ = on_line.send(line);
        })
    })
    .await
    .unwrap_or_else(|_| blocking_error())
}

/// `mo purge`：项目构建 artifact 清理。
#[tauri::command]
pub async fn run_purge(dry_run: bool) -> CommandOutput {
    tauri::async_runtime::spawn_blocking(move || {
        let mut args = vec!["purge"];
        if dry_run {
            args.push("--dry-run");
        }
        cli::run_mo(&args)
    })
    .await
    .unwrap_or_else(|_| blocking_error())
}

/// `mo installer`：installer 文件发现与清理。
#[tauri::command]
pub async fn run_installer(dry_run: bool) -> CommandOutput {
    tauri::async_runtime::spawn_blocking(move || {
        let mut args = vec!["installer"];
        if dry_run {
            args.push("--dry-run");
        }
        cli::run_mo(&args)
    })
    .await
    .unwrap_or_else(|_| blocking_error())
}

/// `mo history`：操作历史。`json=true` 返回 JSON，`limit` 限制条目数。
#[tauri::command]
pub async fn run_history(json: bool, limit: Option<i64>) -> CommandOutput {
    tauri::async_runtime::spawn_blocking(move || {
        if let Some(n) = limit {
            if n > 0 {
                return run_history_with_limit(json, n);
            }
        }
        let mut args = vec!["history"];
        if json {
            args.push("--json");
        }
        cli::run_mo(&args)
    })
    .await
    .unwrap_or_else(|_| blocking_error())
}

/// 单独处理带 limit 的 history 调用，避免生命周期问题。
fn run_history_with_limit(json: bool, limit: i64) -> CommandOutput {
    let limit_str = limit.to_string();
    let arg_vec: Vec<String> = {
        let mut v = vec!["history".to_string()];
        if json {
            v.push("--json".to_string());
        }
        v.push("--limit".to_string());
        v.push(limit_str);
        v
    };
    let arg_refs: Vec<&str> = arg_vec.iter().map(|s| s.as_str()).collect();
    cli::run_mo(&arg_refs)
}

/// `mo touchid enable/disable/status`：Touch ID sudo 便捷配置。
#[tauri::command]
pub async fn run_touchid(action: String, dry_run: bool) -> CommandOutput {
    tauri::async_runtime::spawn_blocking(move || {
        let action_str = action.as_str();
        let mut args = vec!["touchid", action_str];
        if dry_run {
            args.push("--dry-run");
        }
        cli::run_mo(&args)
    })
    .await
    .unwrap_or_else(|_| blocking_error())
}

/// `mo --version`：获取 CLI 版本。
#[tauri::command]
pub async fn get_mole_version() -> CommandOutput {
    tauri::async_runtime::spawn_blocking(|| cli::run_mo(&["--version"]))
        .await
        .unwrap_or_else(|_| blocking_error())
}

// ---------------------------------------------------------------------------
// 原生扫描命令（不调用 mo CLI，直接在 Rust 中扫描）
// ---------------------------------------------------------------------------

/// 检查 `mo` 命令是否可用。
#[tauri::command]
pub fn check_cli() -> bool {
    cli::check_cli_available()
}

/// 原生 purge 扫描：在 Rust 中扫描项目 build artifact。
///
/// 异步执行以避免大型 `node_modules` 遍历阻塞 UI。
#[tauri::command]
pub async fn scan_purge(paths: Option<Vec<String>>) -> Result<PurgeScanResult, String> {
    tauri::async_runtime::spawn_blocking(move || purge::scan(paths.as_deref()))
        .await
        .map_err(|e| format!("扫描任务失败: {}", e))
}

/// 原生 installer 扫描：在 Rust 中扫描 installer 文件。
///
/// 异步执行以避免文件系统遍历阻塞 UI。
#[tauri::command]
pub async fn scan_installer() -> Result<InstallerScanResult, String> {
    tauri::async_runtime::spawn_blocking(installer::scan)
        .await
        .map_err(|e| format!("扫描任务失败: {}", e))
}

/// 通过 macOS Trash 路由删除文件（可恢复）。
///
/// 返回成功删除的数量。部分失败时返回成功数，全部失败时返回 Err。
/// 异步执行以避免大量文件删除阻塞 UI。
#[tauri::command]
pub async fn trash_paths(paths: Vec<String>, command: Option<String>) -> Result<usize, String> {
    let cmd = command.unwrap_or_else(|| "tauri".to_string());
    tauri::async_runtime::spawn_blocking(move || {
        // 写入 mole oplog，使删除操作出现在 mo history 中
        oplog_session_start(&cmd);
        let result = trash::trash_items(&paths);
        let count = paths.len();
        match &result {
            Ok(success) => {
                for p in &paths {
                    oplog_operation(&cmd, "TRASHED", p);
                }
                oplog_session_end(&cmd, *success, 0);
            }
            Err(e) => {
                // 全部失败时也记录 session
                oplog_session_end(&cmd, 0, 0);
            }
        }
        let _ = count;
        result
    })
    .await
    .map_err(|e| format!("删除任务失败: {}", e))?
}

/// 路径校验命令：前端可在调用删除前先校验路径。
#[tauri::command]
pub fn validate_path_cmd(path: String) -> Result<String, String> {
    cli::validate_path(&path)
}

// ---------------------------------------------------------------------------
// 系统 / UX 命令
// ---------------------------------------------------------------------------

/// 在 Finder 中显示指定文件。
#[tauri::command]
pub fn open_finder(path: String) {
    let _ = Command::new("open")
        .arg("-R")
        .arg(&path)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

/// 把文本复制到剪贴板（通过 pbcopy）。
#[tauri::command]
pub fn copy_to_clipboard(text: String) {
    cli::pipe_to_stdin("pbcopy", None, text.as_bytes());
}

// ---------------------------------------------------------------------------
// 更新检查
// ---------------------------------------------------------------------------

/// 检查 Tauri 应用本身是否有新版本。
///
/// 比较当前应用版本（编译时从 `Cargo.toml` 读取）与 GitHub release 最新版本。
#[tauri::command]
pub async fn check_for_update() -> Result<UpdateInfo, String> {
    let current = env!("CARGO_PKG_VERSION").to_string();
    tauri::async_runtime::spawn_blocking(move || update::check_for_update(&current))
        .await
        .map_err(|e| format!("更新检查失败: {}", e))?
}

/// 下载并安装更新（实际调用 `mo update` 或打开 release 页面）。
#[tauri::command]
pub async fn download_and_install(url: String) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || update::download_and_install(&url))
        .await
        .map_err(|e| format!("下载失败: {}", e))?
}

/// 重启 Tauri 应用。
#[tauri::command]
pub fn restart_app() {
    let home = std::env::var("HOME").unwrap_or_default();
    let app_path = format!("{}/Applications/Mole.app", home);
    let _ = Command::new("open")
        .arg(&app_path)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
    std::process::exit(0);
}

// ---------------------------------------------------------------------------
// 应用列表（解析 mo uninstall --list --json 输出）
// ---------------------------------------------------------------------------

/// 获取已安装应用列表，返回解析后的 `AppListEntry` 数组。
///
/// 调用 `mo uninstall --list` 并解析 JSON。CLI 在 stdout 被管道/重定向时
/// 自动切换到 JSON 输出（`[[ ! -t 1 ]]`），不需要也不支持 `--json` 参数。
/// 失败时返回包含完整诊断信息的错误字符串。
#[tauri::command]
pub async fn list_apps() -> Result<Vec<AppListEntry>, String> {
    tauri::async_runtime::spawn_blocking(|| {
        let output = cli::run_mo(&["uninstall", "--list"]);
        if !output.success {
            // 拼接完整诊断信息：exit code + stderr + stdout（CLI 可能把错误
            // 信息输出到 stdout 而非 stderr）
            let mut parts = Vec::new();
            parts.push(format!("mo uninstall --list 失败 (exit={})", output.exit_code));
            if !output.stderr.is_empty() {
                parts.push(format!("stderr: {}", output.stderr.trim()));
            }
            if !output.stdout.is_empty() {
                let stdout_preview = if output.stdout.len() > 500 {
                    format!("{}...(截断)", &output.stdout[..500])
                } else {
                    output.stdout.trim().to_string()
                };
                parts.push(format!("stdout: {}", stdout_preview));
            }
            if output.stderr.is_empty() && output.stdout.is_empty() {
                parts.push("(无输出，可能是 mo 命令不存在或执行异常)".to_string());
            }
            let err_msg = parts.join(" | ");
            crate::logger::log(crate::logger::LogLevel::Error, &err_msg);
            return Err(err_msg);
        }
        let trimmed = output.stdout.trim();
        if trimmed.is_empty() {
            crate::logger::log(crate::logger::LogLevel::Info, "应用列表为空");
            return Ok(Vec::new());
        }
        serde_json::from_str::<Vec<AppListEntry>>(trimmed)
            .map_err(|e| {
                let preview = if trimmed.len() > 300 {
                    &trimmed[..300]
                } else {
                    trimmed
                };
                let msg = format!("解析应用列表 JSON 失败: {} | 原始输出前300字符: {}", e, preview);
                crate::logger::log(crate::logger::LogLevel::Error, &msg);
                msg
            })
    })
    .await
    .map_err(|e| format!("后台任务失败: {}", e))?
}

// ---------------------------------------------------------------------------
// 日志
// ---------------------------------------------------------------------------

/// 读取应用日志文件内容。
///
/// `tail` 指定只返回最后 N 行（0 或负数表示全部）。
#[tauri::command]
pub fn read_app_log(tail: Option<i64>) -> String {
    logger::read_log(tail.unwrap_or(0))
}

/// 清空应用日志文件。
#[tauri::command]
pub fn clear_app_log() -> Result<String, String> {
    logger::clear_log()?;
    Ok("日志已清空".to_string())
}

/// 返回日志文件路径（供前端显示）。
#[tauri::command]
pub fn app_log_path() -> String {
    logger::log_path().to_string_lossy().to_string()
}

/// 写入一条日志（供前端在关键操作时记录）。
#[tauri::command]
pub fn write_log(level: String, message: String) {
    let lvl = match level.to_lowercase().as_str() {
        "trace" => logger::LogLevel::Trace,
        "debug" => logger::LogLevel::Debug,
        "warn" => logger::LogLevel::Warn,
        "error" => logger::LogLevel::Error,
        _ => logger::LogLevel::Info,
    };
    logger::log(lvl, &message);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn run_history_no_limit() {
        let result = run_history(false, None).await;
        assert!(!result.success);
    }

    #[tokio::test]
    async fn run_history_with_limit() {
        let result = run_history(true, Some(10)).await;
        assert!(!result.success);
    }

    #[tokio::test]
    async fn run_history_with_zero_limit_ignores_limit() {
        let result = run_history(false, Some(0)).await;
        assert!(!result.success);
    }

    #[tokio::test]
    async fn run_history_with_negative_limit_ignores_limit() {
        let result = run_history(false, Some(-5)).await;
        assert!(!result.success);
    }

    #[tokio::test]
    async fn run_touchid_invalid_action() {
        let result = run_touchid("invalid".to_string(), false).await;
        assert!(!result.success);
    }

    #[tokio::test]
    async fn run_touchid_dry_run() {
        let result = run_touchid("status".to_string(), true).await;
        assert!(!result.success);
    }

    #[test]
    fn check_cli_returns_bool() {
        let _ = check_cli();
    }

    #[tokio::test]
    async fn scan_purge_returns_result() {
        let result = scan_purge(None).await;
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn scan_installer_returns_result() {
        let result = scan_installer().await;
        assert!(result.is_ok());
    }

    #[test]
    fn validate_path_cmd_rejects_relative() {
        let result = validate_path_cmd("relative/path".to_string());
        assert!(result.is_err());
    }

    #[test]
    fn validate_path_cmd_accepts_absolute() {
        let result = validate_path_cmd("/tmp/test".to_string());
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), "/tmp/test");
    }

    #[test]
    fn validate_path_cmd_expands_tilde() {
        let home = std::env::var("HOME").unwrap_or_default();
        let result = validate_path_cmd("~/Downloads".to_string());
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), format!("{}/Downloads", home));
    }

    #[tokio::test]
    async fn trash_paths_empty_returns_ok_zero() {
        let result = trash_paths(vec![], None).await;
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), 0);
    }

    #[tokio::test]
    async fn trash_paths_invalid_returns_err() {
        let result = trash_paths(vec!["relative/path".to_string()], None).await;
        assert!(result.is_err());
    }
}
