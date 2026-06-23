//! Tauri 应用更新检查器。
//!
//! 检查 `meiyx7/Mole-Swift` 仓库中 `tauri-v*` 标签的 GitHub release，
//! 判断 Tauri 应用本身是否有新版本。
//!
//! 与 Mac app 的 `v*` 标签和 CLI 的 `V*` 标签区分：
//! - `tauri-v0.3.0` — Tauri 应用发布标签（本模块检测的目标）
//! - `v1.7.14` — Mac app 发布标签
//! - `V1.38.0` — CLI 发布标签

use crate::models::UpdateInfo;
use std::process::{Command, Stdio};

/// Tauri 应用所在仓库（owner/name）。
const REPO: &str = "meiyx7/Mole-Swift";

/// Tauri 发布标签的前缀。Mac app 用 `v`，CLI 用 `V`，Tauri 用 `tauri-v`。
const TAURI_TAG_PREFIX: &str = "tauri-v";

/// GitHub API endpoint，列出所有 release（按创建时间降序）。
fn releases_url() -> String {
    format!(
        "https://api.github.com/repos/{}/releases?per_page=100",
        REPO
    )
}

/// 检查 Tauri 应用是否有新版本。
///
/// `current_version` 是当前应用版本（如 "0.3.0"），不带任何前缀。
/// 返回 `Ok(UpdateInfo)` 表示有新版本；返回 `Err` 表示无新版本或检查失败。
pub fn check_for_update(current_version: &str) -> Result<UpdateInfo, String> {
    let url = releases_url();
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

    let releases = v
        .as_array()
        .ok_or_else(|| "响应格式异常：期望数组".to_string())?;

    // 在所有 release 中查找 `tauri-v*` 标签，取版本号最大的。
    let mut best: Option<(String, &serde_json::Value)> = None;
    for release in releases {
        let tag_raw = release["tag_name"].as_str().unwrap_or("").trim();
        if !tag_raw.to_lowercase().starts_with(TAURI_TAG_PREFIX) {
            continue;
        }
        // 去掉 `tauri-v` / `tauri-V` 前缀，提取纯版本号。
        let ver = tag_raw[TAURI_TAG_PREFIX.len()..].trim_start_matches('v').trim_start_matches('V');
        if ver.is_empty() {
            continue;
        }
        let is_newer_than_best = match &best {
            None => true,
            Some((bv, _)) => is_newer(ver, bv),
        };
        if is_newer_than_best {
            best = Some((ver.to_string(), release));
        }
    }

    let (latest_ver, release) = match best {
        Some(x) => x,
        None => return Err("尚未发布 Tauri 版本".to_string()),
    };

    if !is_newer(&latest_ver, current_version) {
        return Err("已是最新版本".to_string());
    }

    let notes = release["body"].as_str().unwrap_or("新版本已发布").to_string();

    // 找 .zip 资产 URL（Tauri 构建产物是 Mole-Tauri-macOS.zip）。
    let download_url = release["assets"]
        .as_array()
        .and_then(|assets| {
            assets.iter().find_map(|a| {
                let name = a["name"].as_str().unwrap_or("");
                if name.ends_with(".zip") {
                    a["browser_download_url"]
                        .as_str()
                        .map(|s| s.to_string())
                } else {
                    None
                }
            })
        })
        .or_else(|| {
            release["html_url"].as_str().map(|s| s.to_string())
        })
        .ok_or_else(|| "未找到下载包".to_string())?;

    Ok(UpdateInfo {
        version: latest_ver,
        download_url,
        notes,
    })
}

/// 下载并安装更新。
///
/// 对于 Tauri 应用，这里通过 `open` 命令在浏览器中打开下载页面，
/// 让用户手动下载安装。后续可集成 Tauri updater 插件实现自动更新。
pub fn download_and_install(url: &str) -> Result<String, String> {
    // 测试模式：跳过实际操作。
    if std::env::var("MOLE_TEST_NO_AUTH").unwrap_or_default() == "1" {
        return Ok("测试模式：更新已跳过".to_string());
    }

    // 在默认浏览器中打开下载 URL。
    let _ = Command::new("open")
        .arg(url)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();

    Ok("已在浏览器中打开下载页面，请手动下载安装".to_string())
}

/// 语义版本比较：`lhs` 是否比 `rhs` 新。
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

/// 解析版本字符串为 (major, minor, patch)。
fn parse_version(s: &str) -> (i64, i64, i64) {
    let mut cleaned = s.trim().trim_start_matches('v').trim_start_matches('V');
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
        assert_eq!(parse_version("0.3.0"), (0, 3, 0));
    }

    #[test]
    fn parse_version_v_prefix() {
        assert_eq!(parse_version("v0.3.0"), (0, 3, 0));
    }

    #[test]
    fn parse_version_prerelease() {
        assert_eq!(parse_version("0.4.0-beta"), (0, 4, 0));
    }

    #[test]
    fn is_newer_minor() {
        assert!(is_newer("0.4.0", "0.3.0"));
        assert!(!is_newer("0.3.0", "0.4.0"));
    }

    #[test]
    fn is_newer_patch() {
        assert!(is_newer("0.3.1", "0.3.0"));
        assert!(!is_newer("0.3.0", "0.3.1"));
    }

    #[test]
    fn is_newer_equal() {
        assert!(!is_newer("0.3.0", "0.3.0"));
    }

    #[test]
    fn repo_is_mole_swift() {
        assert_eq!(REPO, "meiyx7/Mole-Swift");
    }

    #[test]
    fn tauri_tag_prefix_correct() {
        assert_eq!(TAURI_TAG_PREFIX, "tauri-v");
    }

    #[test]
    fn releases_url_correct() {
        assert!(releases_url().contains("/meiyx7/Mole-Swift/releases"));
    }
}
