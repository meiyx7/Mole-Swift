import Foundation

/// 基于 CLI 的项目产物扫描器。
///
/// 调用 `mo purge --dry-run` 在非交互模式下运行（CLI 检测到 `! [[ -t 0 ]]`
/// 时自动全选非近期项，跳过 TUI），解析其 `✓ [DRY RUN] <path>, <size>` 输出。
///
/// 这是对 `PurgeScanner`（本地 Swift 复刻）的替代方案，消除 34 个 target /
/// 9 个搜索路径的手动同步负担。CLI 一改 GUI 自动跟进。
///
/// 失败时（CLI 不可用 / 解析失败 / 超时）降级到 `PurgeScanner.scan()`。
enum CLIPurgeScanner {

    struct FoundArtifact: Identifiable, Hashable {
        let url: URL
        var sizeBytes: Int64
        let artifactType: String
        let projectName: String
        /// CLI 在 dry-run 输出中不提供 age 信息，统一为 0。
        /// 近期项的判断由 CLI 在选择阶段处理（默认不选近期项）。
        let ageDays: Int
        let isRecent: Bool

        var id: String { url.path }
        var sizeText: String { ByteFormatter.bytes(sizeBytes) }
        var displayName: String { url.lastPathComponent }
        var ageLabel: String {
            if ageDays < 1 { return "<1d" }
            if ageDays < 30 { return "\(ageDays)d" }
            if ageDays < 365 { return "\(ageDays / 30)mo" }
            return "\(ageDays / 365)y"
        }

        /// 转换为 PurgeScanner.FoundArtifact，便于复用 PurgeDeleter。
        func asPurgeArtifact() -> PurgeScanner.FoundArtifact {
            return PurgeScanner.FoundArtifact(
                url: url,
                sizeBytes: sizeBytes,
                artifactType: artifactType,
                projectName: projectName,
                ageDays: ageDays,
                isRecent: isRecent
            )
        }
    }

    /// 扫描结果。
    struct ScanResult {
        let artifacts: [FoundArtifact]
        /// 总可回收空间（来自 CLI 的 "Would free: X" 行）。
        let totalSpaceText: String?
        /// 总项数（来自 CLI 的 "Items: N" 行）。
        let totalItems: Int?
        /// 是否降级到本地扫描。
        let usedFallback: Bool
        /// 降级或失败原因（仅 usedFallback=true 时有意义）。
        let fallbackReason: String?
    }

    /// 运行 `mo purge --dry-run` 并解析输出。
    ///
    /// - Parameter fallback: 当 CLI 不可用或解析失败时是否降级到本地扫描。
    ///   默认为 true。若设为 false，失败时返回空结果。
    static func scan(useFallback: Bool = true) async -> ScanResult {
        guard CLILocator.isAvailable else {
            return fallbackResult(reason: "CLI not installed", useFallback: useFallback)
        }

        var options = CLIOptions()
        options.dryRun = true
        options.nonInteractive = true
        options.timeout = 120 // 2 分钟超时，覆盖大型项目集

        do {
            let result = try await CLIBridge.run(["purge", "--dry-run"], options: options)
            let parsed = parseOutput(result.stdout)
            if parsed.artifacts.isEmpty && result.exitCode != 0 {
                return fallbackResult(reason: "CLI exit \(result.exitCode)", useFallback: useFallback)
            }
            return ScanResult(
                artifacts: parsed.artifacts,
                totalSpaceText: parsed.totalSpaceText,
                totalItems: parsed.totalItems,
                usedFallback: false,
                fallbackReason: nil
            )
        } catch {
            return fallbackResult(reason: error.localizedDescription, useFallback: useFallback)
        }
    }

    // MARK: - Output parsing

    /// 解析 `mo purge --dry-run` 的 stdout。
    /// 输出格式（ANSI 已由 CLIBridge.ANSIStripper 处理）：
    /// ```
    /// ━━━ Purge Project Artifacts ━━━
    /// ✓ [DRY RUN] ~/Code/foo/node_modules, 92.2MB
    /// ✓ [DRY RUN] ~/Code/bar/build, 418KB
    /// ...
    /// Dry run complete - no changes made
    /// Would free: 92.6MB | Items: 2 | Free: ...
    /// ```
    private static func parseOutput(_ raw: String) -> (artifacts: [FoundArtifact], totalSpaceText: String?, totalItems: Int?) {
        var artifacts: [FoundArtifact] = []
        var totalSpace: String?
        var totalItems: Int?

        let lines = raw.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // `✓ [DRY RUN] <path>, <size>`
            if trimmed.hasPrefix("✓ [DRY RUN]") {
                let body = trimmed.replacingOccurrences(of: "✓ [DRY RUN]", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if let artifact = parseArtifactLine(body) {
                    artifacts.append(artifact)
                }
                continue
            }

            // `Would free: 92.6MB | Items: 2 | Free: ...`
            if trimmed.hasPrefix("Would free:") || trimmed.hasPrefix("Space freed:") {
                let parts = trimmed.components(separatedBy: "|")
                for part in parts {
                    let p = part.trimmingCharacters(in: .whitespaces)
                    if p.hasPrefix("Would free:") {
                        totalSpace = p.replacingOccurrences(of: "Would free:", with: "")
                            .trimmingCharacters(in: .whitespaces)
                    } else if p.hasPrefix("Space freed:") {
                        totalSpace = p.replacingOccurrences(of: "Space freed:", with: "")
                            .trimmingCharacters(in: .whitespaces)
                    } else if p.hasPrefix("Items:") {
                        let n = p.replacingOccurrences(of: "Items:", with: "")
                            .trimmingCharacters(in: .whitespaces)
                        totalItems = Int(n)
                    }
                }
                continue
            }
        }

        // 按大小降序，与 PurgeScanner 一致
        let sorted = artifacts.sorted { $0.sizeBytes > $1.sizeBytes }
        return (sorted, totalSpace, totalItems)
    }

    /// 解析单行 `<path>, <size>`。
    /// path 可能是 `~/Code/foo/node_modules` 形式（CLI 的 format_purge_target_path 输出）。
    private static func parseArtifactLine(_ body: String) -> FoundArtifact? {
        // 切分末尾的 `, <size>`
        guard let commaRange = body.range(of: ", ", options: .backwards) else {
            return nil
        }
        let pathStr = body[..<commaRange.lowerBound].trimmingCharacters(in: .whitespaces)
        let sizeStr = body[commaRange.upperBound...].trimmingCharacters(in: .whitespaces)

        guard isSizeText(sizeStr) else { return nil }

        // 展开 ~ 为 home 目录
        let expanded = expandTilde(pathStr)
        let url = URL(fileURLWithPath: expanded)

        // 从路径推断 artifactType（basename）和 projectName（父目录 basename）
        let artifactType = url.lastPathComponent
        let projectName = url.deletingLastPathComponent().lastPathComponent

        let sizeBytes = parseSizeToBytes(sizeStr) ?? 0

        return FoundArtifact(
            url: url,
            sizeBytes: sizeBytes,
            artifactType: artifactType,
            projectName: projectName,
            ageDays: 0, // CLI dry-run 不输出 age
            isRecent: false
        )
    }

    // MARK: - Helpers

    private static func expandTilde(_ path: String) -> String {
        if path.hasPrefix("~/") {
            return NSHomeDirectory() + String(path.dropFirst(1))
        }
        if path == "~" {
            return NSHomeDirectory()
        }
        return path
    }

    private static func isSizeText(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let pattern = "^[0-9]+(\\.[0-9]+)?(B|KB|MB|GB|TB|PB)$"
        return trimmed.range(of: pattern, options: .regularExpression) != nil
    }

    private static func parseSizeToBytes(_ s: String) -> Int64? {
        let trimmed = s.trimmingCharacters(in: .whitespaces).uppercased()
        let patterns: [(String, Double)] = [
            ("KB", 1024), ("MB", 1024 * 1024), ("GB", 1024 * 1024 * 1024),
            ("TB", 1024 * 1024 * 1024 * 1024), ("B", 1)
        ]
        for (suffix, mult) in patterns {
            if trimmed.hasSuffix(suffix) {
                let numStr = trimmed.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
                if let n = Double(numStr) { return Int64(n * mult) }
            }
        }
        return nil
    }

    private static func fallbackResult(reason: String, useFallback: Bool) -> ScanResult {
        if useFallback {
            // 降级到本地扫描
            let local = PurgeScanner.scan()
            let artifacts = local.map {
                FoundArtifact(
                    url: $0.url,
                    sizeBytes: $0.sizeBytes,
                    artifactType: $0.artifactType,
                    projectName: $0.projectName,
                    ageDays: $0.ageDays,
                    isRecent: $0.isRecent
                )
            }
            return ScanResult(
                artifacts: artifacts,
                totalSpaceText: nil,
                totalItems: artifacts.count,
                usedFallback: true,
                fallbackReason: reason
            )
        }
        return ScanResult(
            artifacts: [],
            totalSpaceText: nil,
            totalItems: 0,
            usedFallback: true,
            fallbackReason: reason
        )
    }
}
