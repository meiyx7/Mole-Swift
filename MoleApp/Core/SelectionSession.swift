import Foundation

/// 交互式选择流程（`mo purge`）的纯 reducer。
///
/// `reduce(state, event) -> (state, [effect])` 无 I/O、无时钟、无 SwiftUI：
/// 宿主（ObservableObject）持有 PTY 和定时器，把 PTY 字节和定时器脉冲
/// 作为事件喂进来，并执行返回的 effect（发送按键 / 退出）。
///
/// 三重安全校验（核心）：
/// 1. 发送切换键后，每 tick 重新解析屏幕，连续两次读取一致才算稳定；
///    然后校验屏幕上勾选行按 index、按 name、按行数都与用户选择一致。
/// 2. 跨视口时逐行滚动累积 checked 行的签名（name+size+location），
///    整体集合必须精确等于 wantedSigs。
/// 3. Mole 自己的确认屏计数（"Remove N"）必须等于用户选择数。
/// 任何一环不符 → q 退出，什么都不删。
enum SelectionSession {

    // MARK: - 状态

    enum Phase: Equatable {
        case scanning          // 等待 Mole 列表渲染
        case choosing          // 列表已出，等用户选择
        case loadingAll        // 滚动拉取超过视口上限的全部行
        case applyingViewport  // 已发切换键；单视口内稳定+校验
        case applyingFull      // 选择跨多视口；逐行滚动校验
        case awaitingConfirm   // 已进入；等待 Mole 的 "Remove N?" 屏
        case confirming        // 已发最终 Enter；收集 Mole 删除输出
        case done(Int32)
        case failed(String)
    }

    struct State: Equatable {
        var phase: Phase = .scanning
        var items: [MoTUIItem] = []
        var totalCount = 0
        var viewportCount = 0      // 第一帧的行数 — Mole 的视口上限

        // 内部终端缓冲，按阶段路由
        var screen = ""
        var confirmScreen = ""
        var result = ""
        var resultText = ""        // 面向用户的删除日志，退出时设置
        var listReady = false

        // 选择簿记（用户确认时设置）
        var wanted: Set<Int> = []
        var wantedSigs: Set<String> = []
        var wantedNames: Set<String> = []
        var expectedCount = 0
        var settleAttempt = 0
        var lastSelected: Set<Int>? = nil

        // "显示全部" 滚动捕获簿记
        var fullyLoaded = false
        var loadPressesLeft = 0

        // 滚动校验簿记（选择跨多视口）
        var verifyChecked: Set<String> = []
        var verifySeen: Set<String> = []
        var verifyPressesLeft = 0
    }

    /// 行身份签名 — 完整 name + size + location，避免同名条目混淆。
    static func sig(_ i: MoTUIItem) -> String { "\(i.name)\u{1}\(i.size)\u{1}\(i.location)" }

    enum Event {
        case output(String)            // 原始 PTY 字节
        case processExited(Int32)
        case showAllRequested
        case confirmRequested(Set<Int>)
        case tick                      // 逻辑时钟脉冲
    }

    enum Effect: Equatable {
        case send([UInt8])
        case terminate
    }

    // MARK: - Reducer

    static func reduce(_ state: State, _ event: Event) -> (State, [Effect]) {
        var s = state
        switch event {
        case .output(let text):
            return ingest(&s, text)
        case .processExited(let code):
            return exited(&s, code)
        case .confirmRequested(let wanted):
            return confirm(&s, wanted)
        case .showAllRequested:
            return showAll(&s)
        case .tick:
            return tick(&s)
        }
    }

    /// 开始滚动捕获视口上限之外的所有行。仅在列表已出且 Mole 报告的
    /// 总数大于可见行数时有效。
    private static func showAll(_ s: inout State) -> (State, [Effect]) {
        guard s.phase == .choosing, !s.fullyLoaded else { return (s, []) }
        guard s.totalCount > s.items.count else { s.fullyLoaded = true; return (s, []) }
        s.phase = .loadingAll
        s.loadPressesLeft = s.totalCount + 20
        return (s, [])
    }

    private static func confirm(_ s: inout State, _ wanted: Set<Int>) -> (State, [Effect]) {
        guard s.phase == .choosing, !wanted.isEmpty else { return (s, []) }
        s.wanted = wanted
        s.wantedSigs = Set(wanted.compactMap { s.items.indices.contains($0) ? sig(s.items[$0]) : nil })
        s.wantedNames = Set(wanted.compactMap { s.items.indices.contains($0) ? s.items[$0].name : nil })
        s.expectedCount = s.items.count
        let keys = MoTUI.keystrokesToSelect(wanted, count: s.items.count, confirm: false)
        if s.items.count > s.viewportCount {
            // 选择跨越多个视口。一帧无法显示全部，滚动整个列表并按身份
            // 校验勾选行。先把光标回顶，校验走查从上往下读。
            s.phase = .applyingFull
            s.verifyChecked = []
            s.verifySeen = []
            s.verifyPressesLeft = s.items.count + 20
            s.screen = ""
            let ups = Array(repeating: MoTUI.up, count: s.items.count + 5).flatMap { $0 }
            return (s, [.send(keys), .send(ups)])
        }
        s.phase = .applyingViewport
        s.settleAttempt = 0
        s.lastSelected = nil
        return (s, [.send(keys)])
    }

    // MARK: - Tick（稳定 / 校验 / 超时）

    private static func tick(_ s: inout State) -> (State, [Effect]) {
        switch s.phase {
        case .loadingAll:       return tickLoadingAll(&s)
        case .applyingViewport: return tickViewport(&s)
        case .applyingFull:     return tickFull(&s)
        case .awaitingConfirm:  return tickAwaitConfirm(&s)
        default:                return (s, [])
        }
    }

    /// 滚动校验跨多视口的选择：从顶到底逐行累积 CHECKED 行，仅当集合
    /// 精确等于用户选择（按身份）才继续。任何不符或超时 → 退出，不删。
    private static func tickFull(_ s: inout State) -> (State, [Effect]) {
        for it in MoTUI.parse(s.screen).items {
            let sg = sig(it)
            s.verifySeen.insert(sg)
            if it.selected { s.verifyChecked.insert(sg) }
        }
        if s.verifySeen.count >= s.items.count || s.verifyPressesLeft <= 0 {
            if s.verifyChecked == s.wantedSigs {
                s.phase = .awaitingConfirm
                s.confirmScreen = ""
                s.settleAttempt = 0
                return (s, [.send([0x0d])])
            }
            s.phase = .failed("无法安全校验完整选择（\(s.verifyChecked.count)/\(s.wantedSigs.count) 已确认）。未删除任何内容，请重试。")
            return (s, [.send(MoTUI.quit)])
        }
        s.verifyPressesLeft -= 1
        if s.screen.count > 80_000 { s.screen = String(s.screen.suffix(40_000)) }
        return (s, [.send(MoTUI.down)])
    }

    /// 每 tick 把光标下移一行，把重叠帧拼接成有序列表（按身份去重），
    /// 直到捕获报告的总数。然后回顶，让后续选择走查从第 0 行开始。
    private static func tickLoadingAll(_ s: inout State) -> (State, [Effect]) {
        let vp = MoTUI.parse(s.screen).items
        if !vp.isEmpty { s.items = MoTUI.mergeItems(s.items, vp) }
        if s.items.count >= s.totalCount || s.loadPressesLeft <= 0 {
            let ups = Array(repeating: MoTUI.up, count: s.items.count + 5).flatMap { $0 }
            s.fullyLoaded = true
            s.phase = .choosing
            return (s, [.send(ups)])
        }
        s.loadPressesLeft -= 1
        if s.screen.count > 80_000 { s.screen = String(s.screen.suffix(40_000)) }
        return (s, [.send(MoTUI.down)])
    }

    /// 第一个 Enter 后，Mole 显示第二个屏 — "Remove/Delete N…，Enter 确认，
    /// ESC 取消"。仅当屏幕显示取消提示且能解析出计数，且计数等于用户
    /// 选择数时才发最终 Enter。否则 ESC + 退出，不删。
    private static func tickAwaitConfirm(_ s: inout State) -> (State, [Effect]) {
        let maxAttempts = 75      // 约 4.5 秒等 Mole 到达确认屏
        let txt = ANSIStripper.strip(s.confirmScreen)
        if txt.localizedCaseInsensitiveContains("esc cancel"), let n = MoTUI.removalCount(txt) {
            if n == s.wanted.count {
                s.phase = .confirming
                return (s, [.send([0x0d])])     // 最终 Enter → Mole 执行删除
            }
            s.phase = .failed("mo 的确认屏显示 \(n) 项，但你选择了 \(s.wanted.count) 项。未删除任何内容，请重新扫描重试。")
            return (s, [.send([0x1b]), .send(MoTUI.quit)])
        }
        guard s.settleAttempt < maxAttempts else {
            s.phase = .failed("mo 未在规定时间内到达确认屏。未删除任何内容，请重试。")
            return (s, [.send([0x1b]), .send(MoTUI.quit)])
        }
        s.settleAttempt += 1
        return (s, [])
    }

    /// 每 tick 重新解析屏幕，直到连续两次读取的屏幕选择一致才算稳定。
    /// 然后仅当勾选行按 index、按 name、按行数都与用户选择一致才继续。
    private static func tickViewport(_ s: inout State) -> (State, [Effect]) {
        let maxAttempts = 35      // 约 2.1 秒稳定余量
        let screenNow = MoTUI.parse(s.screen)
        let onScreen = MoTUI.selectedIndices(screenNow)
        if s.settleAttempt > 0, onScreen == s.lastSelected {
            let onScreenNames = Set(screenNow.items.filter { $0.selected }.map { $0.name })
            let safe = screenNow.items.count == s.expectedCount
                && onScreen == s.wanted
                && onScreenNames == s.wantedNames
            if safe {
                s.phase = .awaitingConfirm
                s.confirmScreen = ""
                s.settleAttempt = 0
                return (s, [.send([0x0d])])     // Enter → Mole 的 "Remove N?" 屏
            }
            s.phase = .failed("无法安全确认选择（\(onScreen.count)/\(s.wanted.count) 已切换）。未删除任何内容，请重试。")
            return (s, [.send(MoTUI.quit)])
        }
        guard s.settleAttempt < maxAttempts else {
            s.phase = .failed("选择未在规定时间内稳定。未删除任何内容，请重试。")
            return (s, [.send(MoTUI.quit)])
        }
        s.lastSelected = onScreen
        s.settleAttempt += 1
        return (s, [])
    }

    private static func exited(_ s: inout State, _ code: Int32) -> (State, [Effect]) {
        switch s.phase {
        case .done, .failed:
            return (s, [])                 // 不覆盖已决定的终态
        case .scanning where !s.listReady:
            s.phase = .done(code)          // 列表出现前退出 — "无可删除项"
            return (s, [])
        case .confirming, .awaitingConfirm:
            // 已继续：result 持有删除日志；若 Mole 在第一个 Enter 后直接退出
            // （无第二屏），回退到已见内容。
            let raw = s.result.isEmpty ? s.confirmScreen : s.result
            s.resultText = ANSIStripper.strip(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if s.resultText.isEmpty { s.resultText = "完成 — mo 已结束。" }
            s.phase = .done(code)
            return (s, [])
        default:
            return (s, [])
        }
    }

    // MARK: - 输出摄入

    private static func ingest(_ s: inout State, _ text: String) -> (State, [Effect]) {
        switch s.phase {
        case .scanning:
            s.screen += text
            if !s.listReady, s.screen.contains("Enter"), s.screen.contains("Confirm") {
                let parsed = MoTUI.parse(s.screen)
                if !parsed.items.isEmpty {
                    s.listReady = true
                    s.items = parsed.items
                    s.viewportCount = parsed.items.count
                    s.totalCount = max(MoTUI.totalCount(s.screen) ?? parsed.items.count, parsed.items.count)
                    s.phase = .choosing
                }
            }
            return (s, [])
        case .loadingAll, .applyingViewport, .applyingFull:
            s.screen += text       // 累加重绘让 tick 能重读屏幕
            return (s, [])
        case .awaitingConfirm:
            s.confirmScreen += text   // Mole 的 "Remove N?" 屏，最终 Enter 前校验
            return (s, [])
        case .confirming:
            s.result += text          // 最终 Enter 后 Mole 的删除日志
            return (s, [])
        default:
            return (s, [])
        }
    }
}
