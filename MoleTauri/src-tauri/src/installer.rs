//! 原生 installer 扫描器。
//!
//! 镜像 `bin/installer.sh` 的发现逻辑，与 `MoleApp/Core/InstallerScanner.swift`
//! 保持一致。CLI 的预览路径是交互式 TTY 菜单，GUI 无法直接消费
//! `mo installer --dry-run`，所以这里复现发现规则。
//!
//! 对齐 `bin/installer.sh`：
//! - 同样的 `INSTALLER_SCAN_PATHS`（12 项，含 Mail Downloads 和 Telegram Desktop）。
//! - 同样的 `is_installer_zip()` 过滤：`.zip` 仅在前 50 个条目含
//!   `.app/.pkg/.dmg/.xip` payload 时才列出。
//! - 同样不跳过隐藏文件（CLI 用 `fd --no-ignore --hidden` / `find` 不带
//!   `-not-path '.*'`）。
//! - 同样的 `get_source_display()` 来源标签。
//! - 同样的 Homebrew hash 前缀剥离（`^[0-9a-f]{64}--(.*)`）。
//! - 同样的 `INSTALLER_SCAN_MAX_DEPTH_DEFAULT=2`，可通过
//!   `MOLE_INSTALLER_SCAN_MAX_DEPTH` 覆盖。

use crate::cli;
use crate::models::{InstallerFile, InstallerScanResult};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// 默认最大扫描深度。镜像 `INSTALLER_SCAN_MAX_DEPTH_DEFAULT`。
const DEFAULT_MAX_DEPTH: usize = 2;

/// installer 扩展名（无条件接受，不检查内容）。镜像 `handle_candidate_file` 的 case 分支。
const INSTALLER_EXTENSIONS: &[&str] = &["dmg", "pkg", "mpkg", "iso", "xip"];

/// `.zip` 内部视为 installer payload 的扩展名。镜像 `is_installer_zip` 的 awk 模式。
const ZIP_PAYLOAD_EXTENSIONS: &[&str] = &["app", "pkg", "dmg", "xip"];

/// `.zip` 检查的最大条目数。镜像 `MAX_ZIP_ENTRIES`。
const MAX_ZIP_ENTRIES: usize = 50;

/// 扫描所有配置路径，返回找到的 installer 文件，按大小降序排序。
pub fn scan() -> InstallerScanResult {
    let home = cli::home_path();
    let home_str = home.to_string_lossy().to_string();
    let paths = scan_paths(&home_str);
    let max_depth = max_depth();

    let mut files: Vec<InstallerFile> = Vec::new();

    for root_path in &paths {
        let root = PathBuf::from(root_path);
        if !root.is_dir() {
            continue;
        }
        scan_directory(&root, 0, max_depth, &mut files);
    }

    // 按大小降序，与 CLI 默认排序一致。
    files.sort_by(|a, b| b.size.cmp(&a.size));

    let total_size = files.iter().map(|f| f.size).sum();
    let total_count = files.len() as i64;

    InstallerScanResult {
        files,
        total_size,
        total_count,
    }
}

/// 12 个扫描路径。`home` 已展开。镜像 `INSTALLER_SCAN_PATHS`。
fn scan_paths(home: &str) -> Vec<String> {
    vec![
        format!("{}/Downloads", home),
        format!("{}/Desktop", home),
        format!("{}/Documents", home),
        format!("{}/Public", home),
        format!("{}/Library/Downloads", home),
        "/Users/Shared".to_string(),
        "/Users/Shared/Downloads".to_string(),
        format!("{}/Library/Caches/Homebrew", home),
        format!("{}/Library/Mobile Documents/com~apple~CloudDocs/Downloads", home),
        format!("{}/Library/Containers/com.apple.mail/Data/Library/Mail Downloads", home),
        format!("{}/Library/Application Support/Telegram Desktop", home),
        format!("{}/Downloads/Telegram Desktop", home),
    ]
}

/// 读取 `MOLE_INSTALLER_SCAN_MAX_DEPTH` 环境变量，无效时返回默认值 2。
fn max_depth() -> usize {
    if let Ok(raw) = std::env::var("MOLE_INSTALLER_SCAN_MAX_DEPTH") {
        if let Ok(n) = raw.parse::<usize>() {
            if n > 0 {
                return n;
            }
        }
    }
    DEFAULT_MAX_DEPTH
}

/// 递归扫描目录。`depth` 超过 `max_depth` 时停止下钻。
///
/// 注意：不跳过隐藏文件，与 CLI 的 `fd --no-ignore --hidden` 行为一致。
fn scan_directory(dir: &Path, depth: usize, max_depth: usize, results: &mut Vec<InstallerFile>) {
    if depth > max_depth {
        return;
    }
    let entries = match fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };

    for entry in entries.flatten() {
        let path = entry.path();
        let file_type = match entry.file_type() {
            Ok(t) => t,
            Err(_) => continue,
        };

        if file_type.is_dir() {
            if depth < max_depth {
                scan_directory(&path, depth + 1, max_depth, results);
            }
        } else if file_type.is_file() {
            if let Some(file) = make_found_file(&path) {
                results.push(file);
            }
        }
        // 符号链接跳过（与 CLI 的 `[[ -L "$file" ]] && return 0` 一致）。
    }
}

/// 镜像 `handle_candidate_file()`：installer 扩展名无条件接受；`.zip` 仅在
/// `is_installer_zip` 返回 true 时接受。
fn make_found_file(path: &Path) -> Option<InstallerFile> {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|s| s.to_lowercase())
        .unwrap_or_default();

    if ext.is_empty() {
        return None;
    }
    let is_installer_ext = INSTALLER_EXTENSIONS.contains(&ext.as_str());
    let is_zip = ext == "zip";
    if !is_installer_ext && !is_zip {
        return None;
    }

    // 跳过符号链接（CLI `[[ -L "$file" ]] && return 0`）。
    if let Ok(meta) = fs::symlink_metadata(path) {
        if meta.file_type().is_symlink() {
            return None;
        }
    }

    let is_installer_zip = if is_zip {
        if !is_installer_zip(path) {
            return None;
        }
        true
    } else {
        false
    };

    let size = fs::metadata(path).map(|m| m.len() as i64).unwrap_or(0);
    let name = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("")
        .to_string();
    let source = source_name(path);
    let display_name = strip_homebrew_hash(&name, &source);

    Some(InstallerFile {
        path: path.to_string_lossy().to_string(),
        name: display_name,
        size,
        source,
        file_type: ext,
        is_installer_zip,
    })
}

/// 镜像 `is_installer_zip()`：检查 zip 前 `MAX_ZIP_ENTRIES` 个条目，含
/// `.app/.pkg/.dmg/.xip` 时返回 true。无法读取时返回 false（与 CLI 的
/// `2>/dev/null` 吞错一致）。
fn is_installer_zip(path: &Path) -> bool {
    if !is_readable(path) {
        return false;
    }

    // 用系统 `unzip -Z -1`（zipinfo 等价）。CLI 优先 `zipinfo -1`，回退
    // `unzip -Z -1`；我们直接用 `unzip -Z -1`，因为 macOS 上它总是存在。
    let output = Command::new("/usr/bin/unzip")
        .args(["-Z", "-1"])
        .arg(path)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output();
    let stdout = match output {
        Ok(o) => o.stdout,
        Err(_) => return false,
    };

    let listing = String::from_utf8_lossy(&stdout);
    for (i, line) in listing.lines().enumerate() {
        if i >= MAX_ZIP_ENTRIES {
            break;
        }
        let entry = line.to_lowercase();
        for payload_ext in ZIP_PAYLOAD_EXTENSIONS {
            let suffix = format!(".{}", payload_ext);
            // 匹配 awk 模式：条目以 .app/.pkg/.dmg/.xip 结尾，或后跟 `/`。
            if entry.ends_with(&suffix) || entry.contains(&format!("{}/", suffix)) {
                return true;
            }
        }
    }
    false
}

fn is_readable(path: &Path) -> bool {
    fs::File::open(path).is_ok()
}

/// 友好的来源标签，镜像 `get_source_display()`。顺序敏感：更具体的前缀优先
/// （如 Mail Downloads 在通用 Library 之前）。
fn source_name(path: &Path) -> String {
    let parent = match path.parent() {
        Some(p) => p,
        None => return String::new(),
    };
    let parent_str = parent.to_string_lossy();
    let home = cli::home_path();
    let home_str = home.to_string_lossy().to_string();

    if parent_str.starts_with(&format!("{}/Downloads", home_str)) {
        return "Downloads".to_string();
    }
    if parent_str.starts_with(&format!("{}/Desktop", home_str)) {
        return "Desktop".to_string();
    }
    if parent_str.starts_with(&format!("{}/Documents", home_str)) {
        return "Documents".to_string();
    }
    if parent_str.starts_with(&format!("{}/Public", home_str)) {
        return "Public".to_string();
    }
    if parent_str.starts_with(&format!("{}/Library/Downloads", home_str)) {
        return "Library".to_string();
    }
    if parent_str.starts_with("/Users/Shared") {
        return "Shared".to_string();
    }
    if parent_str.starts_with(&format!("{}/Library/Caches/Homebrew", home_str)) {
        return "Homebrew".to_string();
    }
    if parent_str.starts_with(&format!(
        "{}/Library/Mobile Documents/com~apple~CloudDocs/Downloads",
        home_str
    )) {
        return "iCloud".to_string();
    }
    if parent_str.starts_with(&format!("{}/Library/Containers/com.apple.mail", home_str)) {
        return "Mail".to_string();
    }
    if parent_str.contains("Telegram Desktop") {
        return "Telegram".to_string();
    }
    parent
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("")
        .to_string()
}

/// 在来源是 Homebrew 时剥离文件名前的 `sha256--` hash 前缀。镜像 CLI 的
/// 正则 `^[0-9a-f]{64}--(.*)`。非 Homebrew 文件名原样返回。
fn strip_homebrew_hash(filename: &str, source: &str) -> String {
    if source != "Homebrew" {
        return filename.to_string();
    }
    // 简单实现：检查前 64 个字符是否全是 hex，且后跟 `--`。
    if filename.len() < 67 {
        return filename.to_string();
    }
    let (hash_part, rest) = filename.split_at(64);
    if !rest.starts_with("--") {
        return filename.to_string();
    }
    if !hash_part.chars().all(|c| c.is_ascii_hexdigit()) {
        return filename.to_string();
    }
    rest[2..].to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scan_paths_count() {
        let paths = scan_paths("/Users/test");
        assert_eq!(paths.len(), 12);
    }

    #[test]
    fn scan_paths_expand_home() {
        let paths = scan_paths("/Users/test");
        assert!(paths[0].contains("/Users/test/Downloads"));
        assert_eq!(paths[5], "/Users/Shared");
    }

    #[test]
    fn max_depth_default() {
        std::env::remove_var("MOLE_INSTALLER_SCAN_MAX_DEPTH");
        assert_eq!(max_depth(), DEFAULT_MAX_DEPTH);
    }

    #[test]
    fn max_depth_override() {
        std::env::set_var("MOLE_INSTALLER_SCAN_MAX_DEPTH", "5");
        assert_eq!(max_depth(), 5);
        std::env::remove_var("MOLE_INSTALLER_SCAN_MAX_DEPTH");
    }

    #[test]
    fn max_depth_invalid_falls_back() {
        std::env::set_var("MOLE_INSTALLER_SCAN_MAX_DEPTH", "notanumber");
        assert_eq!(max_depth(), DEFAULT_MAX_DEPTH);
        std::env::remove_var("MOLE_INSTALLER_SCAN_MAX_DEPTH");
    }

    #[test]
    fn max_depth_zero_falls_back() {
        std::env::set_var("MOLE_INSTALLER_SCAN_MAX_DEPTH", "0");
        assert_eq!(max_depth(), DEFAULT_MAX_DEPTH);
        std::env::remove_var("MOLE_INSTALLER_SCAN_MAX_DEPTH");
    }

    #[test]
    fn strip_homebrew_hash_with_prefix() {
        let name = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef--firefox--123.pkg";
        assert_eq!(strip_homebrew_hash(name, "Homebrew"), "firefox--123.pkg");
    }

    #[test]
    fn strip_homebrew_hash_without_prefix() {
        let name = "firefox.pkg";
        assert_eq!(strip_homebrew_hash(name, "Homebrew"), "firefox.pkg");
    }

    #[test]
    fn strip_homebrew_hash_non_homebrew_unchanged() {
        let name = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef--foo.pkg";
        assert_eq!(strip_homebrew_hash(name, "Downloads"), name);
    }

    #[test]
    fn strip_homebrew_hash_short_name() {
        assert_eq!(strip_homebrew_hash("foo.pkg", "Homebrew"), "foo.pkg");
    }

    #[test]
    fn strip_homebrew_hash_non_hex_prefix() {
        // 前 64 字符不全为 hex，应原样返回。
        let name = "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz--foo.pkg";
        assert_eq!(strip_homebrew_hash(name, "Homebrew"), name);
    }

    #[test]
    fn source_name_downloads() {
        let path = Path::new("/Users/foo/Downloads/test.dmg");
        assert_eq!(source_name(path), "Downloads");
    }

    #[test]
    fn source_name_shared() {
        let path = Path::new("/Users/Shared/test.dmg");
        assert_eq!(source_name(path), "Shared");
    }

    #[test]
    fn source_name_telegram() {
        let path = Path::new("/Users/foo/Library/Application Support/Telegram Desktop/test.dmg");
        assert_eq!(source_name(path), "Telegram");
    }

    #[test]
    fn scan_returns_empty_when_no_paths_exist() {
        // 测试环境通常没有这些路径，应返回空结果而非 panic。
        let result = scan();
        assert_eq!(result.total_count, result.files.len() as i64);
    }
}
