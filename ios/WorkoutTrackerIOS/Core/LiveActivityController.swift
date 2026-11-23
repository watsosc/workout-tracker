import ActivityKit
import Foundation

/// Mirrors the on-device workout onto a Live Activity (lock screen + Dynamic Island).
///
/// Driven entirely by local state, so it works offline. Only pushes an update when the displayed
/// content changes (not on every heart-rate sample), which keeps within ActivityKit's update budget.
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    private var lastState: WorkoutActivityAttributes.ContentState?
    private var lastWorkoutId: String?

    /// What the Live Activity should show for a workout. Pure, so it's unit-tested.
    static func contentState(for workout: LocalWorkout, unit: WeightUnit) -> WorkoutActivityAttributes.ContentState {
        let completed = workout.completedSetCount
        let total = workout.totalSetCount
        let restStart = workout.restStart ?? workout.startedAt

        guard let position = workout.pendingSetPosition() else {
            return .init(
                exerciseName: workout.entries.isEmpty ? "Add an exercise" : "All sets complete",
                detail: workout.entries.isEmpty ? workout.workoutName : "Finish the workout in the app",
                completedSets: completed,
                totalSets: total,
                restStartedAt: restStart,
                restEndsAt: nil,
                isComplete: !workout.entries.isEmpty
            )
        }

        let entry = workout.entries[position.entryIndex]
        let set = entry.sets[position.setIndex]
        let reps = "\(set.targetReps ?? entry.plannedReps)\(set.isAmrap ? "+" : "")"
        let weight = "\(WeightMath.displayWeightFromKg(set.weightKg, unit: unit)) \(unit.label)"
        // Before the first set there's no rest to count down.
        let restEnds = workout.lastSetCompletedAt.map { $0.addingTimeInterval(TimeInterval(entry.restTargetSeconds)) }
        return .init(
            exerciseName: entry.exerciseName,
            detail: "Set \(set.setIndex) of \(entry.sets.count) · \(reps) reps @ \(weight)",
            completedSets: completed,
            totalSets: total,
            restStartedAt: restStart,
            restEndsAt: restEnds,
            isComplete: false
        )
    }

    func sync(workout: LocalWorkout?, unit: WeightUnit) {
        guard let workout else {
            lastState = nil
            lastWorkoutId = nil
            endAll()
            return
        }
        let state = Self.contentState(for: workout, unit: unit)
        guard state != lastState || workout.clientId != lastWorkoutId else { return }
        lastState = state
        lastWorkoutId = workout.clientId
        apply(state, workoutName: workout.workoutName)
    }

    private func apply(_ state: WorkoutActivityAttributes.ContentState, workoutName: String) {
        // A rest that's over is shown as stale ("Rest's up") by the widget.
        let content = ActivityContent(state: state, staleDate: state.restEndsAt)
        let existing = Activity<WorkoutActivityAttributes>.activities
        if let current = existing.first(where: { $0.attributes.workoutName == workoutName && $0.activityState == .active }) {
            Task { await current.update(content) }
            for other in existing where other.id != current.id {
                Task { await other.end(nil, dismissalPolicy: .immediate) }
            }
            return
        }
        for other in existing {
            Task { await other.end(nil, dismissalPolicy: .immediate) }
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            _ = try Activity.request(
                attributes: WorkoutActivityAttributes(workoutName: workoutName),
                content: content,
                pushType: nil
            )
        } catch {
            // Live Activities are a nice-to-have; the workout itself is unaffected.
        }
    }

    private func endAll() {
        for activity in Activity<WorkoutActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
