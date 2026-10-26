// 引擎诊断计数(计划 §7.4 第 5 条、S2 任务"未知目标计数、解析耗时和最近结果摘要")。
// 全部内存计数,不落盘、不长期保存窗口信息;供 popover/headless 查看。

import Foundation

/// 供 UI/headless 读取的诊断快照(值类型)。
struct EngineDiagnosticsSnapshot: Equatable {
    var discreteSeen = 0
    var discreteFlipped = 0
    var continuousSeen = 0
    /// 目标 PID 存在但解析不出 App 身份(no-app-bundle 等)。
    var unresolvableTargets = 0
    /// 事件没有目标 PID(理论上 annotated 位置不应发生;持续增长说明路线前提被破坏)。
    var missingTargetPIDs = 0
    /// 规则不可用(未载入/恢复模式)而放行的离散事件数。
    var noRulesPassthrough = 0
    var appOverrideDecisions = 0
    var globalDefaultDecisions = 0
    var tapTimeoutDisables = 0
    var tapUserInputDisables = 0
    var reenables = 0
    var reenableGaveUps = 0
    var resolveCount = 0
    var totalResolveMicros = 0
    var maxResolveMicros = 0
    /// 最近一次离散事件摘要;不含窗口信息,进程内内存,不落盘。
    var lastDiscrete: LastDiscreteSummary?

    var averageResolveMicros: Int {
        resolveCount == 0 ? 0 : totalResolveMicros / resolveCount
    }
}

struct LastDiscreteSummary: Equatable {
    let bundleID: String?
    let flipped: Bool
    let source: FlipDecisionSource?
    let resolveMicros: Int
}

/// 线程安全的计数器集合;事件回调线程写,UI/headless 线程读快照。
final class EngineDiagnostics {
    private let lock = NSLock()
    private var value = EngineDiagnosticsSnapshot()

    func snapshot() -> EngineDiagnosticsSnapshot {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func noteDiscrete(bundleID: String?, flipped: Bool, source: FlipDecisionSource?, resolveMicros: Int) {
        lock.lock()
        value.discreteSeen += 1
        if flipped { value.discreteFlipped += 1 }
        value.resolveCount += 1
        value.totalResolveMicros += resolveMicros
        value.maxResolveMicros = max(value.maxResolveMicros, resolveMicros)
        value.lastDiscrete = LastDiscreteSummary(bundleID: bundleID, flipped: flipped, source: source, resolveMicros: resolveMicros)
        switch source {
        case .appOverride: value.appOverrideDecisions += 1
        case .globalDefault: value.globalDefaultDecisions += 1
        case .continuousPassthrough, nil: break
        }
        lock.unlock()
    }

    func noteContinuous() {
        lock.lock()
        value.continuousSeen += 1
        lock.unlock()
    }

    func noteUnresolvableTarget() {
        lock.lock()
        value.unresolvableTargets += 1
        lock.unlock()
    }

    func noteMissingTargetPID() {
        lock.lock()
        value.missingTargetPIDs += 1
        lock.unlock()
    }

    func noteNoRulesPassthrough() {
        lock.lock()
        value.noRulesPassthrough += 1
        lock.unlock()
    }

    func noteTapTimeout() {
        lock.lock()
        value.tapTimeoutDisables += 1
        lock.unlock()
    }

    func noteTapUserInput() {
        lock.lock()
        value.tapUserInputDisables += 1
        lock.unlock()
    }

    func noteReenable() {
        lock.lock()
        value.reenables += 1
        lock.unlock()
    }

    func noteReenableGaveUp() {
        lock.lock()
        value.reenableGaveUps += 1
        lock.unlock()
    }
}
