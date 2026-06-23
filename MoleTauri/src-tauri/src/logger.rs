//! 应用日志记录器。
//!
//! 将 Tauri 应用运行时日志写入文件，供 app 内日志查询页面读取。
//! 日志文件路径：`~/.local/share/mole-tauri/app.log`
//!
//! 日志格式：`[YYYY-MM-DD HH:MM:SS] [LEVEL] message`
//! 文件大小超过 1MB 时自动轮转（保留一个 `.1` 备份）。

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::Mutex;

/// 最大日志文件大小（1MB），超过后轮转。
const MAX_LOG_SIZE: u64 = 1024 * 1024;

/// 日志级别。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogLevel {
    Trace,
    Debug,
    Info,
    Warn,
    Error,
}

impl LogLevel {
    fn as_str(self) -> &'static str {
        match self {
            LogLevel::Trace => "TRACE",
            LogLevel::Debug => "DEBUG",
            LogLevel::Info => "INFO",
            LogLevel::Warn => "WARN",
            LogLevel::Error => "ERROR",
        }
    }
}

/// 全局日志文件路径（首次写入时初始化）。
static LOG_PATH: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();

/// 全局日志写入锁，防止并发写入交错。
static LOG_LOCK: Mutex<()> = Mutex::new(());

/// 返回日志文件路径。
pub fn log_path() -> PathBuf {
    LOG_PATH
        .get_or_init(|| {
            let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
            PathBuf::from(format!("{}/.local/share/mole-tauri/app.log", home))
        })
        .clone()
}

/// 写入一条日志。
pub fn log(level: LogLevel, msg: &str) {
    let _guard = LOG_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let path = log_path();

    // 确保目录存在
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }

    // 检查文件大小，超过阈值则轮转
    if let Ok(meta) = fs::metadata(&path) {
        if meta.len() > MAX_LOG_SIZE {
            let backup = path.with_extension("log.1");
            let _ = fs::rename(&path, &backup);
        }
    }

    let timestamp = current_timestamp();
    let line = format!("[{}] [{}] {}\n", timestamp, level.as_str(), msg);

    if let Ok(mut file) = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        let _ = file.write_all(line.as_bytes());
    }
}

/// 便捷宏：记录 INFO 级别日志。
#[macro_export]
macro_rules! log_info {
    ($($arg:tt)*) => {
        $crate::logger::log($crate::logger::LogLevel::Info, &format!($($arg)*))
    };
}

/// 便捷宏：记录 WARN 级别日志。
#[macro_export]
macro_rules! log_warn {
    ($($arg:tt)*) => {
        $crate::logger::log($crate::logger::LogLevel::Warn, &format!($($arg)*))
    };
}

/// 便捷宏：记录 ERROR 级别日志。
#[macro_export]
macro_rules! log_error {
    ($($arg:tt)*) => {
        $crate::logger::log($crate::logger::LogLevel::Error, &format!($($arg)*))
    };
}

/// 读取日志文件内容，返回全部文本。
///
/// `tail` 指定只返回最后 N 行（0 或负数表示全部）。
pub fn read_log(tail: i64) -> String {
    let path = log_path();
    let content = match fs::read_to_string(&path) {
        Ok(c) => c,
        Err(_) => return String::new(),
    };

    if tail <= 0 {
        return content;
    }

    let lines: Vec<&str> = content.lines().collect();
    let start = if lines.len() > tail as usize {
        lines.len() - tail as usize
    } else {
        0
    };
    lines[start..].join("\n")
}

/// 清空日志文件。
pub fn clear_log() -> Result<(), String> {
    let path = log_path();
    OpenOptions::new()
        .write(true)
        .truncate(true)
        .open(&path)
        .map(|_| ())
        .map_err(|e| format!("清空日志失败: {}", e))
}

/// 返回当前时间戳字符串（本地时间）。
fn current_timestamp() -> String {
    // 使用 `date` 命令获取本地时间，避免引入 chrono 依赖。
    let output = std::process::Command::new("date")
        .arg("+%Y-%m-%d %H:%M:%S")
        .stdout(std::process::Stdio::piped())
        .output();

    match output {
        Ok(o) if o.status.success() => {
            String::from_utf8_lossy(&o.stdout).trim().to_string()
        }
        _ => {
            // 回退到 Unix 时间戳
            let secs = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0);
            format!("epoch:{}", secs)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn log_path_ends_with_app_log() {
        let path = log_path();
        assert!(path.to_string_lossy().ends_with("app.log"));
    }

    #[test]
    fn log_level_as_str() {
        assert_eq!(LogLevel::Info.as_str(), "INFO");
        assert_eq!(LogLevel::Warn.as_str(), "WARN");
        assert_eq!(LogLevel::Error.as_str(), "ERROR");
    }

    #[test]
    fn read_log_returns_string() {
        let s = read_log(0);
        // 可能是空字符串（测试环境无日志），也可能有内容
        assert!(s.len() >= 0);
    }
}
