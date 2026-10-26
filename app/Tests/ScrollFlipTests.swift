import XCTest
@testable import WheelFlip

final class ScrollFlipTests: XCTestCase {
    func testContinuousPassesThrough() {
        let fields = ScrollFields(
            isContinuous: true,
            deltaAxis1: 3, deltaAxis2: 1,
            pointDeltaAxis1: 30, pointDeltaAxis2: 10,
            fixedPtDeltaAxis1: 3.5, fixedPtDeltaAxis2: 1.5
        )
        XCTAssertNil(ScrollFlip.flipped(fields))
    }

    func testDiscreteFlipsAllSixFields() throws {
        let fields = ScrollFields(
            isContinuous: false,
            deltaAxis1: 3, deltaAxis2: -2,
            pointDeltaAxis1: 30, pointDeltaAxis2: -20,
            fixedPtDeltaAxis1: 3.5, fixedPtDeltaAxis2: -2.5
        )
        let flipped = try XCTUnwrap(ScrollFlip.flipped(fields))
        XCTAssertEqual(flipped.deltaAxis1, -3)
        XCTAssertEqual(flipped.deltaAxis2, 2)
        XCTAssertEqual(flipped.pointDeltaAxis1, -30)
        XCTAssertEqual(flipped.pointDeltaAxis2, 20)
        XCTAssertEqual(flipped.fixedPtDeltaAxis1, -3.5)
        XCTAssertEqual(flipped.fixedPtDeltaAxis2, 2.5)
    }

    func testFlippingTwiceReturnsOriginal() throws {
        let fields = ScrollFields(
            isContinuous: false,
            deltaAxis1: 5, deltaAxis2: 7,
            pointDeltaAxis1: 50, pointDeltaAxis2: 70,
            fixedPtDeltaAxis1: 5.25, fixedPtDeltaAxis2: 7.75
        )
        let once = try XCTUnwrap(ScrollFlip.flipped(fields))
        let twice = try XCTUnwrap(ScrollFlip.flipped(once))
        XCTAssertEqual(twice, fields)
    }

    func testZeroDeltaStaysZero() throws {
        let fields = ScrollFields(
            isContinuous: false,
            deltaAxis1: 0, deltaAxis2: 0,
            pointDeltaAxis1: 0, pointDeltaAxis2: 0,
            fixedPtDeltaAxis1: 0, fixedPtDeltaAxis2: 0
        )
        let flipped = try XCTUnwrap(ScrollFlip.flipped(fields))
        XCTAssertEqual(flipped, fields)
    }
}
