//! 原生 purge 扫描器。
//!
//! 镜像 `lib/clean/purge_shared.sh` 和 `lib/clean/project.sh` 的发现逻辑，
//! 与 `MoleApp/Core/PurgeScanner.swift` 保持一致。GUI 不能直接消费
//! `mo purge --dry-run`（CLI 的预览路径是 TTY 交互式菜单），所以这里
//! 复现发现规则，让 GUI 和 CLI 产生相同的扫描结果。
//!
//! 安全对齐：
//! - 同样的 artifact 目标集（`MOLE_PURGE_TARGETS`，33 项）。
//! - 同样的默认搜索路径（`MOLE_PURGE_DEFAULT_SEARCH_PATHS`，9 项）+
//!   用户配置文件 `~/.config/mole/purge_paths`。
//! - 同样的 `max_scan_depth = 6` 和项目容器检测
//!   （`MOLE_PURGE_PROJECT_INDICATORS` / `MOLE_PURGE_MONOREPO_INDICATORS`）。
//! - 同样的 `MIN_AGE_DAYS = 7` 近期修改保护：近期 artifact 仍列出但标记
//!   `is_recent = true`，前端默认不选中。
//! - 同样的 protected-artifact 规则：`bin` 仅在 .NET 上下文中清理，
//!   `vendor` 在 Go 源码上下文中保护，`DerivedData` 仅在项目目录内清理。

use crate::cli;
use crate::models::{PurgeArtifact, PurgeScanResult};
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use walkdir::WalkDir;

/// artifact 目录名集合。必须与 `purge_shared.sh` 中的 `MOLE_PURGE_TARGETS`
/// 保持同步。
const ARTIFACT_PATTERNS: &[&str] = &[
    "node_modules",
    "target",        // Rust, Maven
    "build",         // Gradle, various
    "dist",          // JS builds
    "venv",          // Python
    ".venv",         // Python
    ".pytest_cache", // Python (pytest)
    ".mypy_cache",   // Python (mypy)
    ".tox",          // Python (tox virtualenvs)
    ".nox",          // Python (nox virtualenvs)
    ".ruff_cache",   // Python (ruff)
    ".gradle",       // Gradle local
    "__pycache__",   // Python
    ".next",         // Next.js
    ".nuxt",         // Nuxt.js
    ".output",       // Nuxt.js
    "vendor",        // PHP Composer (guarded; see is_protected_artifact)
    "bin",           // .NET build output (guarded; see is_protected_artifact)
    "obj",           // C# / Unity
    ".turbo",        // Turborepo cache
    ".parcel-cache", // Parcel bundler
    ".dart_tool",    // Flutter/Dart build cache
    ".zig-cache",    // Zig
    "zig-out",       // Zig
    ".angular",      // Angular
    ".svelte-kit",   // SvelteKit
    ".astro",        // Astro
    "coverage",      // Code coverage reports
    "DerivedData",   // Xcode (guarded; see is_protected_artifact)
    "Pods",          // CocoaPods
    ".cxx",          // React Native Android NDK build cache
    ".expo",         // Expo
    ".build",        // Swift Package Manager
];

/// 默认搜索路径（`~` 在扫描时展开）。必须与 `MOLE_PURGE_DEFAULT_SEARCH_PATHS`
/// 保持同步。
const DEFAULT_SEARCH_PATHS: &[&str] = &[
    "~/www",
    "~/dev",
    "~/Projects",
    "~/GitHub",
    "~/Code",
    "~/Workspace",
    "~/Repos",
    "~/Development",
    "~/Library/CloudStorage",
];

/// Monorepo 指示文件。存在任一即视为 monorepo 根，继续下钻 workspace 包。
const MONOREPO_INDICATORS: &[&str] = &[
    "lerna.json",
    "pnpm-workspace.yaml",
    "nx.json",
    "rush.json",
];

/// 项目指示文件。存在任一即视为项目根。
const PROJECT_INDICATORS: &[&str] = &[
    "package.json",
    "Cargo.toml",
    "go.mod",
    "pyproject.toml",
    "requirements.txt",
    "pom.xml",
    "build.gradle",
    "Gemfile",
    "composer.json",
    "pubspec.yaml",
    "Package.swift",
    "Makefile",
    "build.zig",
    "build.zig.zon",
    ".git",
];

/// 永远不是项目容器的目录名（镜像 `is_project_container()` 的 basename 跳过列表）。
const NON_PROJECT_DIRS: &[&str] = &[
    "Library",
    "Applications",
    "Movies",
    "Music",
    "Pictures",
    "Public",
];

/// 近期修改保护窗口（天）。镜像 `MIN_AGE_DAYS`。
const MIN_AGE_DAYS: i64 = 7;

/// 最大扫描深度（相对每个搜索根）。镜像 `PURGE_MAX_DEPTH_DEFAULT`。
const MAX_SCAN_DEPTH: usize = 6;

/// artifact 最小字节数，小于此值跳过以减少噪声。镜像 CLI 的 `size > 1024`。
const MIN_ARTIFACT_SIZE: i64 = 1024;

/// 扫描所有配置的项目目录，返回找到的 build artifact。
///
/// 搜索路径来自默认集合 + 用户配置文件 `~/.config/mole/purge_paths`
/// （每行一个路径，`#` 注释和空行忽略，`~` 展开）。
///
/// `extra_paths` 允许调用方附加额外搜索根（前端可让用户指定）。
pub fn scan(extra_paths: Option<&[String]>) -> PurgeScanResult {
    let home = cli::home_path();
    let home_str = home.to_string_lossy().to_string();

    let mut seen_roots: HashSet<String> = HashSet::new();
    let mut search_paths: Vec<String> = Vec::new();

    // 默认路径 + 用户配置 + 调用方附加路径，去重后扫描。
    let user_config = read_user_config_paths(&home_str);
    let extras: Vec<String> = extra_paths
        .map(|v| v.to_vec())
        .unwrap_or_default();

    for raw in DEFAULT_SEARCH_PATHS
        .iter()
        .map(|s| s.to_string())
        .chain(user_config.into_iter())
        .chain(extras.into_iter())
    {
        let expanded = expand_tilde(&raw, &home_str);
        if !Path::new(&expanded).is_dir() {
            continue;
        }
        let key = standardize_path(&expanded);
        if seen_roots.insert(key) {
            search_paths.push(expanded);
        }
    }

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0);

    let mut artifacts: Vec<PurgeArtifact> = Vec::new();

    for root_path in &search_paths {
        let root = PathBuf::from(root_path);
        // 只下钻看起来像项目容器的目录，避免扫描 Documents/Movies 等。
        if !is_project_container(&root, 0) {
            continue;
        }
        scan_directory(&root, 0, now, &mut artifacts);
    }

    // 去重：重叠的搜索根可能通过两条路径发现同一个 artifact。
    let mut seen: HashSet<String> = HashSet::new();
    artifacts.retain(|a| seen.insert(a.path.clone()));

    // 按大小降序，与 CLI 默认排序一致。
    artifacts.sort_by(|a, b| b.size.cmp(&a.size));

    let total_size = artifacts.iter().map(|a| a.size).sum();
    let total_count = artifacts.len() as i64;

    PurgeScanResult {
        artifacts,
        total_size,
        total_count,
        scan_paths: search_paths,
    }
}

/// 递归扫描目录，发现 artifact 即记录，否则继续下钻直到 `MAX_SCAN_DEPTH`。
fn scan_directory(dir: &Path, depth: usize, now: f64, results: &mut Vec<PurgeArtifact>) {
    if depth > MAX_SCAN_DEPTH {
        return;
    }

    let entries = match fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };

    for entry in entries.flatten() {
        let path = entry.path();
        // 跳过隐藏文件（与 Swift 实现的 `.skipsHiddenFiles` 一致）。
        let name = match path.file_name().and_then(|n| n.to_str()) {
            Some(n) => n.to_string(),
            None => continue,
        };
        if name.starts_with('.') && !is_artifact_pattern(&name) {
            // 隐藏目录除非本身是 artifact（如 .next、.gradle），否则跳过。
            continue;
        }

        let is_dir = match entry.file_type() {
            Ok(t) => t.is_dir(),
            Err(_) => continue,
        };
        if !is_dir {
            continue;
        }

        if is_artifact_pattern(&name) {
            if is_protected_artifact(&path, &name) {
                continue;
            }

            let size = directory_size(&path);
            if size < MIN_ARTIFACT_SIZE {
                continue;
            }

            let age_days = modification_age_days(&path, now).unwrap_or(0);
            let project_path = path
                .parent()
                .and_then(|p| p.file_name())
                .and_then(|n| n.to_str())
                .unwrap_or("")
                .to_string();

            results.push(PurgeArtifact {
                path: path.to_string_lossy().to_string(),
                size,
                artifact_type: name.clone(),
                project_path,
                age_days,
                is_recent: age_days < MIN_AGE_DAYS,
            });
        } else if depth < MAX_SCAN_DEPTH {
            // 继续下钻。这里不再 gate on is_project_container，因为 artifact
            // 可能嵌在非项目目录里（如 monorepo 的 packages/）。深度上限会
            // 防止失控遍历。
            scan_directory(&path, depth + 1, now, results);
        }
    }
}

/// 判断 `dir` 是否像项目容器：含 monorepo / project 指示文件，或其子目录
/// （最深 2 层）含指示文件。镜像 `is_project_container()`。
fn is_project_container(dir: &Path, depth: usize) -> bool {
    let basename = dir
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("");
    if basename.starts_with('.') {
        return false;
    }
    if NON_PROJECT_DIRS.contains(&basename) {
        return false;
    }

    // 直接检查指示文件。
    for name in MONOREPO_INDICATORS.iter().chain(PROJECT_INDICATORS.iter()) {
        if dir.join(name).exists() {
            return true;
        }
    }

    // 深一层检查（CLI 中 max_depth=2）。
    if depth >= 2 {
        return false;
    }
    let entries = match fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return false,
    };
    for entry in entries.flatten() {
        if entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
            if is_project_container(&entry.path(), depth + 1) {
                return true;
            }
        }
    }
    false
}

/// 镜像 `is_protected_purge_artifact()`。返回 true 表示该 artifact 应被保护。
fn is_protected_artifact(path: &Path, artifact_type: &str) -> bool {
    match artifact_type {
        "bin" => {
            // 仅在 .NET 上下文（兄弟 .csproj/.fsproj/.vbproj）中允许清理 bin/。
            !is_dotnet_bin_dir(path)
        }
        "vendor" => {
            // Go / vendor 源码目录受保护。
            is_protected_vendor_dir(path)
        }
        "DerivedData" => {
            // 全局 Xcode DerivedData 受保护；仅项目目录内的 DerivedData 可清理。
            path.to_string_lossy()
                .contains("/Library/Developer/Xcode/DerivedData")
        }
        _ => false,
    }
}

/// `bin/` 旁有 .csproj/.fsproj/.vbproj 时视为 .NET 构建产物。
fn is_dotnet_bin_dir(path: &Path) -> bool {
    let parent = match path.parent() {
        Some(p) => p,
        None => return false,
    };
    let entries = match fs::read_dir(parent) {
        Ok(e) => e,
        Err(_) => return false,
    };
    for entry in entries.flatten() {
        if let Some(name) = entry.file_name().to_str() {
            if name.ends_with(".csproj")
                || name.ends_with(".fsproj")
                || name.ends_with(".vbproj")
            {
                return true;
            }
        }
    }
    false
}

/// `vendor/` 含 Go 源码或 vendor.json/modules.txt 时视为受保护的源码目录。
fn is_protected_vendor_dir(path: &Path) -> bool {
    let entries = match fs::read_dir(path) {
        Ok(e) => e,
        Err(_) => return false,
    };
    for entry in entries.flatten() {
        if let Some(name) = entry.file_name().to_str() {
            if name.ends_with(".go") {
                return true;
            }
            if name == "vendor.json" || name == "modules.txt" {
                return true;
            }
        }
    }
    false
}

/// 计算目录树总字节数。镜像 `get_dir_size_kb` 但返回字节。
///
/// 用 `walkdir` 遍历，跳过符号链接（防止循环），累加文件大小。
fn directory_size(path: &Path) -> i64 {
    let mut total: i64 = 0;
    for entry in WalkDir::new(path)
        .follow_links(false)
        .into_iter()
        .filter_map(|e| e.ok())
    {
        if entry.file_type().is_file() {
            if let Ok(meta) = entry.metadata() {
                total += meta.len() as i64;
            }
        }
    }
    total
}

/// 返回 artifact 距上次修改的天数，无法读取时返回 None。
fn modification_age_days(path: &Path, now: f64) -> Option<i64> {
    let meta = fs::metadata(path).ok()?;
    let mtime = meta.modified().ok()?;
    let mtime_secs = mtime.duration_since(UNIX_EPOCH).ok()?.as_secs_f64();
    let interval = now - mtime_secs;
    Some((interval / 86400.0).max(0.0) as i64)
}

/// `name` 是否在 artifact 模式集合中。
fn is_artifact_pattern(name: &str) -> bool {
    ARTIFACT_PATTERNS.contains(&name)
}

/// 展开路径前缀 `~`。`~` 单独使用返回 home，`~/foo` 返回 `home/foo`。
fn expand_tilde(path: &str, home: &str) -> String {
    if path == "~" {
        return home.to_string();
    }
    if let Some(rest) = path.strip_prefix("~/") {
        return format!("{}/{}", home.trim_end_matches('/'), rest);
    }
    path.to_string()
}

/// 标准化路径用于去重：解析符号链接并小写化（HFS+/APFS 大小写不敏感）。
fn standardize_path(path: &str) -> String {
    let canonical = fs::canonicalize(path)
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|_| path.to_string());
    canonical.to_lowercase()
}

/// 读取用户 purge-paths 配置文件 `~/.config/mole/purge_paths`。
///
/// 每个非空、非注释行是一个搜索根；`~` 会展开。镜像
/// `mole_purge_read_paths_config`。
fn read_user_config_paths(home: &str) -> Vec<String> {
    let config_path = format!("{}/.config/mole/purge_paths", home);
    let content = match fs::read_to_string(&config_path) {
        Ok(c) => c,
        Err(_) => return Vec::new(),
    };
    let mut paths = Vec::new();
    for raw in content.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        paths.push(expand_tilde(line, home));
    }
    paths
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn artifact_patterns_count_matches_canonical() {
        // 与 purge_shared.sh 中的 MOLE_PURGE_TARGETS 保持同步。
        // 当前 canonical 集合有 33 项（注释说 34，实际数 33；保持与 shell 一致）。
        assert_eq!(ARTIFACT_PATTERNS.len(), 33);
    }

    #[test]
    fn default_search_paths_count() {
        assert_eq!(DEFAULT_SEARCH_PATHS.len(), 9);
    }

    #[test]
    fn expand_tilde_home() {
        assert_eq!(expand_tilde("~", "/Users/foo"), "/Users/foo");
    }

    #[test]
    fn expand_tilde_prefix() {
        assert_eq!(expand_tilde("~/Code", "/Users/foo"), "/Users/foo/Code");
    }

    #[test]
    fn expand_tilde_no_prefix() {
        assert_eq!(expand_tilde("/Users/foo/Code", "/Users/foo"), "/Users/foo/Code");
    }

    #[test]
    fn is_artifact_pattern_known() {
        assert!(is_artifact_pattern("node_modules"));
        assert!(is_artifact_pattern("target"));
        assert!(is_artifact_pattern(".next"));
        assert!(is_artifact_pattern("DerivedData"));
    }

    #[test]
    fn is_artifact_pattern_unknown() {
        assert!(!is_artifact_pattern("src"));
        assert!(!is_artifact_pattern("Documents"));
        assert!(!is_artifact_pattern("my-app"));
    }

    #[test]
    fn scan_returns_empty_for_nonexistent_root() {
        // 默认搜索路径在测试环境通常不存在，应返回空结果而非 panic。
        let result = scan(None);
        // 不断言具体数量，只确保不 panic 且字段一致。
        assert_eq!(result.total_count, result.artifacts.len() as i64);
        assert_eq!(result.total_size, result.artifacts.iter().map(|a| a.size).sum::<i64>());
    }
}
