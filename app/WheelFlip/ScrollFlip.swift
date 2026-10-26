// 纯函数部分,不依赖 CGEvent,可单元测试。
// 坑 1(docs/APP_PLAN.md §0): 滚动六个字段联动,写线级 delta 会自动同步像素级字段;
// 必须先读全部六个字段再统一写回取反,逐字段读-反-写会负负得正。
// 用一个不可变的 ScrollFields 值类型 + 纯函数强制这个顺序,让回归不可能发生。

struct ScrollFields: Equatable {
    var isContinuous: Bool
    var deltaAxis1: Int64
    var deltaAxis2: Int64
    var pointDeltaAxis1: Int64
    var pointDeltaAxis2: Int64
    var fixedPtDeltaAxis1: Double
    var fixedPtDeltaAxis2: Double
}

enum ScrollFlip {
    // 触控板/Magic Mouse(continuous)不处理,返回 nil;鼠标滚轮(discrete)返回翻转后的值。
    static func flipped(_ fields: ScrollFields) -> ScrollFields? {
        guard !fields.isContinuous else { return nil }
        var result = fields
        result.deltaAxis1 = -result.deltaAxis1
        result.deltaAxis2 = -result.deltaAxis2
        result.pointDeltaAxis1 = -result.pointDeltaAxis1
        result.pointDeltaAxis2 = -result.pointDeltaAxis2
        result.fixedPtDeltaAxis1 = -result.fixedPtDeltaAxis1
        result.fixedPtDeltaAxis2 = -result.fixedPtDeltaAxis2
        return result
    }
}
