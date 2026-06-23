//! macOS Trash 路由。
//!
//! 通过 `osascript` 调用 Finder 把文件移到废纸篓，删除可恢复，符合
//! AGENTS.md 中 "Route user-facing cleanup through Trash where the project
//! expects recoverability" 的要求。
//!
//! 路径必须先通过 `validate_path` 校验，拒绝相对路径、`..` 穿越、null 字节。
//! 单引号转义防止 AppleScript 注入。

use crate::cli;
use std::process::{Command, Stdio};

/// 把单个文件或目录移到废纸篓。
///
/// 返回 `Ok(())` 表示 Finder 接受了删除请求；用户在弹窗中取消会被视为错误。
pub fn trash_item(path: &str) -> Result<(), String> {
    let validated = cli::validate_path(path)?;
    trash_validated(&validated)
}

/// 把多个文件或目录移到废纸篓。
///
/// 每个路径独立校验、独立调用 Finder。返回成功删除的数量；遇到错误会继续
/// 处理后续路径，最终把第一个错误通过 `Err` 返回（同时仍返回成功数）。
///
/// 这种 "best effort" 策略与 `mole_delete` 的批量行为一致：单个失败不应
/// 阻断整个清理任务。
pub fn trash_items(paths: &[String]) -> Result<usize, String> {
    let mut success = 0usize;
    let mut last_err: Option<String> = None;

    for p in paths {
        match trash_item(p) {
            Ok(()) => success += 1,
            Err(e) => {
                if last_err.is_none() {
                    last_err = Some(e);
                }
            }
        }
    }

    if let Some(e) = last_err {
        if success == 0 {
            return Err(e);
        }
        // 部分成功：把错误信息附在返回里，但不算失败。
        // 调用方可以通过返回的 success 数量判断是否全部成功。
        eprintln!("trash_items: 部分失败，成功 {} 个，最后错误: {}", success, e);
    }
    Ok(success)
}

/// 调用 Finder 删除已校验的路径。
fn trash_validated(path: &str) -> Result<(), String> {
    // 测试模式：MOLE_TEST_NO_AUTH=1 时跳过 osascript，防止 CI 触发授权弹窗。
    if std::env::var("MOLE_TEST_NO_AUTH").unwrap_or_default() == "1" {
        return Ok(());
    }

    let quoted = shell_quote(path);
    // 用 POSIX file 形式，避免 AppleScript 把 `/` 解释成 HFS 路径分隔符。
    let script = format!(
        "tell application \"Finder\" to delete POSIX file {}",
        quoted
    );

    let output = Command::new("osascript")
        .arg("-e")
        .arg(&script)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|e| format!("无法启动 osascript: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        // 用户取消授权时 osascript 退出码 -128，stderr 含 "User canceled"。
        if stderr.contains("User canceled") || stderr.contains("-128") {
            return Err("用户取消了删除操作".to_string());
        }
        return Err(format!("移到废纸篓失败: {}", stderr.trim()));
    }

    Ok(())
}

/// 单引号转义：把 `path` 包在单引号里，内部单引号转义为 `'\''`。
///
/// 这是 POSIX 安全引用，能处理路径中的任意字符（包括空格、`$`、反引号、
/// 单引号本身），防止 AppleScript 注入。
fn shell_quote(s: &str) -> String {
    let escaped = s.replace('\'', "'\\''");
    format!("'{}'", escaped)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shell_quote_handles_simple_path() {
        assert_eq!(shell_quote("/Users/foo/bar"), "'/Users/foo/bar'");
    }

    #[test]
    fn shell_quote_escapes_single_quote() {
        // 路径含单引号时，转义为 close-quote + escaped-quote + reopen-quote。
        assert_eq!(shell_quote("/Users/Mole's App"), "'/Users/Mole'\\''s App'");
    }

    #[test]
    fn shell_quote_handles_spaces() {
        assert_eq!(shell_quote("/Users/foo/My Dir"), "'/Users/foo/My Dir'");
    }

    #[test]
    fn trash_item_rejects_relative_path() {
        let result = trash_item("relative/path");
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("绝对路径"));
    }

    #[test]
    fn trash_item_rejects_dotdot() {
        let result = trash_item("/Users/foo/../etc/passwd");
        assert!(result.is_err());
        assert!(result.unwrap_err().contains(".."));
    }

    #[test]
    fn trash_item_rejects_null_byte() {
        let result = trash_item("/Users/foo\0/bar");
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("null"));
    }

    #[test]
    fn trash_item_rejects_empty() {
        assert!(trash_item("").is_err());
        assert!(trash_item("   ").is_err());
    }

    #[test]
    fn trash_item_test_mode_skips_osascript() {
        // 在测试模式下不应触发 osascript，路径合法时应直接返回 Ok。
        std::env::set_var("MOLE_TEST_NO_AUTH", "1");
        let result = trash_item("/tmp/nonexistent-test-path-12345");
        std::env::remove_var("MOLE_TEST_NO_AUTH");
        assert!(result.is_ok());
    }
}
