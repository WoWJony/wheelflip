# wheelflip 端到端自测:
# 1. 引擎在 .cgAnnotatedSessionEventTap(headInsert)修改事件;
#    session 观察点位于其上游,故本观察 tap 同样挂在
#    annotated(tailAppend,创建晚于引擎 → 位于引擎下游)。
# 2. 发一条 discrete(line 单位,模拟鼠标滚轮)+ 一条 continuous(pixel 单位,模拟触控板)
# 3. 断言: discrete 的 delta 被取反,continuous 原样通过
import sys
import threading
import Quartz

if not hasattr(Quartz, "kCGAnnotatedSessionEventTap"):
    print("SKIP: PyObjC 无 kCGAnnotatedSessionEventTap,无法自测")
    sys.exit(2)
TAP_LOCATION = Quartz.kCGAnnotatedSessionEventTap

MARKER = 0x57F11F  # 用 eventSourceUserData 标记自己发的事件,过滤环境噪声
posted_delta = 3
received = []

def cb(proxy, type_, event, refcon):
    if type_ == Quartz.kCGEventScrollWheel:
        if Quartz.CGEventGetIntegerValueField(event, Quartz.kCGEventSourceUserData) == MARKER:
            received.append({
                "continuous": Quartz.CGEventGetIntegerValueField(
                    event, Quartz.kCGScrollWheelEventIsContinuous),
                "delta": Quartz.CGEventGetIntegerValueField(
                    event, Quartz.kCGScrollWheelEventDeltaAxis1),
                "pointDelta": Quartz.CGEventGetIntegerValueField(
                    event, Quartz.kCGScrollWheelEventPointDeltaAxis1),
                "fixedPt": Quartz.CGEventGetDoubleValueField(
                    event, Quartz.kCGScrollWheelEventFixedPtDeltaAxis1),
            })
    return event

tap = Quartz.CGEventTapCreate(
    TAP_LOCATION, Quartz.kCGTailAppendEventTap,
    Quartz.kCGEventTapOptionListenOnly,
    Quartz.CGEventMaskBit(Quartz.kCGEventScrollWheel), cb, None)
if tap is None:
    print("SKIP: 本进程无权限创建观察 tap,无法自测")
    sys.exit(2)

src = Quartz.CFMachPortCreateRunLoopSource(None, tap, 0)
loop = Quartz.CFRunLoopGetCurrent()
Quartz.CFRunLoopAddSource(loop, src, Quartz.kCFRunLoopCommonModes)
Quartz.CGEventTapEnable(tap, True)

def post():
    for unit in (Quartz.kCGScrollEventUnitLine, Quartz.kCGScrollEventUnitPixel):
        ev = Quartz.CGEventCreateScrollWheelEvent(None, unit, 1, posted_delta)
        Quartz.CGEventSetIntegerValueField(ev, Quartz.kCGEventSourceUserData, MARKER)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)

threading.Timer(0.5, post).start()
threading.Timer(2.0, lambda: Quartz.CFRunLoopStop(loop)).start()
Quartz.CFRunLoopRun()

print("收到:", received)
disc = [r for r in received if r["continuous"] == 0]
cont = [r for r in received if r["continuous"] == 1]
ok = True
if not disc or disc[0]["delta"] != -posted_delta:
    print(f"FAIL: 鼠标(discrete)线级 delta 应为 {-posted_delta},实际 {disc}")
    ok = False
elif disc[0]["pointDelta"] > 0 or disc[0]["fixedPt"] > 0:
    print(f"FAIL: 鼠标(discrete)像素级字段未翻转,三组符号不一致: {disc[0]}")
    ok = False
else:
    print(f"PASS: 鼠标(discrete)+{posted_delta} → {disc[0]}(三组字段全部翻转)")
if not cont or cont[0]["pointDelta"] != posted_delta:
    print(f"FAIL: 触控板(continuous)事件 pointDelta 应保持 +{posted_delta},实际 {cont}")
    ok = False
else:
    print(f"PASS: 触控板(continuous)事件 +{posted_delta} → {cont[0]['pointDelta']}(未动)")
sys.exit(0 if ok else 1)
