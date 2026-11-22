import XCTest
@testable import WorkoutTrackerIOS

@MainActor
final class LiveActivityTests: XCTestCase {
    private var store: OfflineWorkoutStore!

    override func setUp() async throws {
        StubURLProtocol.install()
        StubURLProtocol.handler = { _ in .failure(.notConnectedToInternet) }
        store = OfflineWorkoutStore(fileURL: Fixtures.tempFile())
        store.startWorkout(from: Fixtures.prescription())
    }

    private func state(_ unit: WeightUnit = .kg) -> WorkoutActivityAttributes.ContentState {
        LiveActivityController.contentState(for: store.activeWorkout!, unit: unit)
    }

    func testBeforeFirstSetThereIsNoRestCountdown() {
        let s = state()
        XCTAssertEqual(s.exerciseName, "Squat")
        XCTAssertEqual(s.detail, "Set 1 of 3 · 3 reps @ 100.0 kg")
        XCTAssertNil(s.restEndsAt)
        XCTAssertEqual(s.completedSets, 0)
        XCTAssertEqual(s.totalSets, 5)
    }

    func testAfterASetRestCountsDownToTheNextExercisesTarget() {
        let t0 = Date()
        store.completeSet(at: .init(entryIndex: 0, setIndex: 0), reps: 3, now: t0)
        let s = state()
        XCTAssertEqual(s.restStartedAt, t0)
        XCTAssertEqual(s.restEndsAt, t0.addingTimeInterval(180), "T1 rest is 3 minutes")
        XCTAssertEqual(s.detail, "Set 2 of 3 · 3 reps @ 100.0 kg")
    }

    func testAmrapSetsAndUnitsAreShown() {
        store.completeSet(at: .init(entryIndex: 0, setIndex: 0), reps: 3)
        store.completeSet(at: .init(entryIndex: 0, setIndex: 1), reps: 3)
        XCTAssertTrue(state(.lb).detail.hasPrefix("Set 3 of 3 · 3+ reps @ "))
        XCTAssertTrue(state(.lb).detail.hasSuffix(" lb"))
    }

    func testWeightChangesAndSkipsAreReflected() {
        store.changeWeight(entryIndex: 0, weightKg: 90)
        XCTAssertTrue(state().detail.hasSuffix("@ 90.0 kg"))
        store.skipExercise(entryIndex: 0)
        XCTAssertEqual(state().exerciseName, "Lat Pulldown")
    }

    func testAllDoneAndEmptyWorkouts() {
        while let position = store.activeWorkout?.pendingSetPosition() {
            store.completeSet(at: position, reps: 10)
        }
        let done = state()
        XCTAssertTrue(done.isComplete)
        XCTAssertNil(done.restEndsAt)
        XCTAssertEqual(done.completedSets, 5)

        store.discardActiveWorkout()
        store.startEmptyWorkout(name: "Hotel gym")
        XCTAssertEqual(state().exerciseName, "Add an exercise")
        XCTAssertFalse(state().isComplete)
    }

    func testHeartRateSamplesDoNotChangeTheDisplayedState() {
        let before = state()
        store.appendHeartRate(bpm: 120, at: Date())
        XCTAssertEqual(state(), before, "so per-second heart-rate samples don't spend the update budget")
    }
}
