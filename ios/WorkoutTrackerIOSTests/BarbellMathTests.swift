import XCTest
@testable import WorkoutTrackerIOS

// Mirrors web/src/lib/barbell.test.ts so both platforms agree.
final class BarbellMathTests: XCTestCase {
    func testPlatesLargestFirst() {
        XCTAssertEqual(BarbellMath.platesPerSide(total: 225, unit: .lb)?.plates, [45, 45])
        XCTAssertEqual(BarbellMath.platesPerSide(total: 100, unit: .kg)?.plates, [25, 15])
        XCTAssertEqual(BarbellMath.platesPerSide(total: 45, unit: .lb)?.plates, [])
        XCTAssertNil(BarbellMath.platesPerSide(total: 30, unit: .lb))
    }

    func testUnloadableRemainderIsReported() {
        XCTAssertEqual(BarbellMath.platesPerSide(total: 137.5, unit: .lb)?.remainder, 1.25)
        XCTAssertEqual(BarbellMath.formatPlates(total: 227.5, unit: .lb), "45 + 45 /side (+1.25 short)")
        XCTAssertEqual(BarbellMath.formatPlates(total: 45, unit: .lb), "Empty bar")
    }

    func testWarmupRamp() {
        XCTAssertEqual(
            BarbellMath.warmupSets(working: 225, unit: .lb),
            [WarmupSet(weight: 45, reps: 10), WarmupSet(weight: 90, reps: 5), WarmupSet(weight: 135, reps: 3), WarmupSet(weight: 180, reps: 2)]
        )
        XCTAssertEqual(BarbellMath.warmupSets(working: 50, unit: .lb), [])
        let light = BarbellMath.warmupSets(working: 75, unit: .lb)
        XCTAssertEqual(light.first, WarmupSet(weight: 45, reps: 10))
        XCTAssertTrue(zip(light, light.dropFirst()).allSatisfy { $0.weight < $1.weight })
        XCTAssertTrue(light.allSatisfy { $0.weight < 75 })
    }

    func testUsesBarbell() {
        XCTAssertTrue(BarbellMath.usesBarbell(equipment: "BARBELL", tier: "T3"))
        XCTAssertFalse(BarbellMath.usesBarbell(equipment: "DUMBBELL", tier: "T1"))
        XCTAssertTrue(BarbellMath.usesBarbell(equipment: nil, tier: "T2"))
        XCTAssertFalse(BarbellMath.usesBarbell(equipment: nil, tier: nil))
    }
}
