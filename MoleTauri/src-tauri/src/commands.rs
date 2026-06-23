//! 所有 `#[tauri::command]` 函数。
//!
//! 命令签名与前端 `invoke` 调用保持兼容。新增的流式命令使用
//! `tauri::ipc::Channel` 逐行推送输出，前端可通过 `Channel` API 实时接收。
//!
//! 安全约束：
//! - 所有清理类命令自动附加 `MOLE_NON_INTERACTIVE=1`（在 `cli.rs` 中实现）。
//! - stdin 重定向到 `/dev/null`（在 `cli.rs` 中实现）。
//! - 涉及路径的命令先通过 `validate_path` 校验。
//! - 删除走 Trash 路由（`trash.rs`），不直接 `rm -rf`。

use crate::cli;
use crate::installer;
use crate::models::{
    AppListEntry, CommandOutput, InstallerScanResult, PurgeScanResult, UpdateInfo,
};
use crate::purge;
use crate::trash;
use crate::update;
use std::process::{Command, Stdio};
use tauri::ipc::Channel;

// ---------------------------------------------------------------------------
// 清理类命令
// ---------------------------------------------------------------------------

/// `mo clean`：深度清理系统缓存、浏览器缓存、开发工具缓存等。
#[tauri::command]
pub fn run_clean(dry_run: bool, verbose: bool) -> CommandOutput {
    let mut args = vec!["clean"];
    if dry_run {
        args.push("--dry-run");
    }
    if verbose {
        args.push("--verbose");
    }
    cli::run_mo(&args)
}

/// `mo clean` 的流式版本：每读出一行 stdout 就通过 `on_line` 推送给前端。
#[tauri::command]
pub fn run_clean_streaming(
    dry_run: bool,
    verbose: bool,
    on_line: Channel<String>,
) -> CommandOutput {
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
}

/// `mo analyze --json`：磁盘分析，返回 JSON 字符串。
#[tauri::command]
pub fn run_analyze(path: Option<String>) -> CommandOutput {
    let mut args = vec!["analyze", "--json"];
    let path_str = path.unwrap_or_default();
    if !path_str.is_empty() {
        args.push(&path_str);
    }
    cli::run_mo(&args)
}

/// `mo status`：健康仪表盘。`json=true` 时返回 JSON 输出供前端解析。
#[tauri::command]
pub fn run_status(json: bool) -> CommandOutput {
    let mut args = vec!["status"];
    if json {
        args.push("--json");
    }
    cli::run_mo(&args)
}

/// `mo optimize`：维护任务。
#[tauri::command]
pub fn run_optimize(dry_run: bool) -> CommandOutput {
    let mut args = vec!["optimize"];
    if dry_run {
        args.push("--dry-run");
    }
    cli::run_mo(&args)
}

/// `mo optimize` 的流式版本。
#[tauri::command]
pub fn run_optimize_streaming(dry_run: bool, on_line: Channel<String>) -> CommandOutput {
    let mut args = vec!["optimize"];
    if dry_run {
        args.push("--dry-run");
    }
    cli::run_mo_streaming(&args, &[], |line| {
        let _ = on_line.send(line);
    })
}

/// `mo uninstall`：安全卸载应用及残留。
///
/// `permanent` 和 `non_interactive` 是可选参数，前端不传时默认 false，
/// 保持与旧版 `run_uninstall(dry_run)` 调用的向后兼容。
#[tauri::command]
pub fn run_uninstall(
    dry_run: bool,
    permanent: Option<bool>,
    non_interactive: Option<bool>,
) -> CommandOutput {
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
}

/// `mo uninstall` 的流式版本。
#[tauri::command]
pub fn run_uninstall_streaming(
    dry_run: bool,
    permanent: Option<bool>,
    non_interactive: Option<bool>,
    on_line: Channel<String>,
) -> CommandOutput {
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
}

/// `mo purge`：项目构建 artifact 清理。
#[tauri::command]
pub fn run_purge(dry_run: bool) -> CommandOutput {
    let mut args = vec!["purge"];
    if dry_run {
        args.push("--dry-run");
    }
    cli::run_mo(&args)
}

/// `mo installer`：installer 文件发现与清理。
#[tauri::command]
pub fn run_installer(dry_run: bool) -> CommandOutput {
    let mut args = vec!["installer"];
    if dry_run {
        args.push("--dry-run");
    }
    cli::run_mo(&args)
}

/// `mo history`：操作历史。`json=true` 返回 JSON，`limit` 限制条目数。
#[tauri::command]
pub fn run_history(json: bool, limit: Option<i64>) -> CommandOutput {
    // 带 limit 时需要把数字转成 &str，单独走一个函数避免生命周期问题。
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
pub fn run_touchid(action: String, dry_run: bool) -> CommandOutput {
    let action_str = action.as_str();
    let mut args = vec!["touchid", action_str];
    if dry_run {
        args.push("--dry-run");
    }
    cli::run_mo(&args)
}

/// `mo --version`：获取 CLI 版本。
#[tauri::command]
pub fn get_mole_version() -> CommandOutput {
    cli::run_mo(&["--version"])
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
/// `paths` 为 None 时使用默认搜索路径 + 用户配置文件；非 None 时附加到
/// 默认路径之后。
#[tauri::command]
pub fn scan_purge(paths: Option<Vec<String>>) -> Result<PurgeScanResult, String> {
    Ok(purge::scan(paths.as_deref()))
}

/// 原生 installer 扫描：在 Rust 中扫描 installer 文件。
#[tauri::command]
pub fn scan_installer() -> Result<InstallerScanResult, String> {
    Ok(installer::scan())
}

/// 通过 macOS Trash 路由删除文件（可恢复）。
///
/// 返回成功删除的数量。部分失败时返回成功数，全部失败时返回 Err。
#[tauri::command]
pub fn trash_paths(paths: Vec<String>) -> Result<usize, String> {
    trash::trash_items(&paths)
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
    // 不做严格校验：open -R 对非法路径会静默失败，无安全风险。
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

/// 检查 CLI 是否有新版本。`current_version` 是当前 CLI 版本（无 `v` 前缀）。
#[tauri::command]
pub fn check_for_update(current_version: String) -> Result<UpdateInfo, String> {
    update::check_for_update(&current_version)
}

/// 下载并安装 CLI 更新（实际调用 `mo update`）。
///
/// `url` 参数保留以兼容前端现有调用签名，实际由 `mo update` 自行处理下载。
#[tauri::command]
pub fn download_and_install(url: String) -> Result<String, String> {
    update::download_and_install(&url)
}

/// 重启 Tauri 应用。
///
/// 重新打开 `~/Applications/Mole.app` 并退出当前进程。如果应用在
/// `/Applications` 下，路径可能不同，但 Tauri 应用通常装在用户目录。
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
/// 调用 `mo uninstall --list --json` 并解析 JSON。失败时返回原始
/// `CommandOutput` 的 stderr。
#[tauri::command]
pub fn list_apps() -> Result<Vec<AppListEntry>, String> {
    let output = cli::run_mo(&["uninstall", "--list", "--json"]);
    if !output.success {
        return Err(output.stderr);
    }
    let trimmed = output.stdout.trim();
    if trimmed.is_empty() {
        return Ok(Vec::new());
    }
    serde_json::from_str::<Vec<AppListEntry>>(trimmed)
        .map_err(|e| format!("解析应用列表失败: {} (原始输出: {})", e, trimmed))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn run_history_no_limit() {
        // 不带 limit 时应正常调用（CLI 不存在时返回错误 CommandOutput，不 panic）。
        let result = run_history(false, None);
        // CLI 在测试环境通常不存在，stderr 应包含 "无法启动"。
        assert!(!result.success);
    }

    #[test]
    fn run_history_with_limit() {
        let result = run_history(true, Some(10));
        assert!(!result.success);
    }

    #[test]
    fn run_history_with_zero_limit_ignores_limit() {
        // limit=0 时应忽略 limit 参数，正常调用。
        let result = run_history(false, Some(0));
        assert!(!result.success);
    }

    #[test]
    fn run_history_with_negative_limit_ignores_limit() {
        let result = run_history(false, Some(-5));
        assert!(!result.success);
    }

    #[test]
    fn run_touchid_invalid_action() {
        // 即使 action 非法，也应返回 CommandOutput 而非 panic。
        let result = run_touchid("invalid".to_string(), false);
        assert!(!result.success);
    }

    #[test]
    fn run_touchid_dry_run() {
        let result = run_touchid("status".to_string(), true);
        assert!(!result.success);
    }

    #[test]
    fn check_cli_returns_bool() {
        // 不 panic 即可，结果取决于环境。
        let _ = check_cli();
    }

    #[test]
    fn scan_purge_returns_result() {
        let result = scan_purge(None);
        assert!(result.is_ok());
    }

    #[test]
    fn scan_installer_returns_result() {
        let result = scan_installer();
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

    #[test]
    fn trash_paths_empty_returns_ok_zero() {
        let result = trash_paths(vec![]);
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), 0);
    }

    #[test]
    fn trash_paths_invalid_returns_err() {
        let result = trash_paths(vec!["relative/path".to_string()]);
        assert!(result.is_err());
    }
}
