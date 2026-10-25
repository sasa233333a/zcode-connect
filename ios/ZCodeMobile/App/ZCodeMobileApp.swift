import SwiftUI

@main
struct ZCodeMobileApp: App {
    @State private var store: AppStore
    private static func makeStore() -> AppStore {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--onboarding-review"),
           let defaults = UserDefaults(suiteName: "dev.paco.zcode.mobile.onboarding-review") {
            return AppStore(defaults: defaults)
        }
        #endif
        return AppStore()
    }
    init() {
        _store = State(initialValue: Self.makeStore())
    }
    var body: some Scene {
        WindowGroup {
            rootView
                .environment(store)
                .tint(ZTheme.accent)
                .preferredColorScheme(store.appearance == "浅色" ? .light : store.appearance == "深色" ? .dark : nil)
        }
    }
    @ViewBuilder private var rootView: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("material-calibration") { GlassCalibrationView() }
        else { AppShell() }
        #else
        AppShell()
        #endif
    }
}
