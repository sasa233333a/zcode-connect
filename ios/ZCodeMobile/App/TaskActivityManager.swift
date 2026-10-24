import ActivityKit
import Foundation

/// Maintains one aggregate Live Activity for the task that most needs the
/// user's attention. Timers are rendered by the widget itself, so the Dynamic
/// Island keeps counting even after iOS suspends the app; real status updates
/// still require the app to be running (or a future push service).
@MainActor
final class TaskActivityManager {
    static let shared = TaskActivityManager()

    private var activity: Activity<TaskActivityAttributes>?
    private var focusID: String?
    private var phaseStartedAt: Date?
    private var lastSignature: String?
    private var endTask: Task<Void, Never>?

    /// ActivityKit classes are safe to drive from the main actor but are not
    /// annotated Sendable, so an await in a task needs this explicit handoff.
    private struct ActivityBox: @unchecked Sendable {
        let value: Activity<TaskActivityAttributes>
    }

    private init() {}

    func sync(sessions: [RemoteSession], hostName: String, enabled: Bool, activeSessionID: String?) {
        // Connection setup clears sessions briefly before the first index load.
        // Keep the existing activity through that gap instead of flickering away.
        endTask?.cancel()
        endTask = nil
        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled else {
            end()
            return
        }
        let live = sessions.filter { !$0.isArchived && ($0.status == .running || $0.status == .waiting) }
        guard let focus = focusTask(in: live) else {
            end()
            return
        }
        if activity == nil { activity = Activity<TaskActivityAttributes>.activities.first }
        if focusID != focus.id {
            focusID = focus.id
            phaseStartedAt = .now
        }
        let running = live.filter { $0.status == .running }.count
        let waiting = live.filter { $0.status == .waiting }.count
        let state = TaskActivityAttributes.ContentState(
            sessionID: focus.id,
            title: focus.title,
            projectName: focus.projectName,
            hostName: hostName,
            phase: focus.status == .waiting ? "waiting" : "running",
            phaseStartedAt: phaseStartedAt ?? .now,
            runningCount: running,
            waitingCount: waiting
        )
        let signature = [state.sessionID, state.phase, state.title, state.projectName, state.hostName,
                         String(state.runningCount), String(state.waitingCount),
                         String(state.phaseStartedAt.timeIntervalSince1970)].joined(separator: "|")
        guard signature != lastSignature else { return }
        lastSignature = signature
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(15 * 60))
        if let activity {
            let box = ActivityBox(value: activity)
            #if DEBUG
            RelayTestLog.write("activity update \(state.phase) \(state.title) running=\(state.runningCount) waiting=\(state.waitingCount)")
            #endif
            Task { await box.value.update(content) }
        } else {
            do {
                activity = try Activity.request(attributes: TaskActivityAttributes(), content: content, pushType: nil)
                #if DEBUG
                RelayTestLog.write("activity request ok \(state.phase) \(state.title)")
                #endif
            } catch {
                // Live Activities can be disabled by the system or the user; the
                // in-app banner and local notifications remain available.
                activity = nil
                #if DEBUG
                RelayTestLog.write("activity request failed \(error.localizedDescription)")
                #endif
            }
        }
    }

    private func end() {
        guard activity != nil, endTask == nil else { return }
        endTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            self.finishEnd()
        }
    }

    private func finishEnd() {
        guard !Task.isCancelled else { return }
        endTask = nil
        let current = activity
        activity = nil
        focusID = nil
        phaseStartedAt = nil
        lastSignature = nil
        guard let current else { return }
        #if DEBUG
        RelayTestLog.write("activity end")
        #endif
        let box = ActivityBox(value: current)
        Task { await box.value.end(nil, dismissalPolicy: .immediate) }
    }

    private func focusTask(in sessions: [RemoteSession]) -> RemoteSession? {
        let waiting = sessions.filter { $0.status == .waiting }.max { $0.updatedAt < $1.updatedAt }
        return waiting ?? sessions.filter { $0.status == .running }.max { $0.updatedAt < $1.updatedAt }
    }
}
