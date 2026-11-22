import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Live Activity data. Compiled into both the app and the WorkoutLiveActivity widget extension.
struct WorkoutActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Exercise of the next set, or a summary when every set is done.
        var exerciseName: String
        /// e.g. "Set 3 of 5 · 3 reps @ 225 lb"
        var detail: String
        var completedSets: Int
        var totalSets: Int
        /// When the current rest began (last set logged, or workout start).
        var restStartedAt: Date
        /// When the rest target is reached. Nil before the first set and once everything is done.
        var restEndsAt: Date?
        var isComplete: Bool
    }

    var workoutName: String
}

#if canImport(ActivityKit)
@available(iOS 16.1, *)
extension WorkoutActivityAttributes: ActivityAttributes {}
#endif
