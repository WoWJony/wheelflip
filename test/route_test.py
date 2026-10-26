# 按目标路由的自动回归:
#   1. 准备临时规则:默认关 + Finder=forceOff + Dock=forceOn(两身份相反规则,
#      验证覆盖规则在真机上的路由)。
#   2. 起 headless 引擎(临时规则,不碰日常配置),向 Finder/Dock/SystemUIServer
#      定向投递标记事件,同时用 annotated tailAppend 观察 tap(位于引擎下游)
#      核对最终字段:垂直六字段、水平轴、快速交替、暂停放行、重启后规则保持。
#   3. 输出 PASS / FAIL / SKIP(无权限/无目标进程);SKIP 不算通过。
# 定向投递验证"事件目标→规则";真实鼠标命中窗口与使用体验仍需手工验证。
import json
import os
import signal
import subprocess
import sys
import threading
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(REPO, "app/build/per-app-validation/Build/Products/Release/WheelFlip.app/Contents/MacOS/WheelFlip")
CONTAINER_TMP = os.path.expanduser("~/Library/Containers/com.jonywu.WheelFlip/Data/tmp")
RULES = os.path.join(CONTAINER_TMP, "route-test-rules.json")
MARKER = 0x5A51

import Quartz  # noqa: E402  (放在路径检查之后,缺依赖时给 SKIP)

results = []


def check(name, ok, detail=""):
    results.append((name, ok, detail))
    print(("PASS" if ok else "FAIL") + f": {name}" + (f" — {detail}" if detail else ""))


def find_target(bundle_id):
    apps = Quartz.NSRunningApplication.runningApplicationsWithBundleIdentifier_(bundle_id)
    if apps is None or len(apps) == 0:
        return None
    return apps[0].processIdentifier()


def write_rules():
    os.makedirs(CONTAINER_TMP, exist_ok=True)
    # scratch defaults 迁移基线为空 → load() 读到该文件按 loaded 处理
    json.dump({
        "schemaVersion": 1,
        "revision": 5,
        "defaultFlip": False,
        "overrides": {
            "com.apple.finder": {"mode": "forceOff"},
            "com.apple.dock": {"mode": "forceOn"},
        },
    }, open(RULES, "w"))


class Observer:
    """annotated tailAppend listen-only tap:记录标记事件在引擎下游的最终字段。
    tap 的创建/挂载/运行必须在同一条有 run loop 的线程里完成。"""

    def __init__(self):
        self.received = []
        self.lock = threading.Lock()
        self.tap = None
        self.loop = None
        self._ready = threading.Event()
        threading.Thread(target=self._run, daemon=True).start()
        self._ready.wait(5)

    def _run(self):
        self.tap = Quartz.CGEventTapCreate(
            Quartz.kCGAnnotatedSessionEventTap, Quartz.kCGTailAppendEventTap,
            Quartz.kCGEventTapOptionListenOnly,
            Quartz.CGEventMaskBit(Quartz.kCGEventScrollWheel), self._cb, None)
        if self.tap is not None:
            src = Quartz.CFMachPortCreateRunLoopSource(None, self.tap, 0)
            self.loop = Quartz.CFRunLoopGetCurrent()
            Quartz.CFRunLoopAddSource(self.loop, src, Quartz.kCFRunLoopCommonModes)
            Quartz.CGEventTapEnable(self.tap, True)
        self._ready.set()
        if self.tap is not None:
            Quartz.CFRunLoopRun()

    def _cb(self, proxy, type_, event, refcon):
        if type_ == Quartz.kCGEventScrollWheel:
            if Quartz.CGEventGetIntegerValueField(event, Quartz.kCGEventSourceUserData) == MARKER:
                with self.lock:
                    self.received.append({
                        "target": Quartz.CGEventGetIntegerValueField(event, Quartz.kCGEventTargetUnixProcessID),
                        "d1": Quartz.CGEventGetIntegerValueField(event, Quartz.kCGScrollWheelEventDeltaAxis1),
                        "d2": Quartz.CGEventGetIntegerValueField(event, Quartz.kCGScrollWheelEventDeltaAxis2),
                        "pd1": Quartz.CGEventGetIntegerValueField(event, Quartz.kCGScrollWheelEventPointDeltaAxis1),
                        "pd2": Quartz.CGEventGetIntegerValueField(event, Quartz.kCGScrollWheelEventPointDeltaAxis2),
                        "fd1": Quartz.CGEventGetDoubleValueField(event, Quartz.kCGScrollWheelEventFixedPtDeltaAxis1),
                        "fd2": Quartz.CGEventGetDoubleValueField(event, Quartz.kCGScrollWheelEventFixedPtDeltaAxis2),
                    })
        return event

    def stop(self):
        if getattr(self, "loop", None):
            Quartz.CFRunLoopStop(self.loop)

    def take(self):
        with self.lock:
            out, self.received = self.received, []
            return out


def post(pid, horizontal=False, continuous=False):
    args = ["--continuous"] if continuous else (["--horizontal"] if horizontal else [])
    subprocess.run(
        [sys.executable, os.path.join(REPO, "probe/post_targeted.py"), str(pid), "--marker", str(MARKER)] + args,
        check=True, capture_output=True)


class Engine:
    def __init__(self):
        self.proc = subprocess.Popen(
            [BIN, "--headless-run", "--settings", RULES],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    def wait_for(self, token, timeout=8):
        deadline = time.time() + timeout
        lines = []
        while time.time() < deadline:
            line = self.proc.stdout.readline()
            if not line:
                break
            lines.append(line.strip())
            if token in line:
                return lines
        raise TimeoutError(f"等待 {token} 超时;输出: {lines}")

    def stop(self):
        self.proc.send_signal(signal.SIGTERM)
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def verify_round(label, finder, dock, uiserver):
    """一轮定向投递 + 下游字段核对。返回是否全部通过。"""
    ok_all = True

    # 垂直轴:Finder forceOff(+默认关)→ 原样;六字段全部不变
    post(finder)
    time.sleep(0.4)
    seen = observer.take()
    f = next((e for e in seen if e["target"] == finder), None)
    ok = f is not None and f["d1"] == 3 and f["pd1"] == 30 and abs(f["fd1"] - 3.0) < 0.01
    check(f"{label} Finder(forceOff) 垂直原样", ok, str(f))
    ok_all &= ok

    # Dock forceOn(默认关)→ 翻转;六字段全部取反
    post(dock)
    time.sleep(0.4)
    seen = observer.take()
    d = next((e for e in seen if e["target"] == dock), None)
    ok = d is not None and d["d1"] == -3 and d["pd1"] == -30 and abs(d["fd1"] + 3.0) < 0.01
    check(f"{label} Dock(forceOn,默认关) 六字段翻转", ok, str(d))
    ok_all &= ok

    # SystemUIServer 无覆盖 → 跟随默认(关)→ 原样
    post(uiserver)
    time.sleep(0.4)
    seen = observer.take()
    u = next((e for e in seen if e["target"] == uiserver), None)
    ok = u is not None and u["d1"] == 3
    check(f"{label} 无覆盖 App 跟随默认(关)", ok, str(u))
    ok_all &= ok

    # 水平轴:Dock forceOn → 第二轴同样翻转(d2 -2→+2, pd2 -20→+20, fd2 -2→+2)
    post(dock, horizontal=True)
    time.sleep(0.4)
    seen = observer.take()
    h = next((e for e in seen if e["target"] == dock and e["d2"] != 0), None)
    ok = h is not None and h["d2"] == 2 and h["pd2"] == 20 and abs(h["fd2"] - 2.0) < 0.01
    check(f"{label} Dock 水平轴六字段翻转", ok, str(h))
    ok_all &= ok

    # 快速交替:Finder/Dock 各 3 次,顺序与方向不串
    for _ in range(3):
        post(finder)
        post(dock)
    time.sleep(0.8)
    seen = observer.take()
    seq = [(e["target"], e["d1"]) for e in seen if e["target"] in (finder, dock)]
    expect = [(finder, 3), (dock, -3)] * 3
    ok = seq == expect
    check(f"{label} 快速交替两身份方向不串", ok, str(seq))
    ok_all &= ok

    return ok_all


if not os.path.exists(BIN):
    print(f"SKIP: 未找到构建产物 {BIN};先 xcodebuild -derivedDataPath build/per-app-validation")
    sys.exit(2)

finder = find_target("com.apple.finder")
dock = find_target("com.apple.dock")
uiserver = find_target("com.apple.systemuiserver")
if not all([finder, dock, uiserver]):
    print(f"SKIP: 目标进程不全 finder={finder} dock={dock} uiserver={uiserver}")
    sys.exit(2)

observer = Observer()
if observer.tap is None:
    print("SKIP: 本进程无权限创建观察 tap")
    sys.exit(2)

write_rules()
engine = Engine()
try:
    engine.wait_for("[started]")
    ok = verify_round("首轮", finder, dock, uiserver)

    # 暂停:SIGUSR1 停引擎 → 投递事件 → 引擎不再翻转(观察点看到原值),无 EVT
    engine.proc.send_signal(signal.SIGUSR1)
    engine.wait_for("[stopped]")
    post(dock)
    time.sleep(0.5)
    seen = observer.take()
    d = next((e for e in seen if e["target"] == dock), None)
    paused_ok = d is not None and d["d1"] == 3  # 暂停 = 原样通过
    check("暂停后所有滚动原样通过", paused_ok, str(d))
    ok &= paused_ok

    # 恢复:SIGUSR1 重启 → 规则快照来自同一进程的 store,行为恢复
    engine.proc.send_signal(signal.SIGUSR1)
    engine.wait_for("[restarted]")
    post(dock)
    time.sleep(0.4)
    seen = observer.take()
    d = next((e for e in seen if e["target"] == dock), None)
    resumed_ok = d is not None and d["d1"] == -3
    check("恢复后规则重新生效", resumed_ok, str(d))
    ok &= resumed_ok
finally:
    engine.stop()

# 进程重启:退出后重新拉起,规则持久生效(持久化跨进程);观察 tap 全程保持
engine2 = Engine()
try:
    startup_lines = engine2.wait_for("[started]")
    loaded_ok = any("RULES: loaded" in line for line in startup_lines)
    check("重启后规则从磁盘载入(loaded 而非 freshInstall)", loaded_ok, str(startup_lines[:3]))
    ok &= loaded_ok
    ok &= verify_round("重启后", finder, dock, uiserver)
finally:
    engine2.stop()
    observer.stop()

failed = [name for name, o, _ in results if not o]
print(f"\n结果: {'PASS' if ok and not failed else 'FAIL'} ({len(results) - len(failed)}/{len(results)})")
sys.exit(0 if ok and not failed else 1)
