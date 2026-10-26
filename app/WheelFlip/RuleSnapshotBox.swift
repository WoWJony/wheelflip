// 引擎回调的规则读取入口(计划 §6.1、§7.4)。
//
// 为什么不让引擎直接读 RuleStore:RuleStore 的锁在保存时覆盖"编码+写盘+回读验证"
// 整段文件 I/O;若滚轮回调与用户保存竞争同一把锁,回调会被文件写入卡住,极端时
// 触发 tap 超时禁用(即 S0 冻结事故同类的回调阻塞链)。
// 这里维护一个只做内存交换的原子快照盒:保存成功后由状态层 publish,回调加锁
// 仅持有微秒级,满足 §7.4"在不可变内存快照中查找规则"。

import Foundation

protocol ScrollRuleProviding: AnyObject {
    /// nil = 规则不可用(未载入/恢复模式):调用方按放行处理并计数(§3.2)。
    func decision(forBundle bundleID: String?, eventKind: ScrollEventKind) -> FlipDecision?
}

/// 原子替换的不可变规则快照。
final class RuleSnapshotBox: ScrollRuleProviding {
    private let lock = NSLock()
    private var snapshot: RuleSettings?

    /// 载入成功或每次成功保存后调用;nil 表示规则不可用(进入恢复模式等)。
    func publish(_ settings: RuleSettings?) {
        lock.lock()
        snapshot = settings
        lock.unlock()
    }

    var current: RuleSettings? {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    func decision(forBundle bundleID: String?, eventKind: ScrollEventKind) -> FlipDecision? {
        lock.lock(); defer { lock.unlock() }
        guard let snapshot else { return nil }
        let override = bundleID.flatMap { snapshot.overrides[$0]?.mode }
        return FlipPolicy.decide(defaultFlip: snapshot.defaultFlip, override: override, eventKind: eventKind)
    }
}
