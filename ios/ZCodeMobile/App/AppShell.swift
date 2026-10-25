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
            await store.start()
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
                Task { await store.applicationDidBecomeActive(); await store.resumeConnectionIfNeeded() }
            } else if phase == .background {
                store.applicationDidEnterBackground()
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
}
