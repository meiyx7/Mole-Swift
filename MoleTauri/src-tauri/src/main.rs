//! Mole Tauri 应用入口。
//!
//! 注册所有 `#[tauri::command]` 函数并启动 Tauri 运行时。
//! 命令实现分布在 `commands.rs`、`cli.rs`、`purge.rs`、`installer.rs`、
//! `trash.rs`、`update.rs`，数据结构定义在 `models.rs`。

mod cli;
mod commands;
mod installer;
mod models;
mod purge;
mod trash;
mod update;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            // 清理类命令
            commands::run_clean,
            commands::run_clean_streaming,
            commands::run_analyze,
            commands::run_status,
            commands::run_optimize,
            commands::run_optimize_streaming,
            commands::run_uninstall,
            commands::run_uninstall_streaming,
            commands::run_purge,
            commands::run_installer,
            commands::run_history,
            commands::run_touchid,
            commands::get_mole_version,
            // 原生扫描命令
            commands::check_cli,
            commands::scan_purge,
            commands::scan_installer,
            commands::trash_paths,
            commands::validate_path_cmd,
            commands::list_apps,
            // 系统 / UX 命令
            commands::open_finder,
            commands::copy_to_clipboard,
            commands::restart_app,
            // 更新检查
            commands::check_for_update,
            commands::download_and_install,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
