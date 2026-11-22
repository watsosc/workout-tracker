import ActivityKit
import SwiftUI
import WidgetKit

// Lock screen + Dynamic Island, in the app's Edgerunners theme (Shared/Theme.swift).
// The countdown keeps the rest clock's retro system green.

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
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(Neon.yellow)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text("⚡ \(context.state.completedSets)/\(context.state.totalSets) SETS")
                        .font(Neon.mono(12))
                        .foregroundStyle(Neon.yellow)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RestTimerText(state: context.state, isStale: context.isStale)
                        .font(Neon.mono(22))
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.state.exerciseName.uppercased())
                            .font(Neon.head(20, .bold))
                            .tracking(1)
                            .foregroundStyle(Neon.white)
                        Text(context.state.detail.uppercased())
                            .font(Neon.mono(12))
                            .foregroundStyle(Neon.muted)
                        RestProgress(state: context.state, isStale: context.isStale)
                            .padding(.top, 4)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: "bolt.fill").foregroundStyle(Neon.yellow)
            } compactTrailing: {
                RestTimerText(state: context.state, isStale: context.isStale)
                    .font(Neon.mono(15))
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: "bolt.fill").foregroundStyle(Neon.yellow)
            }
            .keylineTint(Neon.yellow)
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<WorkoutActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(context.attributes.workoutName.uppercased())
                Spacer()
                Text("\(context.state.completedSets)/\(context.state.totalSets) SETS")
            }
            .font(Neon.mono(11))
            .tracking(1.6)
            .foregroundStyle(Neon.muted)

            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.exerciseName.uppercased())
                        .font(Neon.head(24, .bold))
                        .tracking(1)
                        .foregroundStyle(Neon.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(context.state.detail.uppercased())
                        .font(Neon.mono(12))
                        .foregroundStyle(Neon.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer()
                RestTimerText(state: context.state, isStale: context.isStale)
                    .font(Neon.mono(44))
            }

            RestProgress(state: context.state, isStale: context.isStale)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Neon.ink.opacity(0.94), in: CutCornerShape(cut: 18))
        .overlay(CutCornerShape(cut: 18).strokeBorder(Neon.heroEdge, lineWidth: 1))
    }
}

/// Counts down to the rest target; "GO" once reached (the activity goes stale then).
private struct RestTimerText: View {
    let state: WorkoutActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if state.isComplete {
            Image(systemName: "checkmark").foregroundStyle(Neon.yellow)
        } else if let end = state.restEndsAt, !isStale, end > Date() {
            Text(timerInterval: state.restStartedAt...end, countsDown: true)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .foregroundStyle(Neon.clockGreen)
        } else if state.restEndsAt != nil {
            Text("GO").foregroundStyle(Neon.pink)
        } else {
            Text("READY").foregroundStyle(Neon.clockGreen)
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
            .tint(Neon.yellow)
        } else if state.restEndsAt != nil, !state.isComplete {
            Text("REST'S UP // NEXT SET")
                .font(Neon.mono(12))
                .tracking(1.4)
                .foregroundStyle(Neon.pink)
        }
    }
}
