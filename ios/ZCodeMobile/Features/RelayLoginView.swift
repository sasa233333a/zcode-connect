import SwiftUI
import SafariServices

/// Account login for the current relay protocol. Authorization happens in the
/// system browser; the short-lived polling credential stays inside this view's
/// task and the resulting account JWT is written only to the keychain.
@MainActor
struct RelayLoginView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var flow: RelayLoginFlow?
    @State private var provider: RelayAccountProvider?
    @State private var showBrowser = false
    @State private var starting = false
    @State private var failure: String?
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(ZTheme.accent)
                    .padding(.top, 12)
                Text("登录 ZCode 账号").font(.title2.weight(.semibold))
                Text("手机和电脑需要登录同一账号。登录只用于授权这台手机控制电脑，任务仍然在电脑上运行。")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let failure {
                    Text(failure).font(.subheadline).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                if let flow, let provider {
                    Button {
                        showBrowser = true
                    } label: {
                        Label("打开 \(provider.shortLabel) 登录页面", systemImage: "safari")
                    }.buttonStyle(.borderedProminent)
                    ProgressView("等待浏览器完成登录…").font(.footnote)
                    Text("如果浏览器没有自动返回，完成登录后回到这里即可。")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Link("在 Safari 中打开", destination: flow.authorizeURL)
                        .font(.footnote)
                    Button("换一个账号类型") { restart() }
                        .font(.footnote)
                } else {
                    Text("请选择电脑上 ZCode 使用的账号类型。两者账号不互通。")
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    ForEach(RelayAccountProvider.allCases, id: \.self) { choice in
                        Button {
                            Task { await begin(choice) }
                        } label: {
                            HStack {
                                if starting, provider == choice { ProgressView().padding(.trailing, 6) }
                                Text("使用 \(choice.label) 登录")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(starting)
                    }
                }
                Spacer()
            }
            .padding(24)
            .navigationTitle("账号登录").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { pollTask?.cancel(); dismiss() }
                }
            }
        }
        .sheet(isPresented: $showBrowser) {
            if let flow { SafariView(url: flow.authorizeURL).ignoresSafeArea() }
        }
        .onDisappear { pollTask?.cancel() }
    }

    private func restart() {
        pollTask?.cancel(); pollTask = nil
        flow = nil; provider = nil; failure = nil; showBrowser = false
    }

    private func begin(_ choice: RelayAccountProvider) async {
        guard !starting else { return }
        starting = true; failure = nil; provider = choice
        defer { starting = false }
        do {
            let started = try await RelayAccountService.shared.beginLogin(provider: choice)
            flow = started
            showBrowser = true
            pollTask?.cancel()
            pollTask = Task { await poll(started) }
        } catch {
            if !(error is CancellationError) {
                failure = accountMessage(error)
                provider = nil
            }
        }
    }

    private func poll(_ flow: RelayLoginFlow) async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(flow.pollInterval)) } catch { return }
            if Task.isCancelled { return }
            do {
                if let account = try await RelayAccountService.shared.poll(flow) {
                    do { try RelayAccountService.store(account) }
                    catch { failure = accountMessage(error); return }
                    store.setRelayAccount(account)
                    dismiss()
                    return
                }
            } catch {
                if error is CancellationError { return }
                failure = accountMessage(error)
                return
            }
        }
    }

    private func accountMessage(_ error: Error) -> String {
        (error as? RelayFailure)?.message ?? error.localizedDescription
    }
}

@MainActor
private struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .close
        controller.preferredControlTintColor = UIColor(ZTheme.accent)
        return controller
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
