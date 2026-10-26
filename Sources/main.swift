// wheelflip — 只反转鼠标滚轮方向,触控板不动
//
// 原理: CGEventTap 拦截 scrollWheel 事件。触控板/Magic Mouse 发的是
// continuous 事件(scrollWheelEventIsContinuous == 1),普通鼠标滚轮是
// discrete(== 0)。只对 discrete 事件把三组 delta 取反,其余原样放行。
// 这样系统"自然滚动"保持开启(触控板体验不变),鼠标滚轮方向被翻回传统方向。

import ApplicationServices
import CoreGraphics
import Foundation

func log(_ msg: String) {
    FileHandle.standardError.write(Data("[wheelflip] \(msg)\n".utf8))
}

// ---- 1. 辅助功能权限(修改事件流必需) ----
// 权限查询结果在进程内会被缓存,授权后必须重启进程才能读到新状态;
// 所以未授权时直接退出,靠 launchd KeepAlive 自动重拉(约 10s 一次)。
if !AXIsProcessTrusted() {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    AXIsProcessTrustedWithOptions(opts)
    log("无辅助功能权限,退出等 launchd 重拉。请在 系统设置 → 隐私与安全性 → 辅助功能 里允许 wheelflip")
    Thread.sleep(forTimeInterval: 3)
    exit(1)
}

// ---- 2. 事件回调 ----
// 全局可变引用,供回调里重新启用被系统禁用的 tap(超时/用户输入会触发禁用)。
var tapPort: CFMachPort?

let callback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = tapPort {
            CGEvent.tapEnable(tap: tap, enable: true)
            log("event tap 被系统禁用,已重新启用")
        }
        return Unmanaged.passUnretained(event)
    }
    guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }

    // 触控板 / Magic Mouse → continuous,放行;滚轮鼠标 → 翻转
    guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else {
        return Unmanaged.passUnretained(event)
    }

    // 垂直(axis1)与水平(axis2,倾斜滚轮)都翻,等价于对鼠标单独关掉自然滚动。
    // 注意: 滚动各字段联动,写线级 delta 会自动同步像素级字段——
    // 必须先把所有值读完,再统一写回,否则逐字段"读-取反-写"会负负得正。
    let intFields: [CGEventField] = [
        .scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2,
        .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2,
    ]
    let doubleFields: [CGEventField] = [
        .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2,
    ]
    let intValues = intFields.map { event.getIntegerValueField($0) }
    let doubleValues = doubleFields.map { event.getDoubleValueField($0) }
    for (f, v) in zip(intFields, intValues) {
        event.setIntegerValueField(f, value: -v)
    }
    for (f, v) in zip(doubleFields, doubleValues) {
        event.setDoubleValueField(f, value: -v)
    }
    return Unmanaged.passUnretained(event)
}

// ---- 3. 挂 tap 进 run loop ----
guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: 1 << CGEventType.scrollWheel.rawValue,
    callback: callback,
    userInfo: nil
) else {
    log("创建 event tap 失败(通常是辅助功能权限未生效),退出")
    exit(1)
}
tapPort = tap

let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
log("运行中: 鼠标滚轮已反转,触控板保持自然滚动")
CFRunLoopRun()
