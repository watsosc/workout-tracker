import Foundation
@testable import WorkoutTrackerIOS

enum Fixtures {
    /// Day A: Squat 3x3 (last set AMRAP) and Lat Pulldown 2x10.
    static func prescription() -> WorkoutPrescription {
        WorkoutPrescription(
            planId: 1,
            planName: "Plan",
            planWorkoutId: 10,
            workoutName: "Day A",
            sequenceIndex: 0,
            week: 1,
            blockedReason: nil,
            entries: [
                PrescribedEntry(
                    planWorkoutExerciseId: 100, exerciseId: 1, exerciseName: "Squat", plannedSets: 3, plannedReps: 3,
                    plannedWeightKg: 100, progressionProtocol: .gzclpT1, tier: "T1", equipmentType: nil, expectedRestSeconds: 180,
                    sets: (1...3).map { PrescribedSet(setIndex: $0, targetReps: 3, isAmrap: $0 == 3, weightKg: 100) }
                ),
                PrescribedEntry(
                    planWorkoutExerciseId: 101, exerciseId: 2, exerciseName: "Lat Pulldown", plannedSets: 2, plannedReps: 10,
                    plannedWeightKg: 40, progressionProtocol: .basic, tier: nil, equipmentType: "CABLE", expectedRestSeconds: 90,
                    sets: (1...2).map { PrescribedSet(setIndex: $0, targetReps: 10, isAmrap: false, weightKg: 40) }
                )
            ]
        )
    }

    static func sessionJSON(id: Int = 7, records: [[String: Any]] = []) -> [String: Any] {
        [
            "id": id, "status": "COMPLETED", "startedAt": "2026-01-05T18:00:00", "finishedAt": "2026-01-05T18:45:00",
            "heartRateSampleCount": 0, "avgHeartRateBpm": NSNull(), "maxHeartRateBpm": NSNull(),
            "stravaExportStatus": NSNull(), "stravaActivityId": NSNull(), "stravaActivityUrl": NSNull(), "stravaLastError": NSNull(),
            "planWorkoutId": 10, "planWorkoutName": "Day A", "entries": [], "personalRecords": records
        ]
    }

    static func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString).json")
    }
}

@MainActor
func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
