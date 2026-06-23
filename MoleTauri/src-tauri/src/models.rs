//! 共享数据结构。
//!
//! 这些结构体对应前端 TypeScript 接口以及 `mo` CLI 的 JSON 输出。
//! 字段命名使用 `#[serde(rename)]` 把 Rust 的 snake_case 转成 CLI 使用的
//! snake_case（多数情况下两者一致）或 camelCase（前端历史约定）。

use serde::{Deserialize, Serialize};

/// CLI 命令的统一返回结构。
///
/// 前端 `invoke` 调用所有 `run_*` 命令时都拿到这个对象，包含 stdout / stderr
/// 以及退出码。`success` 等价于 `exit_code == 0`，方便前端直接判断。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommandOutput {
    pub success: bool,
    pub stdout: String,
    pub stderr: String,
    /// 进程退出码；命令无法启动时为 -1。
    pub exit_code: i32,
}

impl CommandOutput {
    pub fn ok(stdout: String) -> Self {
        Self {
            success: true,
            stdout,
            stderr: String::new(),
            exit_code: 0,
        }
    }

    pub fn err(stderr: String) -> Self {
        Self {
            success: false,
            stdout: String::new(),
            stderr,
            exit_code: -1,
        }
    }
}

/// GitHub release 检查结果。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateInfo {
    pub version: String,
    pub download_url: String,
    pub notes: String,
}

/// `mo analyze --json` 中的单个目录条目。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AnalyzeEntry {
    pub name: String,
    pub path: String,
    pub size: i64,
    #[serde(rename = "is_dir")]
    pub is_dir: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub insight: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cleanable: Option<bool>,
    #[serde(rename = "last_access", skip_serializing_if = "Option::is_none")]
    pub last_access: Option<String>,
}

/// `mo analyze --json` 顶层结构。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AnalyzeResult {
    pub path: String,
    pub overview: bool,
    pub entries: Vec<AnalyzeEntry>,
    #[serde(rename = "large_files", skip_serializing_if = "Option::is_none")]
    pub large_files: Option<Vec<AnalyzeFileEntry>>,
    #[serde(rename = "total_size")]
    pub total_size: i64,
    #[serde(rename = "total_files", skip_serializing_if = "Option::is_none")]
    pub total_files: Option<i64>,
}

/// `mo analyze --json` 中 `large_files` 数组的元素。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AnalyzeFileEntry {
    pub name: String,
    pub path: String,
    pub size: i64,
}

/// `mo status --json` 的简化版，仅保留前端 dashboard 需要的字段。
///
/// 完整快照字段非常多，前端目前只关心主机名、CPU、内存、磁盘等核心指标。
/// 其它字段通过原始 stdout 透传给前端按需解析。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatusSnapshot {
    pub host: String,
    pub platform: String,
    pub uptime: String,
    #[serde(rename = "uptime_seconds")]
    pub uptime_seconds: f64,
    #[serde(rename = "health_score")]
    pub health_score: i64,
    #[serde(rename = "health_score_msg")]
    pub health_score_msg: String,
    #[serde(rename = "trash_size")]
    pub trash_size: f64,
    #[serde(rename = "trash_approx")]
    pub trash_approx: bool,
}

/// `mo uninstall --list` 单条应用。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppListEntry {
    pub name: String,
    #[serde(rename = "bundle_id", default)]
    pub bundle_id: String,
    #[serde(default = "default_source")]
    pub source: String,
    #[serde(rename = "uninstall_name", default)]
    pub uninstall_name: String,
    pub path: String,
    #[serde(default = "default_size_str")]
    pub size: String,
    #[serde(rename = "size_kb", default)]
    pub size_kb: i64,
    #[serde(rename = "last_used_epoch", default)]
    pub last_used_epoch: i64,
}

fn default_source() -> String {
    "App".to_string()
}

fn default_size_str() -> String {
    "N/A".to_string()
}

/// 原生 purge 扫描器找到的单个 artifact。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PurgeArtifact {
    /// artifact 在磁盘上的绝对路径。
    pub path: String,
    /// 字节数。
    pub size: i64,
    /// artifact 类型（目录名，如 `node_modules`、`target`）。
    pub artifact_type: String,
    /// artifact 所在项目的目录名（用于前端分组显示）。
    pub project_path: String,
    /// 距上次修改的天数。
    pub age_days: i64,
    /// 是否在 `MIN_AGE_DAYS` 窗口内（近期修改，默认不选中）。
    pub is_recent: bool,
}

/// 原生 purge 扫描结果。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PurgeScanResult {
    pub artifacts: Vec<PurgeArtifact>,
    pub total_size: i64,
    pub total_count: i64,
    pub scan_paths: Vec<String>,
}

/// 原生 installer 扫描器找到的单个文件。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InstallerFile {
    pub path: String,
    pub name: String,
    pub size: i64,
    /// 来源标签：Downloads / Desktop / Library / Shared / Homebrew / iCloud / Mail / Telegram。
    pub source: String,
    /// 文件扩展名（小写，不含 `.`）。
    pub file_type: String,
    /// `.zip` 文件是否包含 installer payload（.app/.pkg/.dmg/.xip）。
    pub is_installer_zip: bool,
}

/// 原生 installer 扫描结果。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InstallerScanResult {
    pub files: Vec<InstallerFile>,
    pub total_size: i64,
    pub total_count: i64,
}

/// `mo history --json` 中单次操作会话。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HistorySession {
    pub command: String,
    #[serde(rename = "started_at")]
    pub started_at: String,
    #[serde(rename = "ended_at")]
    pub ended_at: String,
    pub items: i64,
    pub size: String,
    #[serde(rename = "operation_count")]
    pub operation_count: i64,
    pub actions: HistoryActions,
}

/// `HistorySession.actions` 子结构。
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct HistoryActions {
    #[serde(default)]
    pub removed: i64,
    #[serde(default)]
    pub trashed: i64,
    #[serde(default)]
    pub skipped: i64,
    #[serde(default)]
    pub failed: i64,
    #[serde(default)]
    pub rebuilt: i64,
    #[serde(default)]
    pub other: i64,
}

/// `mo history --json` 中单条删除审计记录。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HistoryDeletion {
    pub timestamp: String,
    pub mode: String,
    pub status: String,
    #[serde(rename = "size_kb", skip_serializing_if = "Option::is_none")]
    pub size_kb: Option<i64>,
    pub path: String,
}

/// `mo history --json` 顶层结构。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HistoryResult {
    pub logs: HistoryLogs,
    pub limit: i64,
    pub sessions: Vec<HistorySession>,
    pub deletions: Vec<HistoryDeletion>,
}

/// `HistoryResult.logs` 子结构。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HistoryLogs {
    pub operations: String,
    pub deletions: String,
}
