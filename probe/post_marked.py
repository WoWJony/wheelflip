# S0 探针配合:投递带标记与不带标记的合成离散滚轮事件(六字段全部置非零)。
# 用于验证 annotated 位置的 active tap(MarkedFlipTap)能否正确修改六个滚动字段。
# 用法: uv run --with pyobjc-framework-Quartz python probe/post_marked.py
import time
import Quartz

MARKER = 0x5A17  # 与 TargetProbe.swift 的 markerValue 一致

# 六字段期望输入(line 单位、双轴)
POSTED = {"d1": -3, "d2": 2, "pd1": -30, "pd2": 20, "fd1": -3.0, "fd2": 2.0}


def make_event(marked: bool):
    ev = Quartz.CGEventCreateScrollWheelEvent(
        None, Quartz.kCGScrollEventUnitLine, 2, POSTED["d1"], POSTED["d2"])
    Quartz.CGEventSetIntegerValueField(ev, Quartz.kCGScrollWheelEventPointDeltaAxis1, POSTED["pd1"])
    Quartz.CGEventSetIntegerValueField(ev, Quartz.kCGScrollWheelEventPointDeltaAxis2, POSTED["pd2"])
    Quartz.CGEventSetDoubleValueField(ev, Quartz.kCGScrollWheelEventFixedPtDeltaAxis1, POSTED["fd1"])
    Quartz.CGEventSetDoubleValueField(ev, Quartz.kCGScrollWheelEventFixedPtDeltaAxis2, POSTED["fd2"])
    if marked:
        Quartz.CGEventSetIntegerValueField(ev, Quartz.kCGEventSourceUserData, MARKER)
    return ev


def post(marked: bool):
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, make_event(marked))


# 顺序:未标记 → 停顿 → 标记 → 停顿 → 标记,时间戳间隙供离线对齐
post(False)
time.sleep(1.0)
post(True)
time.sleep(1.0)
post(True)
print(f"posted: unmarked x1 + marked x2, fields={POSTED}")
