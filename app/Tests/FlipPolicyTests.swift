import XCTest
@testable import WheelFlip

/// §3.1 真值表:六种组合、continuous 放行、来源标注。
final class FlipPolicyTests: XCTestCase {
    func testTruthTableAllSixCombinations() {
        // (defaultFlip, override, 期望 flips, 期望来源)
        let cases: [(Bool, ScrollRuleMode?, Bool, FlipDecisionSource)] = [
            (true, nil, true, .globalDefault),
            (true, .inherit, true, .globalDefault),
            (true, .forceOn, true, .appOverride(.forceOn)),
            (true, .forceOff, false, .appOverride(.forceOff)),
            (false, nil, false, .globalDefault),
            (false, .inherit, false, .globalDefault),
            (false, .forceOn, true, .appOverride(.forceOn)),
            (false, .forceOff, false, .appOverride(.forceOff)),
        ]
        for (defaultFlip, override, expectedFlips, expectedSource) in cases {
            let decision = FlipPolicy.decide(defaultFlip: defaultFlip, override: override, eventKind: .discrete)
            XCTAssertEqual(decision.flips, expectedFlips,
                           "default=\(defaultFlip) override=\(String(describing: override))")
            XCTAssertEqual(decision.source, expectedSource,
                           "default=\(defaultFlip) override=\(String(describing: override))")
        }
    }

    func testContinuousPassesThroughUnderAllRules() {
        for defaultFlip in [false, true] {
            for override in [ScrollRuleMode?.none, .some(.inherit), .forceOn, .forceOff] {
                let decision = FlipPolicy.decide(defaultFlip: defaultFlip, override: override, eventKind: .continuous)
                XCTAssertFalse(decision.flips,
                               "continuous 必须放行 default=\(defaultFlip) override=\(String(describing: override))")
                XCTAssertEqual(decision.source, .continuousPassthrough)
            }
        }
    }

    func testExplicitOverrideBeatsDefault() {
        // App 的明确设置优先:即使默认开,forceOff 也不翻;默认关,forceOn 也翻
        XCTAssertFalse(FlipPolicy.decide(defaultFlip: true, override: .forceOff, eventKind: .discrete).flips)
        XCTAssertTrue(FlipPolicy.decide(defaultFlip: false, override: .forceOn, eventKind: .discrete).flips)
    }
}
