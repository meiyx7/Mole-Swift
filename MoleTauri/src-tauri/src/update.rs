//! CLI 更新检查器。
//!
//! 检查 `tw93/Mole` 仓库（CLI 的官方仓库）的 GitHub release，判断是否有
//! 新版本。注意：这里检查的是 **CLI** 的版本，不是 Tauri 应用本身。
//! Tauri 应用本身的自更新由 Tauri updater 插件负责；本模块仅供 Settings
//! 页面显示 "CLI 有新版本可用" 之类的提示。
//!
//! 修复历史：原 `main.rs` 错误地指向 `meiyx7/Mole-Swift`（Mac app 的 fork
//! 仓库），这里改为 `tw93/Mole`（CLI 上游）。

use crate::models::UpdateInfo;
use std::process::{Command, Stdio};

/// CLI 上游仓库（owner/name）。这是 `mo` CLI 的官方仓库。
const REPO: &str = "tw93/Mole";

/// GitHub API endpoint for the latest release.
fn latest_release_url() -> String {
    format!("https://api.github.com/repos/{}/releases/latest", REPO)
}

/// 检查 CLI 是否有新版本。
///
/// `current_version` 是当前安装的 CLI 版本（如 "1.38.0"），不带 `v` 前缀。
/// 返回 `Ok(UpdateInfo)` 表示有新版本；返回 `Err` 表示无新版本或检查失败。
pub fn check_for_update(current_version: &str) -> Result<UpdateInfo, String> {
    let url = latest_release_url();
    let output = Command::new("curl")
        .args([
            "-s",
            "-H",
            "Accept: application/vnd.github+json",
            "-H",
            "User-Agent: MoleTauri",
            &url,
        ])
        .stdin(Stdio::null())
        .output()
        .map_err(|e| format!("无法启动 curl: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        return Err(format!("GitHub API 请求失败: {}", stderr.trim()));
    }

    let json_str = String::from_utf8_lossy(&output.stdout).to_string();
    let v: serde_json::Value = serde_json::from_str(&json_str)
        .map_err(|e| format!("无法解析 GitHub 响应: {}", e))?;

    // 404 时 GitHub 返回 {"message": "Not Found"}。
    if v.get("message").and_then(|m| m.as_str()) == Some("Not Found") {
        return Err("尚未发布任何 release".to_string());
    }

    let tag_raw = v["tag_name"].as_str().unwrap_or("").trim();
    if tag_raw.is_empty() {
        return Err("无法获取版本号".to_string());
    }
    // CLI release tag 用大写 V 前缀（如 V1.38.0），但版本比较时统一去掉前缀。
    let tag = tag_raw.trim_start_matches('V').trim_start_matches('v');
    let notes = v["body"].as_str().unwrap_or("新版本已发布").to_string();

    if !is_newer(tag, current_version) {
        return Err("已是最新版本".to_string());
    }

    // 找 .zip 资产 URL（CLI release 通常附带 SHA256SUMS 和二进制，但更新
    // 走 `mo update` 命令而不是直接下载 zip）。这里仍返回一个 URL 供前端
    // 显示 release 页面。
    let download_url = v["assets"]
        .as_array()
        .and_then(|assets| {
            assets.iter().find_map(|a| {
                let name = a["name"].as_str().unwrap_or("");
                if name.ends_with(".zip") {
                    a["browser_download_url"].as_str().map(|s| s.to_string())
                } else {
                    None
                }
            })
        })
        .or_else(|| {
            // 没有 zip 资产时回退到 release HTML 页面。
            v["html_url"].as_str().map(|s| s.to_string())
        })
        .ok_or_else(|| "未找到下载包".to_string())?;

    Ok(UpdateInfo {
        version: tag.to_string(),
        download_url,
        notes,
    })
}

/// 下载并安装 CLI 更新。
///
/// 这里不直接下载 zip（CLI 的 release 资产是编译好的二进制 + SHA256SUMS，
/// 安装逻辑由 `mo update` 命令处理）。我们直接调用 `mo update`，让 CLI
/// 自己处理下载、校验、安装。
///
/// `url` 参数保留是为了兼容前端现有调用签名，实际不使用。
pub fn download_and_install(_url: &str) -> Result<String, String> {
    // 测试模式：跳过实际更新，防止 CI 触发网络请求。
    if std::env::var("MOLE_TEST_NO_AUTH").unwrap_or_default() == "1" {
        return Ok("测试模式：更新已跳过".to_string());
    }

    let output = Command::new("mo")
        .args(["update"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|e| format!("无法启动 mo update: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        return Err(format!("mo update 失败: {}", stderr.trim()));
    }

    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    Ok(stdout.trim().to_string())
}

/// 语义版本比较：`lhs` 是否比 `rhs` 新。
///
/// 去掉前缀 `v`/`V` 和 prerelease 后缀（如 `-nightly`），按 major.minor.patch
/// 比较。
fn is_newer(lhs: &str, rhs: &str) -> bool {
    let l = parse_version(lhs);
    let r = parse_version(rhs);
    if l.0 != r.0 {
        return l.0 > r.0;
    }
    if l.1 != r.1 {
        return l.1 > r.1;
    }
    l.2 > r.2
}

/// 解析版本字符串为 (major, minor, patch)。去掉 `v`/`V` 前缀和 prerelease 后缀。
fn parse_version(s: &str) -> (i64, i64, i64) {
    let mut cleaned = s.trim().trim_start_matches('v').trim_start_matches('V');
    // 去掉 prerelease 后缀：`1.44.0-nightly` → `1.44.0`。
    if let Some(dash) = cleaned.find('-') {
        cleaned = &cleaned[..dash];
    }
    let parts: Vec<i64> = cleaned
        .split('.')
        .map(|p| p.parse::<i64>().unwrap_or(0))
        .collect();
    (
        parts.first().copied().unwrap_or(0),
        parts.get(1).copied().unwrap_or(0),
        parts.get(2).copied().unwrap_or(0),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_version_simple() {
        assert_eq!(parse_version("1.38.0"), (1, 38, 0));
    }

    #[test]
    fn parse_version_v_prefix() {
        assert_eq!(parse_version("v1.38.0"), (1, 38, 0));
    }

    #[test]
    fn parse_version_capital_v_prefix() {
        assert_eq!(parse_version("V1.38.0"), (1, 38, 0));
    }

    #[test]
    fn parse_version_prerelease() {
        assert_eq!(parse_version("1.44.0-nightly"), (1, 44, 0));
    }

    #[test]
    fn parse_version_short() {
        assert_eq!(parse_version("1"), (1, 0, 0));
        assert_eq!(parse_version("1.2"), (1, 2, 0));
    }

    #[test]
    fn parse_version_invalid() {
        assert_eq!(parse_version("notaversion"), (0, 0, 0));
    }

    #[test]
    fn is_newer_major() {
        assert!(is_newer("2.0.0", "1.0.0"));
        assert!(!is_newer("1.0.0", "2.0.0"));
    }

    #[test]
    fn is_newer_minor() {
        assert!(is_newer("1.38.0", "1.37.0"));
        assert!(!is_newer("1.37.0", "1.38.0"));
    }

    #[test]
    fn is_newer_patch() {
        assert!(is_newer("1.38.1", "1.38.0"));
        assert!(!is_newer("1.38.0", "1.38.1"));
    }

    #[test]
    fn is_newer_equal() {
        assert!(!is_newer("1.38.0", "1.38.0"));
    }

    #[test]
    fn is_newer_with_prefixes() {
        assert!(is_newer("V1.39.0", "1.38.0"));
        assert!(is_newer("v1.39.0", "1.38.0"));
    }

    #[test]
    fn is_newer_with_prerelease() {
        // prerelease 版本按其基础版本比较。
        assert!(is_newer("1.45.0-nightly", "1.44.0"));
        assert!(!is_newer("1.44.0-nightly", "1.44.0"));
    }

    #[test]
    fn repo_is_tw93_mole() {
        // 防止回归：原代码错误指向 meiyx7/Mole-Swift。
        assert_eq!(REPO, "tw93/Mole");
    }

    #[test]
    fn latest_release_url_correct() {
        assert_eq!(
            latest_release_url(),
            "https://api.github.com/repos/tw93/Mole/releases/latest"
        );
    }
}
