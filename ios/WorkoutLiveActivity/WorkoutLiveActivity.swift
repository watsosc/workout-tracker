import ActivityKit
import SwiftUI
import WidgetKit

@main
struct WorkoutLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        WorkoutLiveActivityWidget()
    }
}

struct WorkoutLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color(red: 11 / 255, green: 18 / 255, blue: 32 / 255))
                .activitySystemActionForegroundColor(.green)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("\(context.state.completedSets)/\(context.state.totalSets)", systemImage: "figure.strengthtraining.traditional")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RestTimerText(state: context.state, isStale: context.isStale)
                        .font(.title3.monospacedDigit().weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.state.exerciseName).font(.headline)
                        Text(context.state.detail).font(.subheadline).foregroundStyle(.secondary)
                        RestProgress(state: context.state, isStale: context.isStale)
                    }
                }
            } compactLeading: {
                Image(systemName: "figure.strengthtraining.traditional").foregroundStyle(.green)
            } compactTrailing: {
                RestTimerText(state: context.state, isStale: context.isStale)
                    .monospacedDigit()
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: "timer").foregroundStyle(.green)
            }
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<WorkoutActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(context.attributes.workoutName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(context.state.completedSets)/\(context.state.totalSets) sets")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.exerciseName).font(.headline)
                    Text(context.state.detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                RestTimerText(state: context.state, isStale: context.isStale)
                    .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
            }
            RestProgress(state: context.state, isStale: context.isStale)
        }
        .padding()
        .foregroundStyle(.white)
    }
}

/// Counts down to the rest target; shows "Go" once it's reached (the activity goes stale then).
private struct RestTimerText: View {
    let state: WorkoutActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if state.isComplete {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if let end = state.restEndsAt, !isStale, end > Date() {
            Text(timerInterval: state.restStartedAt...end, countsDown: true)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.green)
        } else if state.restEndsAt != nil {
            Text("Go").foregroundStyle(.orange)
        } else {
            Text("Ready").foregroundStyle(.green)
        }
    }
}

private struct RestProgress: View {
    let state: WorkoutActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if let end = state.restEndsAt, !isStale, end > Date() {
            ProgressView(timerInterval: state.restStartedAt...end, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .tint(.green)
        } else if state.restEndsAt != nil, !state.isComplete {
            Text("Rest's up").font(.caption.weight(.semibold)).foregroundStyle(.orange)
        }
    }
}
