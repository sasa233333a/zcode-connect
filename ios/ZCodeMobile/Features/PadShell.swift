import SwiftUI

/// iPad regular-width layout: computers and projects in the sidebar, the
/// selected project's conversations in the middle, and the chat in the detail
/// column. This follows the standard three-column NavigationSplitView pattern.
struct PadShell: View {
    @Environment(AppStore.self) private var store
    @State private var selectedDeviceID: String?
    @State private var selectedWorkspaceID: String?
    @State private var search = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var devices: [HomeDeviceGroup] { store.homeDeviceGroups }

    private var selectedDevice: HomeDeviceGroup? {
        devices.first { $0.id == selectedDeviceID }
            ?? devices.first { $0.isActive }
            ?? devices.first
    }

    private var workspaces: [HomeWorkspaceGroup] { selectedDevice?.workspaces ?? [] }

    private var selectedWorkspace: HomeWorkspaceGroup? {
        workspaces.first { $0.id == selectedWorkspaceID }
            ?? workspaces.first { $0.isActive }
            ?? workspaces.first
    }

    private var sessions: [RemoteSession] {
        let all = selectedWorkspace?.sessions ?? []
        let filtered = all.filter { session in
            guard session.isArchived == store.showArchived else { return false }
            guard !search.isEmpty else { return true }
            return session.title.localizedStandardContains(search)
                || session.projectName.localizedStandardContains(search)
        }
        return filtered.sorted { lhs, rhs in
            if store.sortOrder == .priority {
                if lhs.status == .waiting && rhs.status != .waiting { return true }
                if rhs.status == .waiting && lhs.status != .waiting { return false }
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    var body: some View {
        @Bindable var store = store
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 285, max: 340)
        } content: {
            conversationColumn
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 460)
        } detail: {
            NavigationStack(path: $store.path) {
                detailPlaceholder
                    .navigationDestination(for: AppRoute.self) { route in
                        switch route {
                        case .session(let id): ChatView(sessionID: id).navigationBarBackButtonHidden(true)
                        case .newSession: NewSessionView()
                        }
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .task { normalizeSelection() }
        .onChange(of: store.activeProfileID) { _, id in
            guard let id, let profile = store.profiles.first(where: { $0.id == id }) else { return }
            selectedDeviceID = AppStore.deviceIdentity(for: profile)
            selectedWorkspaceID = id
        }
        .onChange(of: devices.map(\.id)) { _, _ in normalizeSelection() }
        .onChange(of: workspaces.map(\.id)) { _, ids in
            if let selectedWorkspaceID, !ids.contains(selectedWorkspaceID) {
                self.selectedWorkspaceID = workspaces.first(where: \.isActive)?.id ?? workspaces.first?.id
            }
        }
    }

    private var sidebar: some View {
        List {
            Section("电脑") {
                ForEach(devices) { device in
                    Button { selectDevice(device) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "desktopcomputer")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name).foregroundStyle(.primary).lineLimit(1)
                                Text("\(device.workspaces.count) 个项目")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            if device.isActive {
                                Circle().fill(deviceStatusColor(device)).frame(width: 8, height: 8)
                            }
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(selectedDevice?.id == device.id
                                       ? Color.accentColor.opacity(0.14) : Color.clear)
                }
            }

            if let selectedDevice {
                let projects = selectedDevice.workspaces.filter { $0.purpose != "conversation" }
                let conversations = selectedDevice.workspaces.filter { $0.purpose == "conversation" }
                if !projects.isEmpty {
                    Section("项目") {
                        ForEach(projects) { workspace in workspaceRow(workspace, kind: "项目") }
                    }
                }
                if !conversations.isEmpty {
                    Section("对话") {
                        ForEach(conversations) { workspace in workspaceRow(workspace, kind: "对话") }
                    }
                }
            }

            Section {
                Button { store.sheet = .connections } label: {
                    Label("管理电脑", systemImage: "laptopcomputer")
                }
                Button { store.sheet = .settings } label: {
                    Label("设置", systemImage: "gearshape")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Zcode")
        .accessibilityIdentifier("pad.sidebar")
    }

    private var conversationColumn: some View {
        Group {
            if let workspace = selectedWorkspace {
                List {
                    if !workspace.isActive {
                        Section {
                            HStack(spacing: 10) {
                                if store.isAutoReconnecting || store.connection == .connecting {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "icloud.slash").foregroundStyle(.secondary)
                                }
                                Text(store.isAutoReconnecting || store.connection == .connecting
                                     ? "正在连接这台电脑…" : "显示上次同步的内容")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                if !store.connection.isOnline && !store.isAutoReconnecting {
                                    Button("重新连接") { Task { await store.retryConnectionNow() } }
                                        .font(.caption.weight(.semibold))
                                }
                            }
                        }
                    }
                    if sessions.isEmpty {
                        ContentUnavailableView {
                            Label("暂无任务", systemImage: "bubble.left.and.bubble.right")
                        } description: {
                            Text("在电脑上创建任务，或在这里新建一个。")
                        } actions: {
                            Button("新建聊天") { store.path = [.newSession] }
                                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                                .disabled(!store.connection.isOnline)
                        }
                    } else {
                        Section(workspace.title) {
                            ForEach(sessions) { session in
                                conversationRow(session, workspace: workspace)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索聊天")
                .navigationTitle(workspace.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { conversationToolbar }
            } else {
                ContentUnavailableView("选择一个项目", systemImage: "folder",
                                       description: Text("从左侧选择电脑和项目。"))
                    .navigationTitle("对话")
                    .toolbar { conversationToolbar }
            }
        }
    }

    private var detailPlaceholder: some View {
        ContentUnavailableView {
            Label("选择一个对话", systemImage: "bubble.left.and.text.bubble.right")
        } description: {
            Text("从中间列表选择任务，或新建一个聊天。")
        }
        .navigationTitle("Zcode connect")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func conversationRow(_ session: RemoteSession, workspace: HomeWorkspaceGroup) -> some View {
        Button { open(session, workspace: workspace) } label: {
            HStack(spacing: 12) {
                if session.status == .running { StatusDot(status: session.status) }
                else {
                    Circle()
                        .fill(store.isUnread(session.id) ? ZTheme.accent : Color.clear)
                        .frame(width: 7, height: 7)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        if session.isPinned {
                            Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(ZTheme.accent)
                        }
                        Text(session.title).font(.system(size: 16)).lineLimit(1)
                    }
                    HStack(spacing: 5) {
                        Text(workspace.purpose == "conversation" ? "对话" : session.projectName)
                            .font(.caption).lineLimit(1)
                        Text("·").font(.caption)
                        Text(session.updatedAt, style: .relative).font(.caption)
                    }.foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if session.status != .idle {
                    Text(session.status.label)
                        .font(.caption2)
                        .foregroundStyle(session.status == .failed ? .red : .secondary)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(store.currentSessionID == session.id
                           ? Color.accentColor.opacity(0.14) : Color.clear)
    }

    @ToolbarContentBuilder private var conversationToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { store.path = [.newSession] } label: {
                Image(systemName: "square.and.pencil")
            }.accessibilityLabel("新建聊天")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button(store.showArchived ? "显示全部任务" : "显示已归档", systemImage: "archivebox") {
                    store.showArchived.toggle()
                }
                Button("管理电脑", systemImage: "laptopcomputer") { store.sheet = .connections }
                Button("设置", systemImage: "gearshape") { store.sheet = .settings }
            } label: { Image(systemName: "ellipsis") }
        }
    }

    @ViewBuilder
    private func workspaceRow(_ workspace: HomeWorkspaceGroup, kind: String) -> some View {
        Button { selectWorkspace(workspace) } label: {
            HStack(spacing: 10) {
                Image(systemName: kind == "对话" ? "bubble.left.and.bubble.right" : "folder")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.title).foregroundStyle(.primary).lineLimit(1)
                    Text(workspace.isActive ? "当前\(kind)" : "上次同步")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text("\(workspace.sessions.count)")
                    .font(.caption).foregroundStyle(.tertiary)
                if workspace.isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ZTheme.accent)
                } else {
                    Image(systemName: "icloud.slash")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selectedWorkspace?.id == workspace.id
                           ? Color.accentColor.opacity(0.14) : Color.clear)
    }

    private func selectDevice(_ device: HomeDeviceGroup) {
        selectedDeviceID = device.id
        let target = preferredProfile(for: device)
        selectedWorkspaceID = target?.id
        store.path = []
        guard let target else { return }
        if !device.isActive || !store.connection.isOnline {
            Task { await store.switchComputer(target, confirmedControllerReplacement: true) }
        }
    }

    private func selectWorkspace(_ workspace: HomeWorkspaceGroup) {
        selectedWorkspaceID = workspace.id
        store.path = []
        if !workspace.isActive || !store.connection.isOnline {
            Task { await store.switchComputer(workspace.profile, confirmedControllerReplacement: true) }
        }
    }

    private func open(_ session: RemoteSession, workspace: HomeWorkspaceGroup) {
        if workspace.isActive, store.connection.isOnline {
            store.setUnread(false, sessionID: session.id)
            store.path = [.session(session.id)]
        } else {
            Task { await store.switchAndOpen(workspace.profile, sessionID: session.id) }
        }
    }

    private func preferredProfile(for device: HomeDeviceGroup) -> ConnectionProfile? {
        device.workspaces.first(where: \.isActive)?.profile
            ?? device.workspaces.first(where: { !$0.sessions.isEmpty })?.profile
            ?? device.workspaces.first?.profile
    }

    private func deviceStatusColor(_ device: HomeDeviceGroup) -> Color {
        if !device.isActive { return .gray }
        if store.isAutoReconnecting { return .orange }
        return store.connection.isOnline ? .green : .gray
    }

    private func normalizeSelection() {
        if let id = selectedDeviceID, !devices.contains(where: { $0.id == id }) {
            selectedDeviceID = nil
        }
        if selectedDeviceID == nil {
            selectedDeviceID = devices.first(where: \.isActive)?.id ?? devices.first?.id
        }
        if let selectedDevice, !selectedDevice.workspaces.contains(where: { $0.id == selectedWorkspaceID }) {
            selectedWorkspaceID = selectedDevice.workspaces.first(where: \.isActive)?.id
                ?? selectedDevice.workspaces.first?.id
        }
        if selectedWorkspaceID == nil {
            selectedWorkspaceID = store.activeProfileID ?? devices.first?.workspaces.first?.id
        }
    }
}
