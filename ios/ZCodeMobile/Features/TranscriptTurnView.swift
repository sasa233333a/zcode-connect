import SwiftUI

/// One reply owns its progress disclosure and one final-answer action bar.
/// Message identity remains unchanged when the user expands saved work.
struct TranscriptTurnView: View {
    let turn: TranscriptTurn
    let sessionID: String
    var density: ConversationDensity = .standard
    var allowsAutoCollapse = true
    @State private var processExpanded: Bool

    init(turn: TranscriptTurn, sessionID: String,
         density: ConversationDensity = .standard,
         allowsAutoCollapse: Bool = true) {
        self.turn = turn
        self.sessionID = sessionID
        self.density = density
        self.allowsAutoCollapse = allowsAutoCollapse
        _processExpanded = State(initialValue: density.expandsProcess(for: turn))
    }
    @State private var inspectingTool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(turn.userMessages) { message in
                MessageView(message: message, sessionID: sessionID, density: density, showsResponseActions: false)
                    .padding(.top, density == .concise ? 8 : 12)
                    .padding(.bottom, density == .concise ? 18 : 34)
                    .id(message.id)
            }
            if !turn.processMessages.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    if showsProcessToggle {
                        Button {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) { processExpanded.toggle() }
                        } label: {
                            processSummary
                        }.buttonStyle(.plain)
                            .accessibilityValue(processExpanded ? "已展开" : "已折叠")
                            .accessibilityIdentifier("turn.process.\(turn.id)")
                            .transition(reduceMotion ? .identity : .opacity)
                    } else {
                        processSummary
                            .accessibilityIdentifier("turn.process.\(turn.id)")
                    }
                    if processExpanded {
                        processContent.transition(reduceMotion ? .identity : .opacity)
                    } else if density == .concise, !turn.isComplete, let live = turn.latestProcessText {
                        RichMessageText(text: live.text, user: false, streaming: live.isStreaming)
                            .equatable()
                            .padding(.top, 8)
                            .transition(reduceMotion ? .identity : .opacity)
                    }
                }
                .onPreferenceChange(ToolInspectionPreferenceKey.self) { inspectingTool = $0 }
                .padding(.bottom, density == .concise ? 12 : 22)
            }
            ForEach(turn.resultMessages) { message in
                MessageView(message: message, sessionID: sessionID, density: density,
                            showsResponseActions: turn.actionMessageID == message.id)
                    .padding(.bottom, density == .concise ? 14 : 22).id(message.id)
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: turn.hasConfirmedResult) { _, complete in
            if complete, density != .detailed, allowsAutoCollapse, !inspectingTool, !turn.needsAttention {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) { processExpanded = false }
            }
        }
        .onChange(of: turn.needsAttention) { _, attention in
            if density == .concise, attention {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) { processExpanded = true }
            }
        }
        .onChange(of: density) { _, value in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) {
                processExpanded = value.expandsProcess(for: turn)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: turn.hasConfirmedResult)
    }

    private var showsProcessToggle: Bool {
        density == .concise || turn.canCollapseProcess
    }

    @ViewBuilder private var processSummary: some View {
        if density == .concise, !turn.isComplete {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                summaryRow(turn.activitySummary(at: context.date))
            }
        } else {
            summaryRow(density == .concise ? turn.activitySummary(at: .now) : processTitle)
        }
    }

    private func summaryRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: turn.activityIndicator.symbol)
                .font(.system(size: 17, weight: .regular)).frame(width: 22)
                .accessibilityHidden(true)
            Text(text).lineLimit(1).truncationMode(.middle).monospacedDigit()
            Spacer(minLength: 8)
            if showsProcessToggle {
                Image(systemName: processExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).frame(width: 16)
            }
        }
        .font(.subheadline).foregroundStyle(summaryColor).frame(minHeight: 28)
        .contentShape(Rectangle())
    }

    private var summaryColor: Color {
        switch turn.activityIndicator {
        case .failed: .red
        case .waiting: .orange
        default: .secondary
        }
    }

    private var processTitle: String {
        let count = turn.toolCount
        let status: String = switch turn.state {
        case .completed: "已完成"
        case .interrupted: "已中断"
        case .failed: "执行失败"
        default: "执行过程"
        }
        return count > 0 ? "\(status) · \(count) 个步骤" : "\(status) · 查看过程"
    }

    private func hasFollowingResponse(after id: String) -> Bool {
        if !turn.resultMessages.isEmpty { return true }
        guard let index = turn.processMessages.firstIndex(where: { $0.id == id }) else { return false }
        return turn.processMessages.dropFirst(index + 1).contains { $0.role == .assistant && !$0.text.isEmpty }
    }

    private var processContent: some View {
        ForEach(turn.processMessages) { message in
            MessageView(message: message, sessionID: sessionID, density: density, showsResponseActions: false,
                        hasFollowingResponse: hasFollowingResponse(after: message.id),
                        showsToolGroupSummary: !turn.canCollapseProcess || inspectingTool)
                .padding(.bottom, message.text.isEmpty ? 0 : 16).id(message.id)
        }
    }
}
