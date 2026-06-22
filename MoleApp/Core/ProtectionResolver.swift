import Foundation

/// 单一来源的路径保护解析器。
///
/// GUI 自研删除路径（`AnalyzeDeleter` / `PurgeDeleter`）原本各自维护
/// 保护路径列表，与 CLI 的 `should_protect_path` 7 步检查不共享代码，
/// 导致 CLI 更新 `SYSTEM_CRITICAL_BUNDLES` / `DATA_PROTECTED_BUNDLES`
/// 后 GUI 不会自动跟进。
///
/// 本解析器在启动时读取 CLI 的 `lib/core/app_protection_data.sh`，
/// 解析其中的 shell 数组，让 GUI 与 CLI 共享同一份保护列表。
/// 解析失败时降级到内置 fallback 列表（与历史行为一致），保证健壮性。
///
/// 设计要点：
/// - 只读取纯数据文件 `app_protection_data.sh`，不执行任何 shell 逻辑
/// - 数组元素支持通配符（如 `com.apple.*`），按 glob 匹配
/// - 缓存解析结果，避免每次删除都重新读文件
/// - CLI 升级后下次启动自动跟进新列表
enum ProtectionResolver {

    /// 解析后的保护条目。`bundlePattern` 是原始 shell 数组元素，
    /// 可能含 `*` 通配符；`nameFragments` 是按 `,` 切分的名称片段。
    struct ProtectedEntry: Hashable {
        let bundlePattern: String
        let nameFragments: [String]
    }

    /// 缓存的解析结果。`nil` 表示尚未解析。
    private static var cachedCritical: [String]?
    private static var cachedDataProtected: [ProtectedEntry]?
    private static let cacheLock = NSLock()

    // MARK: - Public API

    /// 系统关键 bundle 列表（来自 `SYSTEM_CRITICAL_BUNDLES`）。
    /// 匹配时这些 bundle 永远不可删除/卸载。
    static func systemCriticalBundles() -> [String] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cachedCritical { return cached }
        let resolved = resolveDataFile().map { parseShellArray($0, name: "SYSTEM_CRITICAL_BUNDLES") } ?? []
        let result = resolved.isEmpty ? fallbackSystemCritical : resolved
        cachedCritical = result
        return result
    }

    /// 数据保护 bundle 列表（来自 `DATA_PROTECTED_BUNDLES`）。
    /// 这些 bundle 在清理时受保护，但允许卸载。
    static func dataProtectedBundles() -> [ProtectedEntry] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cachedDataProtected { return cached }
        let raw = resolveDataFile().map { parseShellArray($0, name: "DATA_PROTECTED_BUNDLES") } ?? []
        let entries: [ProtectedEntry]
        if raw.isEmpty {
            entries = fallbackDataProtected.map {
                ProtectedEntry(bundlePattern: $0, nameFragments: fragments(of: $0))
            }
        } else {
            entries = raw.map {
                ProtectedEntry(bundlePattern: $0, nameFragments: fragments(of: $0))
            }
        }
        cachedDataProtected = entries
        return entries
    }

    /// 判断路径是否命中保护列表。
    ///
    /// - Parameter path: 待删除的绝对路径
    /// - Parameter bundleID: 可选的 bundle identifier（用于 bundle 模式匹配）
    /// - Returns: 命中则返回原因，未命中返回 nil
    static func protectedReason(path: String, bundleID: String?) -> String? {
        // 1. 路径本身的 basename 与保护模式做 glob 匹配
        let basename = (path as NSString).lastPathComponent
        let stem = basenameStem(basename)

        for pattern in systemCriticalBundles() {
            if matchesGlob(stem, pattern: pattern) { return "system critical: \(pattern)" }
            if matchesGlob(basename, pattern: pattern) { return "system critical: \(pattern)" }
        }
        for entry in dataProtectedBundles() {
            if matchesGlob(stem, pattern: entry.bundlePattern) { return "data protected: \(entry.bundlePattern)" }
            if matchesGlob(basename, pattern: entry.bundlePattern) { return "data protected: \(entry.bundlePattern)" }
            // 名称片段匹配（如 "Cursor" / "Claude" 等非 bundle-id 形式）
            for frag in entry.nameFragments where !frag.isEmpty {
                if basename == frag { return "data protected: \(frag)" }
            }
        }

        // 2. bundleID 匹配（如果有）
        if let bid = bundleID, !bid.isEmpty {
            for pattern in systemCriticalBundles() {
                if matchesGlob(bid, pattern: pattern) { return "system critical bundle: \(pattern)" }
            }
            for entry in dataProtectedBundles() {
                if matchesGlob(bid, pattern: entry.bundlePattern) { return "data protected bundle: \(entry.bundlePattern)" }
            }
        }

        return nil
    }

    /// 强制重新解析（用于 CLI 升级后的热刷新场景）。
    static func invalidateCache() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cachedCritical = nil
        cachedDataProtected = nil
    }

    // MARK: - Data file resolution

    /// 定位 CLI 的 `app_protection_data.sh`。
    /// 优先在 CLI 安装路径的 `lib/core/` 子目录查找，找不到则返回 nil。
    private static func resolveDataFile() -> String? {
        guard let moPath = CLILocator.resolve() else { return nil }

        // mo 通常是 symlink 或 wrapper，解析到真实安装目录
        let realPath: String
        if let resolved = try? FileManager.default.destinationOfSymbolicLink(atPath: moPath) {
            realPath = resolved
        } else {
            realPath = moPath
        }

        // 真实路径形如 /opt/homebrew/Cellar/mole/1.43.1/bin/mole 或 /Users/.../mole/bin/mole
        // lib/core/app_protection_data.sh 相对于 bin/ 的上级
        let candidates: [String] = [
            // bin/mole → ../lib/core/app_protection_data.sh
            URL(fileURLWithPath: realPath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("lib/core/app_protection_data.sh").path,
            // 如果 mo 是 wrapper 指向 mole 仓库根
            URL(fileURLWithPath: realPath)
                .deletingLastPathComponent()
                .appendingPathComponent("lib/core/app_protection_data.sh").path,
        ]

        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate) {
                return try? String(contentsOfFile: candidate, encoding: .utf8)
            }
        }
        return nil
    }

    /// 从 shell 源码中提取指定 `readonly ARRAY=(...)` 的内容。
    /// 支持多行数组、注释行（`#` 开头）、双引号包裹的元素。
    private static func parseShellArray(_ source: String, name: String) -> [String] {
        var elements: [String] = []
        var inArray = false
        var depth = 0

        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)

            if !inArray {
                // 查找 `readonly NAME=(` 开始
                if line.contains("readonly \(name)=(") || line.contains("\(name)=(") {
                    inArray = true
                    depth = 1
                    // 同行可能有元素
                    if let openIdx = line.firstIndex(of: "(") {
                        let after = String(line[line.index(after: openIdx)...])
                        extractElements(from: after, into: &elements)
                        // 如果同行以 ) 结束
                        if after.contains(")") { inArray = false }
                    }
                    continue
                }
                continue
            }

            // 在数组内部
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { continue }
            if trimmed.isEmpty { continue }

            extractElements(from: line, into: &elements)

            if line.contains(")") {
                inArray = false
            }
        }

        return elements
    }

    /// 从一行文本中提取双引号包裹的元素。
    private static func extractElements(from line: String, into elements: inout [String]) {
        var s = line
        while let openIdx = s.firstIndex(of: "\"") {
            let rest = s[s.index(after: openIdx)...]
            guard let closeIdx = rest.firstIndex(of: "\"") else { break }
            let element = String(rest[..<closeIdx])
            if !element.isEmpty {
                elements.append(element)
            }
            s = String(rest[s.index(after: closeIdx)...])
        }
    }

    // MARK: - Glob matching

    /// 简单 glob 匹配：支持 `*` 通配符。
    /// `com.apple.*` 匹配 `com.apple.finder`；`com.apple.Settings*` 匹配 `com.apple.Settings`。
    private static func matchesGlob(_ s: String, pattern: String) -> Bool {
        // 把 shell glob 转成简单的字符匹配
        // `*` → 任意字符序列
        // 其他字符按字面匹配
        var si = s.startIndex
        var pi = pattern.startIndex
        var starSi: String.Index?
        var starPi: String.Index?

        while si < s.endIndex {
            if pi < pattern.endIndex {
                let pc = pattern[pi]
                if pc == "*" {
                    starPi = pi
                    starSi = si
                    pi = pattern.index(after: pi)
                    continue
                }
                if pc == s[si] {
                    si = s.index(after: si)
                    pi = pattern.index(after: pi)
                    continue
                }
            }
            // mismatch
            if let sp = starPi, let ss = starSi {
                pi = pattern.index(after: sp)
                si = s.index(after: ss)
                starSi = si
                continue
            }
            return false
        }
        // 消耗 pattern 末尾的 *
        while pi < pattern.endIndex, pattern[pi] == "*" {
            pi = pattern.index(after: pi)
        }
        return pi == pattern.endIndex
    }

    /// 从 basename 提取 stem（去掉 `.app` / `.bundle` 等后缀）。
    private static func basenameStem(_ basename: String) -> String {
        for suffix in [".app", ".bundle", ".pkg", ".mpkg"] {
            if basename.hasSuffix(suffix) {
                return String(basename.dropLast(suffix.count))
            }
        }
        return basename
    }

    /// 从 `vendor|bundle-prefixes|name-fragments` 形态的条目中提取名称片段。
    /// 普通 bundle pattern 返回空数组。
    private static func fragments(of pattern: String) -> [String] {
        // OFFICIAL_UNINSTALLER_RULES 形如 "ESET|com.eset.|..."
        // DATA_PROTECTED_BUNDLES 大多是单元素，少数是裸名称如 "Cursor"
        if pattern.contains("|") {
            let parts = pattern.split(separator: "|", omittingEmptySubsequences: true)
            // 第三段是 name-fragments
            if parts.count >= 3 {
                return parts[2].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            }
        }
        // 不含 `.` 且不含 `*` 的纯名称（如 "Cursor" / "Claude"）作为单片段
        if !pattern.contains(".") && !pattern.contains("*") && !pattern.isEmpty {
            return [pattern]
        }
        return []
    }

    // MARK: - Fallback lists

    /// CLI 数据文件不可读时的 fallback。仅含最关键的几项，
    /// 避免在 CLI 升级或路径异常时完全失去保护。
    private static let fallbackSystemCritical: [String] = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.Safari",
        "com.apple.mail",
        "com.apple.systempreferences",
        "com.apple.SystemSettings",
        "com.apple.loginwindow",
        "com.apple.Notes",
        "com.apple.Photos",
        "com.apple.AppStore",
        "com.apple.Terminal",
        "loginwindow",
        "dock",
        "finder",
    ]

    private static let fallbackDataProtected: [String] = [
        "com.1password.*",
        "com.jetbrains.*",
        "com.microsoft.VSCode",
        "Cursor",
        "com.anthropic.claude*",
        "Claude",
        "com.openai.chat*",
        "ChatGPT",
        "com.docker.docker",
        "dev.orbstack.*",
        "com.tencent.xinWeChat",
        "com.tencent.qq",
    ]
}
