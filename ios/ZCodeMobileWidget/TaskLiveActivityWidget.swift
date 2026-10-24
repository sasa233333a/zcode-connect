import ActivityKit
import SwiftUI
import WidgetKit

@main
struct ZCodeMobileWidgetBundle: WidgetBundle {
    var body: some Widget {
        TaskLiveActivityWidget()
    }
}

struct TaskLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TaskActivityAttributes.self) { context in
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: context.state.symbolName)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(context.state.isWaiting ? .orange : .green)
                    .frame(width: 38, height: 38)
                    .background((context.state.isWaiting ? Color.orange : Color.green).opacity(0.16), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.state.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(context.state.projectName) · \(context.state.hostName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(context.state.statusText)
                        .font(.caption2)
                        .foregroundStyle(context.state.isWaiting ? .orange : .secondary)
                }
                Spacer(minLength: 8)
                Text(timerInterval: context.state.phaseStartedAt...context.state.phaseStartedAt.addingTimeInterval(12 * 60 * 60), countsDown: false)
                    .font(.system(.title3, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .activityBackgroundTint(Color.black.opacity(0.18))
            .widgetURL(URL(string: "zcodemobile://session/\(context.state.sessionID)"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.symbolName)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(context.state.isWaiting ? .orange : .green)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(context.state.title).font(.headline).lineLimit(1)
                        Text(context.state.projectName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.state.phaseStartedAt...context.state.phaseStartedAt.addingTimeInterval(12 * 60 * 60), countsDown: false)
                        .font(.system(.title3, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 12) {
                        Text(context.state.statusText)
                            .font(.caption)
                            .foregroundStyle(context.state.isWaiting ? .orange : .secondary)
                        if context.state.runningCount + context.state.waitingCount > 1 {
                            Text("\(context.state.runningCount) 进行中 · \(context.state.waitingCount) 待确认")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(context.state.hostName).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.symbolName)
                    .foregroundStyle(context.state.isWaiting ? .orange : .green)
            } compactTrailing: {
                Text(timerInterval: context.state.phaseStartedAt...context.state.phaseStartedAt.addingTimeInterval(12 * 60 * 60), countsDown: false)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 42)
            } minimal: {
                Image(systemName: context.state.symbolName)
                    .foregroundStyle(context.state.isWaiting ? .orange : .green)
            }
            .widgetURL(URL(string: "zcodemobile://session/\(context.state.sessionID)"))
        }
    }
}
