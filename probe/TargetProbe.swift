// S0 最小探针:比较两个 tap 位置上滚轮事件的目标识别 + 目录可见性快照。
//
// 目的:docs/PER_APP_SCROLL_PLAN.md §7.2 —— 验证 .cgSessionEventTap 与
// .cgAnnotatedSessionEventTap 各自读到的 eventTargetUnixProcessID 是否指向
// 鼠标所在窗口所属的 App(即使该 App 不在前台);§5.1 应用目录在当前责任方下的可见性。
//
// 安全性:默认两个 tap 都是 listen-only 只读不写;--flip-marked 模式为唯一
// active tap,且只翻转带 eventSourceUserData 标记的合成事件,不触碰用户真实滚动,
// 可与日常运行的翻转实例共存(同一时刻仍只有一个"修改所有事件"的引擎)。
//
// 编译:swiftc -O probe/TargetProbe.swift -o probe/build/target-probe
// 用法:
//   target-probe                    双 listen tap(S+A),stdout+文件日志,启动时目录快照
//   target-probe --dirs-only        只做目录可见性快照并退出
//   target-probe --flip-marked      单 active tap 于 annotated 位置,仅翻转标记事件
//   target-probe --single S|A       只挂一个 listen tap
//   target-probe --log PATH         显式日志文件路径(默认 ~/s0-probe-log/probe-<pid>.jsonl;
//                                   沙盒 App 内即容器 Data 目录)
//   target-probe --no-snapshot      跳过启动目录快照
// 输出:stdout 与日志文件同步,每条事件一行 JSON;Ctrl-C/SIGTERM 干净退出。

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

let markerValue: Int64 = 0x5A17 // 标记事件专用 eventSourceUserData,区别于 selftest 的 0x57F11F

// MARK: - 事件字段采集 + PID 身份解析(带缓存与耗时测量)

final class EventLogger {
    private struct Identity {
        var bundleID: String?
        var execPath: String?
        var appPath: String?
        var kind: String // app / process / unknown
    }

    private var cache: [Int32: (identity: Identity, resolveMicros: Int)] = [:]
    private var fileHandle: FileHandle?

    init(logPath: String?) {
        if let logPath {
            let url = URL(fileURLWithPath: logPath)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            fileHandle = try? FileHandle(forWritingTo: url)
            _ = try? fileHandle?.seekToEnd()
        }
    }

    func emit(_ record: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
        if let handle = fileHandle, let data = (line + "\n").data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }

    func log(tap: String, event: CGEvent, action: String? = nil) {
        let ts = DispatchTime.now().uptimeNanoseconds / 1000
        let targetPID = event.getIntegerValueField(.eventTargetUnixProcessID)
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        // kCGMouseEventWindowNumber = 8,Swift 未导入该常量名,按数值取
        let windowNumber = event.getIntegerValueField(CGEventField(rawValue: 8)!)
        let location = event.location

        var resolveMicros = 0
        var identity = Identity(bundleID: nil, execPath: nil, appPath: nil, kind: "unknown")
        if targetPID != 0 {
            if let cached = cache[Int32(targetPID)] {
                identity = cached.identity
                resolveMicros = 0
            } else {
                let t0 = DispatchTime.now().uptimeNanoseconds
                identity = Self.resolve(pid: Int32(targetPID))
                resolveMicros = Int((DispatchTime.now().uptimeNanoseconds - t0) / 1000)
                cache[Int32(targetPID)] = (identity, resolveMicros)
            }
        }

        let front = NSWorkspace.shared.frontmostApplication

        var record: [String: Any] = [
            "ts_us": ts,
            "tap": tap,
            "continuous": event.getIntegerValueField(.scrollWheelEventIsContinuous),
            "d1": event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
            "d2": event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
            "pd1": event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
            "pd2": event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2),
            "fd1": event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
            "fd2": event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
            "marker": event.getIntegerValueField(.eventSourceUserData),
            "x": Int(location.x),
            "y": Int(location.y),
            "win": windowNumber,
            "src_pid": sourcePID,
            "tgt_pid": targetPID,
            "tgt_kind": identity.kind,
            "resolve_us": resolveMicros,
            "front_pid": front?.processIdentifier ?? 0,
            "front_bundle": front?.bundleIdentifier ?? NSNull(),
        ]
        if let action { record["action"] = action }
        if let bundleID = identity.bundleID { record["tgt_bundle"] = bundleID }
        if let execPath = identity.execPath { record["tgt_exec"] = execPath }
        if let appPath = identity.appPath { record["tgt_app"] = appPath }
        emit(record)
    }

    /// PID → 身份。NSRunningApplication 覆盖普通 App;proc_pidpath 补 helper/XPC 进程,
    /// 并从可执行路径推导所属 .app 包(helper 归属的运行时证据,不按进程名猜)。
    private static func resolve(pid: Int32) -> Identity {
        let running = NSRunningApplication(processIdentifier: pid)
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let path = proc_pidpath(pid, &pathBuffer, 4096) > 0 ? String(cString: pathBuffer) : nil

        var appPath: String?
        if let path {
            let parts = path.split(separator: "/").map(String.init)
            if let idx = parts.lastIndex(where: { $0.hasSuffix(".app") }) {
                appPath = "/" + parts[...idx].joined(separator: "/")
            }
        }

        if let running {
            return Identity(bundleID: running.bundleIdentifier, execPath: path, appPath: appPath, kind: "app")
        }
        if path != nil {
            return Identity(bundleID: nil, execPath: path, appPath: appPath, kind: "process")
        }
        return Identity(bundleID: nil, execPath: nil, appPath: nil, kind: "unknown")
    }
}

// MARK: - listen-only tap(stop 沿用 FlipEngine 的三步清理纪律)

final class ScrollTap {
    let tag: String
    private let logger: EventLogger
    private let autoReenable: Bool
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private static var all: [ScrollTap] = []

    init?(tag: String, location: CGEventTapLocation, logger: EventLogger, autoReenable: Bool = true) {
        self.tag = tag
        self.logger = logger
        self.autoReenable = autoReenable
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: location,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: 1 << CGEventType.scrollWheel.rawValue,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<ScrollTap>.fromOpaque(refcon).takeUnretainedValue()
                return owner.handle(type: type, event: event)
            },
            userInfo: info
        ) else { return nil }
        guard let rlSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return nil
        }
        port = tap
        source = rlSource
        CFRunLoopAddSource(CFRunLoopGetCurrent(), rlSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        ScrollTap.all.append(self)
    }

    func stop() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        if let port {
            CFMachPortInvalidate(port)
        }
        port = nil
        source = nil
    }

    static func stopAll() {
        for tap in all { tap.stop() }
        all.removeAll()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent> {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // 诊断模式不自动重挂:tap 被系统禁用就保持禁用并记录,避免超时-重挂循环拖慢整机
            logger.emit(["probe": "tap-disabled", "tap": tag, "type": type.rawValue, "reenabled": autoReenable])
            if autoReenable, let port {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
        logger.log(tap: tag, event: event)
        return Unmanaged.passUnretained(event)
    }
}

// MARK: - 标记翻转 tap(active,annotated 位置,只翻标记事件)

final class MarkedFlipTap {
    private let logger: EventLogger
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    // refcon 是 passUnretained,必须自持,否则创建者作用域结束对象被释放,
    // 下一条事件可能回调进已释放内存并导致 SIGSEGV。
    private static var all: [MarkedFlipTap] = []

    init?(logger: EventLogger) {
        self.logger = logger
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: 1 << CGEventType.scrollWheel.rawValue,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<MarkedFlipTap>.fromOpaque(refcon).takeUnretainedValue()
                return owner.handle(type: type, event: event)
            },
            userInfo: info
        ) else { return nil }
        guard let rlSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return nil
        }
        port = tap
        source = rlSource
        CFRunLoopAddSource(CFRunLoopGetCurrent(), rlSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        MarkedFlipTap.all.append(self)
    }

    func stop() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        if let port {
            CFMachPortInvalidate(port)
        }
        port = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent> {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
        guard event.getIntegerValueField(.eventSourceUserData) == markerValue else {
            logger.log(tap: "F", event: event, action: "pass")
            return Unmanaged.passUnretained(event)
        }
        // 与 FlipEngine 相同的算法:先读全部字段进快照,continuous 放行,再统一写回
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let d1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let d2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let pd1 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let pd2 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        let fd1 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let fd2 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        if isContinuous {
            logger.log(tap: "F", event: event, action: "pass-continuous")
            return Unmanaged.passUnretained(event)
        }
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -d1)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -d2)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -pd1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -pd2)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fd1)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -fd2)
        logger.log(tap: "F", event: event, action: "flip")
        return Unmanaged.passUnretained(event)
    }
}

// MARK: - 应用目录可见性快照(计划 §5.1)

func directorySnapshot(logger: EventLogger) {
    let fm = FileManager.default
    var snap: [String: Any] = [
        "snap": "dirs",
        "ts_us": DispatchTime.now().uptimeNanoseconds / 1000,
        "home_api": NSHomeDirectory(),
    ]
    if let pw = getpwuid(getuid()) {
        snap["home_pw"] = String(cString: pw.pointee.pw_dir)
    }
    let userAppDirs = fm.urls(for: .applicationDirectory, in: .userDomainMask)
    snap["user_domain_appdir"] = userAppDirs.map(\.path)
    let allAppDirs = fm.urls(for: .applicationDirectory, in: .allDomainsMask)
    snap["all_domain_appdirs"] = allAppDirs.map(\.path)

    var dirs: [String: Any] = [:]
    var candidates = ["/Applications", "/System/Applications"]
    if let userDir = userAppDirs.first { candidates.append(userDir.path) }
    if let pw = getpwuid(getuid()) {
        candidates.append(String(cString: pw.pointee.pw_dir) + "/Applications")
    }
    for dir in candidates {
        var info: [String: Any] = [:]
        info["exists"] = fm.fileExists(atPath: dir)
        info["readable"] = fm.isReadableFile(atPath: dir)
        if let items = try? fm.contentsOfDirectory(atPath: dir) {
            info["items"] = items.count
            info["apps"] = items.filter { $0.hasSuffix(".app") }.count
        }
        dirs[dir] = info
    }
    snap["dirs"] = dirs

    // 单个已知 App 的可读性证据(沙盒内能否读 /Applications 下 App 的 Info.plist)
    for path in ["/Applications/Warp.app/Contents/Info.plist",
                 "/Applications/Rhino 8.app/Contents/Info.plist"] {
        let key = path.hasPrefix("/Applications/Warp") ? "read_warp_plist_bytes" : "read_rhino_plist_bytes"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            snap[key] = data.count
        } else {
            snap[key] = "unreadable"
        }
    }

    var volumes: [String: Any] = [:]
    if let vols = fm.mountedVolumeURLs(includingResourceValuesForKeys: nil) {
        for vol in vols {
            volumes[vol.path] = fm.isReadableFile(atPath: vol.path)
        }
    }
    snap["volumes"] = volumes
    logger.emit(snap)

    // Spotlight 可用性(异步,8 秒内收不到就记 timeout)
    let query = NSMetadataQuery()
    query.predicate = NSPredicate(format: "kMDItemContentType == %@", "com.apple.application-bundle")
    var finished = false
    var observer: NSObjectProtocol?
    observer = NotificationCenter.default.addObserver(
        forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
    ) { _ in
        finished = true
        logger.emit(["snap": "spotlight", "count": query.resultCount, "status": "finished"])
        query.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
    query.start()
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
        if !finished {
            logger.emit(["snap": "spotlight", "count": query.resultCount, "status": "timeout"])
            query.stop()
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

// MARK: - 入口

setvbuf(stdout, nil, _IONBF, 0)

var args = CommandLine.arguments
var flipMarked = false
var dirsOnly = false
var snapshot = true
var single: String?
var logPath: String?
var diagAnnotated = false
var watchdogSeconds: Double = 0
var i = 1
while i < args.count {
    switch args[i] {
    case "--flip-marked": flipMarked = true
    case "--dirs-only": dirsOnly = true
    case "--no-snapshot": snapshot = false
    case "--diag-annotated": diagAnnotated = true
    case "--single": i += 1; single = i < args.count ? args[i] : nil
    case "--log": i += 1; logPath = i < args.count ? args[i] : nil
    case "--watchdog": i += 1; watchdogSeconds = i < args.count ? (Double(args[i]) ?? 0) : 0
    default: break
    }
    i += 1
}

if diagAnnotated || (Bundle.main.bundleIdentifier == "com.jonywu.WheelFlip.S0Probe"
    && FileManager.default.fileExists(atPath: NSHomeDirectory() + "/s0-probe-log/diag-flag")) {
    diagAnnotated = true
    // 诊断模式:stdout 丢弃(防 pipe 阻塞),默认 60s 看门狗自杀,超时不自动重挂
    freopen("/dev/null", "w", stdout)
    if watchdogSeconds <= 0 { watchdogSeconds = 60 }
}

if logPath == nil {
    let dir = NSHomeDirectory() + "/s0-probe-log"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    logPath = dir + "/probe-\(getpid()).jsonl"
}

let logger = EventLogger(logPath: logPath)
logger.emit([
    "probe": "start", "pid": getpid(), "axTrusted": AXIsProcessTrusted(),
    "mode": flipMarked ? "flip-marked" : (dirsOnly ? "dirs-only" : "listen"),
    "log": logPath!, "ts_us": DispatchTime.now().uptimeNanoseconds / 1000,
])

if dirsOnly {
    directorySnapshot(logger: logger)
    RunLoop.main.run(until: Date().addingTimeInterval(10))
    exit(0)
}

if snapshot {
    directorySnapshot(logger: logger)
}

// 沙盒 App 形态(通过 open 启动,bundle id 为探针专用):未授权时弹系统授权提示并轮询等待;
// CLI 形态不弹提示,由操作者负责环境。授权结果进程内有缓存,授权后可能需要重启进程(README 记录)。
if Bundle.main.bundleIdentifier == "com.jonywu.WheelFlip.S0Probe" && !AXIsProcessTrusted() {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
    logger.emit(["probe": "await-trust", "hint": "请在系统设置→隐私与安全性→辅助功能中允许 WheelFlipS0Probe"])
    while !AXIsProcessTrusted() {
        RunLoop.main.run(until: Date().addingTimeInterval(2))
    }
    logger.emit(["probe": "trust-granted", "ts_us": DispatchTime.now().uptimeNanoseconds / 1000])
}

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let sources = [SIGTERM, SIGINT].map { sig in
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        ScrollTap.stopAll()
        logger.emit(["probe": "stop"])
        exit(0)
    }
    src.resume()
    return src
}

if watchdogSeconds > 0 {
    DispatchQueue.main.asyncAfter(deadline: .now() + watchdogSeconds) {
        ScrollTap.stopAll()
        logger.emit(["probe": "watchdog-exit"])
        exit(0)
    }
}

if diagAnnotated {
    let tap = ScrollTap(tag: "A", location: .cgAnnotatedSessionEventTap, logger: logger, autoReenable: false)
    logger.emit(["probe": "taps", "diagAnnotated": tap != nil])
} else if flipMarked {
    let flipper = MarkedFlipTap(logger: logger)
    logger.emit(["probe": "taps", "flipMarked": flipper != nil])
} else if let single {
    let location: CGEventTapLocation = single == "S" ? .cgSessionEventTap : .cgAnnotatedSessionEventTap
    let tap = ScrollTap(tag: single, location: location, logger: logger)
    logger.emit(["probe": "taps", single: tap != nil])
} else {
    let sessionTap = ScrollTap(tag: "S", location: .cgSessionEventTap, logger: logger)
    let annotatedTap = ScrollTap(tag: "A", location: .cgAnnotatedSessionEventTap, logger: logger)
    logger.emit(["probe": "taps", "session": sessionTap != nil, "annotated": annotatedTap != nil])
}

RunLoop.main.run()
