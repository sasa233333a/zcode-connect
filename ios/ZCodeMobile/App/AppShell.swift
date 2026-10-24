import SwiftUI
import UIKit

struct AppShell: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var body: some View {
        @Bindable var store = store
        Group {
            if usesPadLayout {
                PadShell()
            } else {
                phoneShell(path: $store.path)
            }
        }
        .modifier(FloatingPanelOverlay())
        .sheet(item: $store.sheet) { destination in
            switch destination {
            case .connections: ConnectionsView()
            case .settings: SettingsView()
            case .pairing: PairingView()
            case .advanced: AdvancedSettingsView()
            case .files(let id, let modified): FilesView(sessionID: id, initiallyModified: modified)
            case .agent(let agent): AgentDetailView(agent: agent)
            case .voice: VoiceCaptureView()
            case .mirror: MirrorSheet()
            }
        }
        .alert("暂时无法完成", isPresented: Binding(
            get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .overlay(alignment: .top) {
            if let toast = store.toast {
                Text(toast).font(.subheadline).padding(.horizontal, 18).padding(.vertical, 12)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.top, 8).transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false).accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.toast)
        .task {
            store.notificationEventSink = { event in
                Task { await TaskNotifications.shared.post(event) }
            }
            store.activitySyncSink = { [weak store] in
                guard let store else { return }
                Self.syncLiveActivity(for: store)
            }
            store.activityEndSink = {
                TaskActivityManager.shared.endImmediately()
            }
            await store.start()
            syncLiveActivity()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--mirror-auto") { store.sheet = .mirror }
            #endif
        }
        .task {
            #if DEBUG
            guard ProcessInfo.processInfo.arguments.contains("--pad-landscape-review") else { return }
            try? await Task.sleep(for: .seconds(1))
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in }
            }
            #endif
        }
        .task {
            #if DEBUG
            guard ProcessInfo.processInfo.arguments.contains("--performance-probe") else { return }
            MotionPerformanceProbe.shared.start(sessionName: "scroll-review", metadata: ["configuration": "Debug", "arguments": ProcessInfo.processInfo.arguments.filter { $0.hasPrefix("--") }.joined(separator: " ")])
            do {
                try await Task.sleep(for: .seconds(60))
                try await MotionPerformanceProbe.shared.stopAndWrite(to: URL.documentsDirectory.appending(path: "scroll-probe.json"))
            } catch { MotionPerformanceProbe.shared.stopWithoutWriting() }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                TaskNotifications.shared.endBackgroundWindow()
                if store.completionNotifications, store.hasConnectedBefore, !isRelayTestRun {
                    Task { await TaskNotifications.shared.requestAuthorizationIfNeeded() }
                }
                Task { await store.applicationDidBecomeActive() }
            } else if phase == .background {
                store.applicationDidEnterBackground()
                TaskNotifications.shared.beginBackgroundWindowIfRunning()
            }
            syncLiveActivity()
        }
        .onChange(of: store.sessions) { _, _ in syncLiveActivity() }
        .onChange(of: store.pendingInteractions.mapValues(\.count)) { _, _ in syncLiveActivity() }
        .onChange(of: store.connection) { _, _ in syncLiveActivity() }
        .onChange(of: store.hostName) { _, _ in syncLiveActivity() }
        .onChange(of: store.liveActivitiesEnabled) { _, _ in
            store.savePreferences()
            syncLiveActivity()
        }
        .onChange(of: store.hasConnectedBefore) { _, connected in
            if connected, store.completionNotifications, !isRelayTestRun {
                Task { await TaskNotifications.shared.requestAuthorizationIfNeeded() }
            }
        }
        .onChange(of: store.completionNotifications) { _, enabled in
            if enabled, !isRelayTestRun {
                Task { await TaskNotifications.shared.requestAuthorizationIfNeeded() }
            }
        }
        .onOpenURL { store.openDeepLink($0) }
    }

    private var usesPadLayout: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
            && horizontalSizeClass == .regular
            && !store.requiresInitialConnection
            && !store.isReferenceMode
    }

    private func phoneShell(path: Binding<[AppRoute]>) -> some View {
        NavigationStack(path: path) {
            Group {
                if store.requiresInitialConnection {
                    PairingView(embedded: true, onboarding: true)
                } else {
                    HomeView()
                }
            }
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .session(let id): ChatView(sessionID: id)
                case .newSession: NewSessionView()
                }
            }
        }
    }

    private var isRelayTestRun: Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--relay-test-pair") || arguments.contains("--relay-test-discover")
            || arguments.contains("--live-activity-review") || arguments.contains("--onboarding-review")
        #else
        return false
        #endif
    }

    private func syncLiveActivity() {
        Self.syncLiveActivity(for: store)
    }

    private static func syncLiveActivity(for store: AppStore) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--live-activity-review") {
            TaskActivityManager.shared.sync(sessions: [
                RemoteSession(id: "review-waiting", title: "整理项目步骤与目录",
                              projectID: "review-project", projectName: "zocode-connect",
                              updatedAt: .now, status: .waiting),
                RemoteSession(id: "review-running", title: "适配 zcode-connect 并打包 iOS",
                              projectID: "review-project", projectName: "zocode-connect",
                              updatedAt: .now.addingTimeInterval(-30), status: .running)
            ], hostName: "Review MacBook", enabled: true, activeSessionID: nil)
            return
        }
        #endif
        let waitingIDs = Set(store.pendingInteractions.compactMap { key, value in value.isEmpty ? nil : key })
        let sessions = store.sessions.map { session -> RemoteSession in
            guard waitingIDs.contains(session.id), session.status == .running else { return session }
            var session = session
            session.status = .waiting
            return session
        }
        let live = store.liveActivitiesEnabled && !store.isReferenceMode
            && (store.connection.isOnline || store.isAutoReconnecting)
        TaskActivityManager.shared.sync(sessions: sessions, hostName: store.hostName,
                                        enabled: live, activeSessionID: store.currentSessionID)
    }
}
