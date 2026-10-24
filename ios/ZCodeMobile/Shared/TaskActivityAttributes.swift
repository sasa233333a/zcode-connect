import ActivityKit
import Foundation

/// Shared by the app and the Live Activity extension. The app keeps one
/// aggregate activity for the most important running task, so switching focus
/// updates the same Dynamic Island instead of stacking activities.
struct TaskActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var sessionID: String
        var title: String
        var projectName: String
        var hostName: String
        var phase: String
        var phaseStartedAt: Date
        var runningCount: Int
        var waitingCount: Int

        var isWaiting: Bool { phase == "waiting" }
        var statusText: String { isWaiting ? "等待你的确认" : "电脑上正在运行" }
        var symbolName: String { isWaiting ? "exclamationmark.circle.fill" : "hourglass" }
    }
}
