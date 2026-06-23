//! Tauri 应用更新检查器与自动安装器。
//!
//! 检查 `meiyx7/Mole-Swift` 仓库中 `tauri-v*` 标签的 GitHub release，
//! 判断 Tauri 应用本身是否有新版本。
//!
//! `download_and_install` 在应用内完成下载、解压、替换、重启，不打开浏览器。
//!
//! 与 Mac app 的 `v*` 标签和 CLI 的 `V*` 标签区分：
//! - `tauri-v0.3.0` — Tauri 应用发布标签（本模块检测的目标）
//! - `v1.7.14` — Mac app 发布标签
//! - `V1.38.0` — CLI 发布标签

use crate::logger;
use crate::models::UpdateInfo;
use std::fs;
use std::path::PathBuf;
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
    logger::log(logger::LogLevel::Info, &format!("检查更新，当前版本: {}", current_version));

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
        .map_err(|e| {
            let msg = format!("无法启动 curl: {}", e);
            logger::log(logger::LogLevel::Error, &msg);
            msg
        })?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        let msg = format!("GitHub API 请求失败: {}", stderr.trim());
        logger::log(logger::LogLevel::Error, &msg);
        return Err(msg);
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
        logger::log(logger::LogLevel::Info, "已是最新版本");
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

    logger::log(logger::LogLevel::Info, &format!("发现新版本: {} -> {}", current_version, latest_ver));

    Ok(UpdateInfo {
        version: latest_ver,
        download_url,
        notes,
    })
}

/// 下载并安装更新（应用内自动更新，不打开浏览器）。
///
/// 流程：
/// 1. 用 curl 下载 zip 到临时目录
/// 2. 用 ditto 解压
/// 3. 关闭当前应用，用新版本替换 /Applications/Mole.app
/// 4. 重新启动应用
///
/// 替换策略：先移除旧的 .app，再把新的移过去。如果 /Applications/Mole.app
/// 不存在（用户可能从其他位置运行），则尝试替换当前可执行文件所在的应用包。
pub fn download_and_install(url: &str) -> Result<String, String> {
    // 测试模式：跳过实际操作。
    if std::env::var("MOLE_TEST_NO_AUTH").unwrap_or_default() == "1" {
        return Ok("测试模式：更新已跳过".to_string());
    }

    logger::log(logger::LogLevel::Info, &format!("开始下载更新: {}", url));

    // 1. 确定临时下载路径
    let tmp_dir = std::env::temp_dir().join("mole-tauri-update");
    let _ = fs::remove_dir_all(&tmp_dir);
    fs::create_dir_all(&tmp_dir)
        .map_err(|e| format!("无法创建临时目录: {}", e))?;

    let zip_path = tmp_dir.join("Mole-Tauri-macOS.zip");

    // 2. 用 curl 下载 zip
    let download_result = Command::new("curl")
        .args([
            "-L",           // 跟随重定向
            "-s",
            "--show-error",
            "-o",
            zip_path.to_str().unwrap_or(""),
            url,
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output();

    let output = download_result.map_err(|e| {
        let msg = format!("无法启动 curl 下载: {}", e);
        logger::log(logger::LogLevel::Error, &msg);
        msg
    })?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        let msg = format!("下载失败: {}", stderr.trim());
        logger::log(logger::LogLevel::Error, &msg);
        return Err(msg);
    }

    // 验证下载文件非空
    let zip_meta = fs::metadata(&zip_path)
        .map_err(|e| format!("下载文件不存在: {}", e))?;
    if zip_meta.len() < 1000 {
        let msg = format!("下载文件过小 ({} bytes)，可能下载失败", zip_meta.len());
        logger::log(logger::LogLevel::Error, &msg);
        return Err(msg);
    }

    logger::log(
        logger::LogLevel::Info,
        &format!("下载完成，大小: {} bytes", zip_meta.len()),
    );

    // 3. 解压 zip（用 ditto，保持 macOS 权限和元数据）
    let unzip_result = Command::new("ditto")
        .args([
            "-x",
            "-k",
            zip_path.to_str().unwrap_or(""),
            tmp_dir.to_str().unwrap_or(""),
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output();

    let output = unzip_result.map_err(|e| {
        let msg = format!("无法启动 ditto 解压: {}", e);
        logger::log(logger::LogLevel::Error, &msg);
        msg
    })?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        let msg = format!("解压失败: {}", stderr.trim());
        logger::log(logger::LogLevel::Error, &msg);
        return Err(msg);
    }

    // 4. 找到解压出的 Mole.app
    let new_app = tmp_dir.join("Mole.app");
    if !new_app.is_dir() {
        // 可能在子目录中
        let alt = tmp_dir.join("Mole").join("Mole.app");
        if alt.is_dir() {
            return install_app(&alt);
        }
        let msg = "解压后未找到 Mole.app";
        logger::log(logger::LogLevel::Error, msg);
        return Err(msg.to_string());
    }

    install_app(&new_app)
}

/// 用新的 .app 替换已安装的应用，然后重启。
fn install_app(new_app: &PathBuf) -> Result<String, String> {
    // 确定目标安装路径
    let home = std::env::var("HOME").unwrap_or_default();
    let target = PathBuf::from(format!("{}/Applications/Mole.app", home));

    // 如果 /Applications/Mole.app 存在，优先用它
    let global_target = PathBuf::from("/Applications/Mole.app");
    let install_target = if global_target.is_dir() {
        global_target
    } else if target.is_dir() {
        target
    } else {
        // 都不存在，安装到 ~/Applications
        target
    };

    logger::log(
        logger::LogLevel::Info,
        &format!("安装到: {}", install_target.display()),
    );

    // 5. 移除旧应用（移到 Trash 而非直接删除，保持可恢复性）
    if install_target.is_dir() {
        let trash_result = Command::new("trash")
            .arg(install_target.to_str().unwrap_or(""))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .output();

        match trash_result {
            Ok(o) if o.status.success() => {
                logger::log(logger::LogLevel::Info, "旧应用已移到 Trash");
            }
            _ => {
                // trash 命令可能不存在，回退到 rm -rf
                let rm_result = Command::new("rm")
                    .args(["-rf", install_target.to_str().unwrap_or("")])
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::piped())
                    .output();

                match rm_result {
                    Ok(o) if o.status.success() => {
                        logger::log(logger::LogLevel::Info, "旧应用已删除");
                    }
                    _ => {
                        let msg = format!("无法移除旧应用: {}", install_target.display());
                        logger::log(logger::LogLevel::Error, &msg);
                        return Err(msg);
                    }
                }
            }
        }
    }

    // 确保父目录存在
    if let Some(parent) = install_target.parent() {
        let _ = fs::create_dir_all(parent);
    }

    // 6. 移动新应用到目标位置
    let mv_result = Command::new("mv")
        .arg(new_app.to_str().unwrap_or(""))
        .arg(install_target.to_str().unwrap_or(""))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output();

    match mv_result {
        Ok(o) if o.status.success() => {
            logger::log(logger::LogLevel::Info, "新应用已安装");
        }
        _ => {
            let msg = format!("无法移动新应用到: {}", install_target.display());
            logger::log(logger::LogLevel::Error, &msg);
            return Err(msg);
        }
    }

    // 7. 清理临时目录
    let tmp_dir = std::env::temp_dir().join("mole-tauri-update");
    let _ = fs::remove_dir_all(&tmp_dir);

    // 8. 启动新应用并退出当前进程
    //    用 `nohup open` 确保新进程不依赖当前进程，避免 exit 后 open 也被杀掉。
    logger::log(logger::LogLevel::Info, "启动新应用并退出");

    // 先用 `open` 启动新应用（macOS 会通过 LaunchServices 管理生命周期）
    let _ = Command::new("open")
        .arg("-n")  // -n 表示启动新实例，即使已有实例运行
        .arg(install_target.to_str().unwrap_or(""))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();

    // 等待 open 命令完成（让 LaunchServices 注册新应用）
    std::thread::sleep(std::time::Duration::from_millis(800));

    // 退出当前进程
    std::process::exit(0);
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
