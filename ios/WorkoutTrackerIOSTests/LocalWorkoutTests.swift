import XCTest
@testable import WorkoutTrackerIOS

@MainActor
final class LocalWorkoutTests: XCTestCase {
    private var store: OfflineWorkoutStore!

    override func setUp() async throws {
        StubURLProtocol.install()
        StubURLProtocol.handler = { _ in .failure(.notConnectedToInternet) }
        store = OfflineWorkoutStore(fileURL: Fixtures.tempFile())
        store.startWorkout(from: Fixtures.prescription())
    }

    private var workout: LocalWorkout { store.activeWorkout! }

    func testPendingSetSkipsCompletedAndSkippedSets() {
        XCTAssertEqual(workout.pendingSetPosition(), .init(entryIndex: 0, setIndex: 0))
        store.completeSet(at: workout.pendingSetPosition()!, reps: 3)
        XCTAssertEqual(workout.pendingSetPosition(), .init(entryIndex: 0, setIndex: 1))
        store.skipExercise(entryIndex: 0)
        XCTAssertEqual(workout.pendingSetPosition(), .init(entryIndex: 1, setIndex: 0))
        XCTAssertTrue(workout.entries[0].isSkipped)
        store.unskipExercise(entryIndex: 0)
        XCTAssertEqual(workout.pendingSetPosition(), .init(entryIndex: 0, setIndex: 1))
    }

    func testUndoReopensTheMostRecentSet() {
        let t0 = Date()
        store.completeSet(at: .init(entryIndex: 0, setIndex: 0), reps: 3, now: t0)
        store.completeSet(at: .init(entryIndex: 0, setIndex: 1), reps: 2, now: t0.addingTimeInterval(120))
        store.undoLastSet()
        XCTAssertNil(workout.entries[0].sets[1].completedAt)
        XCTAssertNil(workout.entries[0].sets[1].repsCompleted)
        XCTAssertEqual(workout.lastSetCompletedAt, t0)
    }

    func testChangeWeightOnlyAffectsRemainingSets() {
        store.completeSet(at: .init(entryIndex: 0, setIndex: 0), reps: 3)
        store.changeWeight(entryIndex: 0, weightKg: 90)
        XCTAssertEqual(workout.entries[0].sets.map(\.weightKg), [100, 90, 90])
    }

    func testAddSetAddExerciseAndSwap() {
        store.addSet(entryIndex: 1)
        XCTAssertEqual(workout.entries[1].sets.map(\.setIndex), [1, 2, 3])
        XCTAssertEqual(workout.entries[1].sets.last?.weightKg, 40)

        store.addExercise(name: "  Plank ", sets: 2, reps: 1, weightKg: 0)
        XCTAssertEqual(workout.entries.last?.exerciseName, "Plank")
        XCTAssertTrue(workout.entries.last!.isAdded)
        XCTAssertEqual(workout.entries.last?.sets.count, 2)

        store.swapExercise(entryIndex: 0, to: "Leg Press")
        XCTAssertEqual(workout.entries[0].exerciseName, "Leg Press")
        XCTAssertEqual(workout.entries[0].planWorkoutExerciseId, 100, "keeps the plan slot it replaced")
        XCTAssertFalse(BarbellMath.usesBarbell(equipment: workout.entries[0].equipmentType, tier: workout.entries[0].tier))
    }

    func testLogWorkoutInputDescribesChanges() throws {
        store.completeSet(at: .init(entryIndex: 0, setIndex: 0), reps: 3)
        store.skipExercise(entryIndex: 0)
        store.addExercise(name: "Plank", sets: 1, reps: 1, weightKg: 0)
        let input = workout.logWorkoutInput()

        XCTAssertEqual(input["planWorkoutId"] as? Int, 10)
        XCTAssertEqual(input["name"] as? String, "Day A")
        let entries = try XCTUnwrap(input["entries"] as? [[String: Any]])
        XCTAssertEqual(entries[0]["planWorkoutExerciseId"] as? Int, 100)
        XCTAssertEqual(entries[0]["exerciseName"] as? String, "Squat")
        let squatSets = try XCTUnwrap(entries[0]["sets"] as? [[String: Any]])
        XCTAssertEqual(squatSets.map { $0["completed"] as? Bool }, [true, false, false])
        XCTAssertEqual(squatSets.map { $0["skipped"] as? Bool }, [false, true, true])
        XCTAssertNil(entries[2]["planWorkoutExerciseId"], "added exercises have no plan slot")
        XCTAssertEqual(entries[2]["exerciseName"] as? String, "Plank")
    }

    func testEmptyWorkoutHasNoPlan() {
        store.discardActiveWorkout()
        store.startEmptyWorkout(name: "Hotel gym")
        XCTAssertNil(workout.planWorkoutId)
        XCTAssertNil(workout.logWorkoutInput()["planWorkoutId"])
        XCTAssertEqual(workout.workoutName, "Hotel gym")
        XCTAssertNil(workout.pendingSetPosition())
    }

    /// A workout saved by the previous app version (no `skipped`/`localId`) must still load.
    func testDecodesWorkoutSavedByOlderVersion() throws {
        let old = """
        {"activeWorkout": {"clientId": "abc", "planWorkoutId": 10, "planName": "Plan", "workoutName": "Day A",
          "startedAt": 0, "heartRateSamples": [], "entries": [
            {"planWorkoutExerciseId": 100, "exerciseId": 1, "exerciseName": "Squat", "plannedSets": 1, "plannedReps": 3,
             "plannedWeightKg": 100, "progressionProtocol": "GZCLP_T1", "tier": "T1", "expectedRestSeconds": 180,
             "sets": [{"setIndex": 1, "targetReps": 3, "isAmrap": false, "weightKg": 100, "repsCompleted": 3, "completedAt": 10}]}
          ]},
         "outbox": [], "noActivePlan": false}
        """
        let file = Fixtures.tempFile()
        try Data(old.utf8).write(to: file)
        let reloaded = OfflineWorkoutStore(fileURL: file)
        let workout = try XCTUnwrap(reloaded.activeWorkout)
        XCTAssertEqual(workout.entries[0].sets[0].repsCompleted, 3)
        XCTAssertFalse(workout.entries[0].sets[0].skipped)
        XCTAssertEqual(reloaded.exerciseNames, [])
    }
}
