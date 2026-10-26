# 定向投递:把标记的合成滚动事件用 CGEventPostToPid 发给指定进程。
# 用途:S2/S5 引擎验证——annotated tap 的 eventTargetUnixProcessID 应为该进程,
# 引擎据此应用规则。注意(计划 §9.2):定向投递不能替代鼠标命中测试,
# 真实窗口路由由 selftest.py(HID 投递+观察 tap)覆盖。
# 用法:post_targeted.py <pid> [--continuous] [--horizontal] [--marker <n>]
import sys
import Quartz

MARKER = 0x5A27

pid = int(sys.argv[1])
continuous = "--continuous" in sys.argv
horizontal = "--horizontal" in sys.argv

if "--marker" in sys.argv:
    MARKER = int(sys.argv[sys.argv.index("--marker") + 1])

if continuous:
    ev = Quartz.CGEventCreateScrollWheelEvent(None, Quartz.kCGScrollEventUnitPixel, 1, 7)
    Quartz.CGEventSetIntegerValueField(ev, Quartz.kCGScrollWheelEventIsContinuous, 1)
elif horizontal:
    # 水平轴(第二轴):d2=-2/pd2=-20/fd2=-2.0(引擎按同一规则翻转全部六字段)
    ev = Quartz.CGEventCreateScrollWheelEvent(None, Quartz.kCGScrollEventUnitLine, 2, 0, -2)
    Quartz.CGEventSetIntegerValueField(ev, Quartz.kCGScrollWheelEventDeltaAxis1, 0)
    Quartz.CGEventSetIntegerValueField(ev, Quartz.kCGScrollWheelEventPointDeltaAxis1, 0)
    Quartz.CGEventSetDoubleValueField(ev, Quartz.kCGScrollWheelEventFixedPtDeltaAxis1, 0.0)
    Quartz.CGEventSetIntegerValueField(ev, Quartz.kCGScrollWheelEventPointDeltaAxis2, -20)
    Quartz.CGEventSetDoubleValueField(ev, Quartz.kCGScrollWheelEventFixedPtDeltaAxis2, -2.0)
else:
    ev = Quartz.CGEventCreateScrollWheelEvent(None, Quartz.kCGScrollEventUnitLine, 1, 3)
    Quartz.CGEventSetIntegerValueField(ev, Quartz.kCGScrollWheelEventPointDeltaAxis1, 30)
    Quartz.CGEventSetDoubleValueField(ev, Quartz.kCGScrollWheelEventFixedPtDeltaAxis1, 3.0)

Quartz.CGEventSetIntegerValueField(ev, Quartz.kCGEventSourceUserData, MARKER)
Quartz.CGEventPostToPid(pid, ev)
print(f"posted continuous={int(continuous)} horizontal={int(horizontal)} to pid={pid}")
