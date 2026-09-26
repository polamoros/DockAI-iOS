import ActivityKit
import SwiftUI
import WidgetKit

/// The Live Activity for a run: the lock screen banner and the Dynamic Island.
/// Started and updated by the app (RunActivityController); the server does
/// not push Live Activity updates yet.
struct RunActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RunActivityAttributes.self) { context in
            RunLockScreenView(attributes: context.attributes, state: context.state)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.projectName, systemImage: "shippingbox").font(.caption).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RunStatusLabel(state: context.state).font(.caption)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title).font(.caption.weight(.semibold)).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.state.lastLine.isEmpty ? "…" : context.state.lastLine)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        RunElapsed(state: context.state).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: context.state.symbol).foregroundStyle(statusColor(context.state))
            } compactTrailing: {
                if context.state.finished { Text(context.state.statusText).font(.caption2) }
                else { RunElapsed(state: context.state).font(.caption2.monospacedDigit()).frame(maxWidth: 44) }
            } minimal: {
                Image(systemName: context.state.symbol).foregroundStyle(statusColor(context.state))
            }
            .widgetURL(URL(string: "dockai://project/\(context.attributes.slug)"))
        }
    }
}

private func statusColor(_ s: RunActivityAttributes.ContentState) -> Color {
    switch s.status { case "completed": .green; case "failed": .red; case "canceled": .secondary; default: .accentColor }
}

private struct RunStatusLabel: View {
    let state: RunActivityAttributes.ContentState
    var body: some View {
        Label(state.statusText, systemImage: state.symbol).foregroundStyle(statusColor(state))
    }
}

/// Seconds counting up while running; the total once finished.
private struct RunElapsed: View {
    let state: RunActivityAttributes.ContentState
    var body: some View {
        if let end = state.finishedAt {
            Text(Duration.seconds(max(0, end.timeIntervalSince(state.startedAt))).formatted(.time(pattern: .minuteSecond)))
        } else {
            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
        }
    }
}

private struct RunLockScreenView: View {
    let attributes: RunActivityAttributes
    let state: RunActivityAttributes.ContentState
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(attributes.title).font(.headline).lineLimit(1)
                    Text(attributes.projectName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    RunStatusLabel(state: state).font(.subheadline.weight(.medium))
                    RunElapsed(state: state).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Text(state.lastLine.isEmpty ? "Waiting for the first line…" : state.lastLine)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}
