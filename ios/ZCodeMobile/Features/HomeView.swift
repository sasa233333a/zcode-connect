import SwiftUI

struct HomeView: View {
    @Environment(AppStore.self) private var store
    @State private var search = ""
    @State private var collapsed: Set<String> = []
    @State private var selectedDeviceID: String?
    @State private var renameSession: RemoteSession?
    @State private var renameText = ""
    @State private var renameScope: String?
    @State private var confirmRelayReconnect = false
    @State private var connectRequest: ConnectRequest?
    @State private var switchingSessionID: String?

    private struct SessionRowIdentity: Hashable {
        var scope: String
        var sessionID: String
        var actions: [SessionContextAction.AccessibilityIdentity]
    }

    private struct HomeSection: Identifiable {
        var id: String
        var device: HomeDeviceGroup
        var workspace: HomeWorkspaceGroup
        var projectName: String
        var projectKey: String
        var sessions: [RemoteSession]
    }

    private struct ConnectRequest: Identifiable {
        let id = UUID()
        var profile: ConnectionProfile
        var deviceName: String
        var workspaceTitle: String
    }

    private var connectionScope: String {
        "\(store.isReferenceMode)|\(store.activeProfileID ?? "")|\(store.activeProfile?.baseURL ?? "")"
    }

    private var selectedDevice: HomeDeviceGroup? {
        guard let selectedDeviceID else { return nil }
        return store.homeDeviceGroups.first { $0.id == selectedDeviceID }
    }

    private var visibleDevices: [HomeDeviceGroup] {
        let devices = store.homeDeviceGroups
        guard let selectedDeviceID else { return devices }
        return devices.filter { $0.id == selectedDeviceID }
    }

    private var sections: [HomeSection] {
        var result: [HomeSection] = []
        for device in visibleDevices {
            for workspace in device.workspaces {
                let visible = workspace.sessions.filter { session in
                    guard session.isArchived == store.showArchived else { return false }
                    guard !search.isEmpty else { return true }
                    return session.title.localizedStandardContains(search)
                        || session.projectName.localizedStandardContains(search)
                        || device.name.localizedStandardContains(search)
                        || workspace.title.localizedStandardContains(search)
                }
                let grouped = Dictionary(grouping: visible) { session in
                    let project = session.projectID.isEmpty ? session.projectName : session.projectID
                    return workspace.id + "|" + project
                }
                for (key, items) in grouped {
                    let project = workspace.projects.first { $0.id == items.first?.projectID }
                    let name = items.first?.projectName ?? project?.name ?? workspace.title
                    result.append(HomeSection(id: key, device: device, workspace: workspace,
                                              projectName: name, projectKey: key, sessions: items))
                }
            }
        }
        return result.sorted { lhs, rhs in
            let left = lhs.sessions.map(\.updatedAt).max() ?? .distantPast
            let right = rhs.sessions.map(\.updatedAt).max() ?? .distantPast
            if left != right { return left > right }
            return lhs.projectName.localizedStandardCompare(rhs.projectName) == .orderedAscending
        }
    }

    private func orderedSessions(_ sessions: [RemoteSession]) -> [RemoteSession] {
        sessions.sorted { a, b in
            if store.sortOrder == .priority {
                if a.status == .waiting && b.status != .waiting { return true }
                if b.status == .waiting && a.status != .waiting { return false }
                if a.isPinned != b.isPinned { return a.isPinned }
            }
            return a.updatedAt > b.updatedAt
        }
    }

    private func menuItems(for session: RemoteSession, active: Bool = true) -> [SessionMenuItem] {
        var items = SessionMenuPolicy.items(for: session, isReferenceMode: store.isReferenceMode,
                                            isRelay: store.activeProfile?.isRelay == true,
                                            isOnline: store.connection.isOnline, isUnread: store.isUnread(session.id))
        if !active {
            items = items.map { item in
                var item = item
                item.isEnabled = item.id == .copyID
                return item
            }
        }
        return items
    }

    private func beginRename(_ session: RemoteSession) {
        guard menuItems(for: session).contains(where: { $0.id == .rename && $0.isEnabled }) else { return }
        renameScope = connectionScope
        renameText = session.title
        renameSession = session
    }

    private var renameAvailable: Bool {
        guard renameScope == connectionScope, let id = renameSession?.id, let session = store.session(id) else { return false }
        return menuItems(for: session).contains { $0.id == .rename && $0.isEnabled }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !store.isReferenceMode {
                deviceBar
                reconnectBanner
            }
            Group {
                if !store.connection.isOnline && store.sessions.isEmpty && store.profiles.isEmpty {
                    connectionEmptyState
                } else {
                    sessionList
                }
            }
        }
        .background(ZTheme.background)
        .confirmationDialog("连接这台电脑？", isPresented: Binding(get: { connectRequest != nil }, set: { if !$0 { connectRequest = nil } }), titleVisibility: .visible) {
            Button("连接并切换") {
                guard let request = connectRequest else { return }
                connectRequest = nil
                search = ""; collapsed = []
                Task { await store.switchComputer(request.profile, confirmedControllerReplacement: true) }
            }
            Button("取消", role: .cancel) { connectRequest = nil }
        } message: {
            Text("连接 \(connectRequest?.deviceName ?? "所选电脑") 的 \(connectRequest?.workspaceTitle ?? "项目")。如果另一台手机正在控制这台电脑，此次连接可能替换它；电脑上的任务会继续运行。")
        }
        .confirmationDialog("重新连接 ZCode 远程控制？", isPresented: $confirmRelayReconnect, titleVisibility: .visible) {
            Button("连接这台电脑") {
                if let profile = store.activeProfile { Task { await store.connect(profile, confirmedControllerReplacement: true) } }
            }
        } message: { Text("同一电脑工作区只允许一个移动端控制器。连接后可能替换当前已连接的手机。") }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { store.sheet = .connections } label: {
                    MenuLinesGlyph().stroke(style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        .frame(width: 22, height: 24)
                }.tint(.primary).accessibilityLabel("打开连接与导航")
                    .accessibilityIdentifier("home.sidebar")
            }
            ToolbarItem(placement: .principal) {
                Button { store.sheet = .connections } label: {
                    VStack(spacing: 2) {
                        Text(store.showArchived ? "已归档任务" : (selectedDevice?.name ?? "Zcode connect"))
                            .font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                        HStack(spacing: 6) {
                            Circle().fill(statusColor)
                                .frame(width: 6, height: 6)
                            Image(systemName: selectedDevice == nil ? "square.grid.2x2" : "laptopcomputer")
                                .font(.system(size: 11))
                            Text(statusTitle).font(.system(size: 13)).lineLimit(1)
                        }.foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain).accessibilityLabel("当前电脑，\(statusTitle)，\(store.connection.label)")
            }
            ToolbarItem(placement: .topBarTrailing) {
                homeMenu
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 12) {
                GlassSearchField(text: $search, placeholder: "搜索聊天")
                Button {
                    if store.connection.isOnline { store.path.append(.newSession) }
                    else { store.sheet = .pairing }
                } label: {
                    HStack(spacing: 10) {
                        ComposeGlyph().stroke(style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)).frame(width: 25, height: 25)
                        if !store.connection.isOnline { Text("聊天").font(.system(size: 18, weight: .semibold)) }
                    }.frame(width: store.connection.isOnline ? 36 : 106, height: store.connection.isOnline ? 36 : 34)
                }.buttonStyle(.glassProminent).buttonBorderShape(store.connection.isOnline ? .circle : .capsule)
                    .frame(width: store.connection.isOnline ? 48 : 120, height: 48)
                    .accessibilityLabel("新建聊天").accessibilityIdentifier("home.new")
                    .measureLayout("home.new")
            }
            .padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 8)
        }
        .alert("重命名任务", isPresented: Binding(get: { renameSession != nil }, set: { if !$0 { renameSession = nil } })) {
            TextField("任务名称", text: $renameText)
            Button("取消", role: .cancel) { renameSession = nil }
            Button("保存") {
                if renameAvailable, let id = renameSession?.id {
                    store.rename(id, title: renameText)
                }
                renameSession = nil
            }.disabled(!renameAvailable || renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onChange(of: connectionScope) { _, _ in
            renameSession = nil; renameScope = nil
            search = ""; collapsed = []
        }
        .onChange(of: store.sessions.map(\.id)) { _, ids in
            if let id = renameSession?.id, !ids.contains(id) { renameSession = nil; renameScope = nil }
        }
        .onChange(of: store.homeDeviceGroups.map(\.id)) { _, ids in
            if let selectedDeviceID, !ids.contains(selectedDeviceID) { self.selectedDeviceID = nil }
        }
        .onChange(of: renameAvailable) { _, available in
            if !available { renameSession = nil; renameScope = nil }
        }
    }

    private var statusColor: Color {
        guard let selectedDevice else { return store.connection.isOnline ? .green : .gray }
        if !selectedDevice.isActive { return .gray }
        if store.isAutoReconnecting { return .orange }
        if store.connection.isOnline {
            return store.isReferenceMode || store.streamConnected ? .green : .orange
        }
        return .gray
    }

    private var statusTitle: String {
        guard let selectedDevice else {
            return store.connection.isOnline ? store.hostName : "全部设备"
        }
        if !selectedDevice.isActive {
            return "\(selectedDevice.name) · 上次同步"
        }
        if store.isAutoReconnecting { return "\(store.hostName) · 正在重连" }
        if store.connection.isOnline && !store.isReferenceMode && !store.streamConnected {
            return "\(store.hostName) · 正在重连"
        }
        return store.hostName
    }

    private var deviceBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                deviceChip(title: "全部", symbol: "square.grid.2x2", selected: selectedDeviceID == nil,
                           dot: nil) {
                    selectedDeviceID = nil
                }
                ForEach(store.homeDeviceGroups) { device in
                    deviceChip(title: device.name, symbol: "desktopcomputer", selected: selectedDeviceID == device.id,
                               dot: device.isActive ? statusColorFor(device) : nil) {
                        selectedDeviceID = device.id
                    }
                }
                Button { store.sheet = .connections } label: {
                    Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }.buttonStyle(.plain).tint(.secondary)
                    .accessibilityLabel("管理连接")
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 6)
        }
        .accessibilityIdentifier("home.devices")
    }

    private func statusColorFor(_ device: HomeDeviceGroup) -> Color {
        if !device.isActive { return .gray }
        if store.isAutoReconnecting { return .orange }
        return store.connection.isOnline ? (store.streamConnected ? .green : .orange) : .gray
    }

    private func deviceChip(title: String, symbol: String, selected: Bool, dot: Color?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let dot {
                    Circle().fill(dot).frame(width: 6, height: 6)
                }
                Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.horizontal, 13).padding(.vertical, 8)
            .background(selected ? Color.primary.opacity(0.10) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var reconnectBanner: some View {
        if selectedDevice?.isActive != false, store.activeProfile != nil {
            if store.isAutoReconnecting || store.connection == .connecting {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.isAutoReconnecting ? "正在重新连接 \(store.hostName)" : "正在连接 \(store.hostName)")
                            .font(.subheadline.weight(.medium))
                        Text(store.reconnectAttempt > 1
                             ? "第 \(store.reconnectAttempt) 次尝试 · 任务仍在电脑上运行"
                             : "任务仍在电脑上运行")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Button("立即重试") { Task { await store.retryConnectionNow() } }
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 20).padding(.bottom, 8)
            } else if !store.connection.isOnline {
                HStack(spacing: 10) {
                    Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connectionFailureMessage).font(.caption).lineLimit(2)
                        Text("自动重连已暂停，任务仍在电脑上运行").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Button(needsRelayLogin ? "登录账号" : "重新连接") {
                        if needsRelayLogin { store.sheet = .pairing }
                        else { Task { await store.retryConnectionNow() } }
                    }
                    .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 20).padding(.bottom, 8)
            }
        }
    }

    private var needsRelayLogin: Bool {
        store.activeProfile?.isRelay == true && store.relayAccount == nil
    }

    private var connectionFailureMessage: String {
        if needsRelayLogin { return "登录状态已失效，请重新登录 ZCode 账号。" }
        if case .failed(let message) = store.connection { return message }
        return "这台电脑尚未连接。"
    }

    private var sessionList: some View {
        let visibleSections = sections
        let firstID = visibleSections.first?.id
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if store.sessionListTruncated && !store.isReferenceMode {
                    InlineNotice(symbol: "list.bullet", text: "已加载 \(store.sessions.count) 个任务，电脑还有未返回的记录。当前搜索只覆盖已加载任务。")
                        .padding(.bottom, 16)
                }
                if store.isReferenceMode && !store.referenceReview {
                    HStack {
                        Text("界面体验").font(.caption.weight(.medium))
                        Spacer()
                        Button("连接我的电脑") { store.leaveReferenceMode(); store.sheet = .pairing }
                            .font(.caption)
                    }.foregroundStyle(.secondary).padding(.bottom, 20)
                }
                if store.showArchived {
                    Button { store.showArchived = false } label: {
                        Label("返回全部任务", systemImage: "arrow.left").font(.subheadline)
                    }.padding(.bottom, 20)
                }
                if visibleSections.isEmpty {
                    emptyState
                }
                ForEach(visibleSections) { section in
                    sectionHeader(section, first: section.id == firstID)
                    if !collapsed.contains(section.id) {
                        ForEach(orderedSessions(section.sessions)) { session in
                            sessionRow(session, section: section)
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 18)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await store.refresh() }
        .accessibilityIdentifier("home.sessions")
        .onScrollPhaseChange { _, phase in
            #if DEBUG
            if MotionPerformanceProbe.shared.isRunning { MotionPerformanceProbe.shared.setStage("home-\(phase)") }
            #endif
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !search.isEmpty {
            ContentUnavailableView("没有找到聊天", systemImage: "magnifyingglass",
                                   description: Text("试试其他任务名称、项目或设备名称。"))
                .padding(.top, 70)
        } else if let selectedDevice, !selectedDevice.isActive {
            ContentUnavailableView {
                Label("还没有同步到任务", systemImage: "desktopcomputer")
            } description: {
                Text("连接后可以查看这台电脑上的项目和对话。")
            } actions: {
                if let workspace = selectedDevice.workspaces.first {
                    Button("连接 \(selectedDevice.name)") {
                        connectRequest = ConnectRequest(profile: workspace.profile,
                                                        deviceName: selectedDevice.name,
                                                        workspaceTitle: workspace.title)
                    }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                }
            }.padding(.top, 70)
        } else if selectedDevice?.isActive == true && !store.connection.isOnline {
            ContentUnavailableView {
                Label("连接暂时中断", systemImage: "wifi.exclamationmark")
            } description: {
                Text("任务保存在电脑上。网络恢复后会自动重新连接。")
            } actions: {
                Button("立即重试") { Task { await store.retryConnectionNow() } }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            }.padding(.top, 70)
        } else {
            ContentUnavailableView {
                Label("还没有任务", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("创建一个任务，从手机继续你的工作。")
            } actions: {
                Button("新建聊天") { store.path.append(.newSession) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    .disabled(!store.connection.isOnline)
            }.padding(.top, 70)
        }
    }

    private func sectionHeader(_ section: HomeSection, first: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if collapsed.contains(section.id) { collapsed.remove(section.id) }
                    else { collapsed.insert(section.id) }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed.contains(section.id) ? -90 : 0))
                    .frame(width: 14, height: 30)
            }.buttonStyle(.plain)
            Image(systemName: "folder")
                .font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(section.projectName).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                if selectedDeviceID == nil || section.device.workspaces.count > 1 {
                    Text("\(section.device.name) · \(section.workspace.title)")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if !section.workspace.isActive {
                Image(systemName: "icloud.slash")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Text("\(section.sessions.count)")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.tertiary)
        }
        .padding(.top, first ? 4 : 26).padding(.bottom, 10)
    }

    private func sessionRow(_ session: RemoteSession, section: HomeSection) -> some View {
        let active = section.workspace.isActive
        let actions = sessionActions(for: session, active: active)
        return Button { open(session, in: section) } label: {
            VStack(alignment: .leading, spacing: 6.666667) {
                HStack(spacing: 8) {
                    if session.status == .running { StatusDot(status: session.status) }
                    else if store.isUnread(session.id) { Circle().fill(ZTheme.accent).frame(width: 7, height: 7).accessibilityLabel("未读") }
                    if session.isPinned { Image(systemName: "flag.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(ZTheme.accent).accessibilityLabel("已置顶") }
                    Text(session.title).font(.system(size: 17))
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }.foregroundStyle(.primary)
                HStack(spacing: 4.666667) {
                    Group {
                        if session.projectName == "聊天" {
                            ChatGlyph().stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                        } else {
                            FolderGlyph().stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                        }
                    }.frame(width: 14, height: 14).frame(width: 16).offset(y: -0.666667)
                    Text(selectedDeviceID == nil ? section.device.name : section.workspace.title)
                        .font(.system(size: 13)).lineLimit(1)
                    Text("·").font(.system(size: 13))
                    Text(session.updatedAt, style: .relative).font(.system(size: 13)).lineLimit(1)
                    Spacer()
                    if switchingSessionID == session.id {
                        ProgressView().controlSize(.mini)
                    } else if !active {
                        Image(systemName: "icloud.slash").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    if session.additions > 0 || session.deletions > 0 {
                        ChangeCount(additions: session.additions, deletions: session.deletions)
                    }
                }.foregroundStyle(ZTheme.listSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 23.333333).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("session.\(session.id)")
        .measureLayout("row.\(session.id)")
        .overlay {
            SessionContextInteraction(title: session.title,
                identity: "\(connectionScope)|\(section.workspace.id)|\(active)|\(session.id)",
                preview: AnyView(ConversationPreview(sessionID: session.id).environment(store)),
                actions: actions, open: { open(session, in: section) })
                .accessibilityHidden(true)
        }
        .accessibilityActions {
            ForEach(actions, id: \.accessibilityIdentity) { action in
                Button(action.item.title) { action.perform() }.disabled(!action.item.isEnabled)
            }
        }
        .id(SessionRowIdentity(scope: connectionScope + "|" + section.workspace.id + "|" + String(active),
                               sessionID: session.id,
                               actions: actions.map(\.accessibilityIdentity)))
    }

    private func open(_ session: RemoteSession, in section: HomeSection) {
        if section.workspace.isActive, store.connection.isOnline {
            store.setUnread(false, sessionID: session.id)
            store.path.append(.session(session.id))
            return
        }
        guard switchingSessionID == nil else { return }
        switchingSessionID = session.id
        Task {
            await store.switchAndOpen(section.workspace.profile, sessionID: session.id)
            if switchingSessionID == session.id { switchingSessionID = nil }
        }
    }

    private func sessionActions(for session: RemoteSession, active: Bool) -> [SessionContextAction] {
        let scope = connectionScope + "|" + String(active)
        let pinned = !session.isPinned, archived = !session.isArchived, unread = !store.isUnread(session.id)
        return menuItems(for: session, active: active).map { item in
            SessionContextAction(item: item) {
                guard item.isEnabled, active, scope.hasPrefix(connectionScope),
                      let current = store.session(session.id),
                      menuItems(for: current).contains(item) else { return }
                switch item.id {
                case .pin: store.setPinned(pinned, sessionID: session.id)
                case .rename: beginRename(current)
                case .unread: store.setUnread(unread, sessionID: session.id)
                case .copyID: store.copy(session.id)
                case .archive: store.archive(session.id, archived: archived)
                }
            }
        }
    }

    private var homeMenu: some View {
        @Bindable var store = store
        return Menu {
            Section {
                Menu {
                    ForEach(store.homeDeviceGroups) { device in
                        if let profile = preferredProfile(for: device) {
                            Button {
                                if profile.isRelay && !(device.isActive && store.connection.isOnline && !store.isReferenceMode) {
                                    connectRequest = ConnectRequest(profile: profile,
                                                                    deviceName: device.name,
                                                                    workspaceTitle: device.workspaces.first?.title ?? "项目")
                                } else {
                                    search = ""; collapsed = []
                                    Task { await store.switchComputer(profile) }
                                }
                            } label: {
                                Label(device.name + (device.isActive && !store.isReferenceMode ? " · \(store.connection.label)" : ""),
                                      systemImage: device.isActive && !store.isReferenceMode ? "checkmark" : "laptopcomputer")
                            }
                            .accessibilityIdentifier("home.computer.\(device.id)")
                        }
                    }
                    if store.profiles.isEmpty { Text("还没有添加电脑") }
                    Divider()
                    Button("添加电脑", systemImage: "plus") { store.sheet = .pairing }
                    Button("管理电脑", systemImage: "laptopcomputer") { store.sheet = .connections }
                } label: { Label("切换电脑", systemImage: "laptopcomputer") }
                Button("添加连接", systemImage: "plus") { store.sheet = .pairing }
                    .accessibilityIdentifier("home.addConnection")
            }
            Picker("排序方式", selection: $store.sortOrder) {
                ForEach(SortOrder.allCases) { sort in Label(sort.rawValue, systemImage: sort.symbol).tag(sort) }
            }.pickerStyle(.inline)
            Section("管理") {
                Button("云端任务", systemImage: "cloud") {
                    store.errorMessage = "云端任务暂未接入。当前任务在所连接的电脑上运行；中转服务器只负责传输，不会在电脑离线后继续执行任务。"
                }
                Button(store.showArchived ? "全部任务" : "已归档任务", systemImage: "archivebox") { store.showArchived.toggle() }
                Button("设置", systemImage: "gearshape") { store.sheet = .settings }
            }
            if store.isReferenceMode {
                Section("剩余用量") { Text("本周 59%").foregroundStyle(.secondary) }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 21, weight: .semibold))
        }.tint(.primary).accessibilityLabel("远程菜单").accessibilityIdentifier("home.menu")
    }

    private func preferredProfile(for device: HomeDeviceGroup) -> ConnectionProfile? {
        device.workspaces.first(where: \.isActive)?.profile
            ?? device.workspaces.first(where: { !$0.sessions.isEmpty })?.profile
            ?? device.workspaces.first?.profile
    }

    private var connectionEmptyState: some View {
        VStack(spacing: 24) {
            Spacer()
            VStack(spacing: 22) {
                Text("\(store.connection.label) · \(store.hostName)").font(.system(size: 20))
                Text(store.connection == .connecting ? "正在加载这台电脑的任务…" : "请确保 ZCode 正在这台电脑上运行。")
                    .font(.system(size: 19)).multilineTextAlignment(.center)
                if store.activeProfile != nil {
                    Button {
                        if store.activeProfile?.isRelay == true { confirmRelayReconnect = true }
                        else { Task { await store.retryConnectionNow() } }
                    } label: {
                        if store.connection == .connecting || store.isAutoReconnecting { ProgressView().frame(width: 78, height: 26) }
                        else { Text("重新连接").frame(width: 78, height: 26) }
                    }.buttonStyle(NativeGlassButtonStyle()).disabled(store.connection == .connecting || store.isAutoReconnecting)
                } else {
                    Button("添加连接") { store.sheet = .pairing }
                        .buttonStyle(NativeGlassButtonStyle()).controlSize(.large)
                    if !store.referenceReview {
                        Button("先体验界面") { store.enterReferenceMode() }.font(.subheadline)
                    }
                }
            }.foregroundStyle(.secondary).padding(.horizontal, 28)
            Spacer()
        }.frame(maxWidth: .infinity)
    }
}
