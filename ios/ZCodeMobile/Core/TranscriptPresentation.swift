import Foundation

enum ConversationDensity: String, CaseIterable, Identifiable, Sendable {
    case concise, standard, detailed

    var id: String { rawValue }
    var label: String {
        switch self {
        case .concise: "简洁"
        case .standard: "标准"
        case .detailed: "详细"
        }
    }
    /// Concise mode compacts every turn; standard keeps today's live detail;
    /// detailed starts settled turns open as well.
    func expandsProcess(for turn: TranscriptTurn) -> Bool {
        guard !turn.processMessages.isEmpty else { return false }
        switch self {
        case .concise: return turn.needsAttention
        case .standard: return !turn.defaultCollapsed
        case .detailed: return true
        }
    }
}

/// The leading glyph of a turn's one-line activity summary. Running turns stay
/// neutral; a failure only turns red once the turn itself has settled.
enum TranscriptActivityIndicator: Equatable {
    case tool(String)
    case replying
    case waiting
    case failed
    case steps

    var symbol: String {
        switch self {
        case .tool(let symbol): symbol
        case .replying: "ellipsis.bubble"
        case .waiting: "clock"
        case .failed: "exclamationmark.triangle"
        case .steps: "list.bullet"
        }
    }
}

struct TranscriptTurn: Identifiable, Hashable {
    let id: String
    let messages: [ChatMessage]
    let userMessages: [ChatMessage]
    let processMessages: [ChatMessage]
    let resultMessages: [ChatMessage]
    let state: TranscriptMessageSemantics.State
    var isComplete: Bool { [.completed, .interrupted, .failed].contains(state) }
    var hasConfirmedResult: Bool { state == .completed && !resultMessages.isEmpty }
    var canCollapseProcess: Bool { isComplete && !processMessages.isEmpty }
    var defaultCollapsed: Bool { canCollapseProcess }
    var actionMessageID: String? { resultMessages.last { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.id }
}

enum TranscriptPresentation {
    /// No session status or array position can promote an intermediate message to final.
    static func group(_ messages: [ChatMessage]) -> [TranscriptTurn] {
        var order: [String] = [], buckets: [String: [ChatMessage]] = [:], current: String?
        // A guided input is appended into an already-running turn. It keeps its
        // chronological position as its own bubble, and the turn continues after it.
        var continuations: [String: String] = [:]
        for message in messages {
            let explicit = message.transcript?.turnID.trimmingCharacters(in: .whitespacesAndNewlines)
            let key: String
            if let explicit, !explicit.isEmpty {
                let base = "turn:" + explicit
                if message.role == .user, buckets[base] != nil {
                    key = base + ":guided:" + message.id
                    let continuation = base + "#after:" + message.id
                    continuations[base] = continuation
                    order.append(key); buckets[key] = [message]; current = key
                    continue
                }
                key = continuations[base] ?? base
            }
            else if message.role == .user { key = "legacy:user:" + message.id }
            else { key = current ?? "legacy:message:" + message.id }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(message); current = key
        }
        return order.map { key in
            let values = buckets[key] ?? [], states = Set(values.compactMap { $0.transcript?.state })
            let state: TranscriptMessageSemantics.State = states.contains(.running) ? .running : states.contains(.failed) ? .failed : states.contains(.interrupted) ? .interrupted : states.contains(.completed) ? .completed : .unknown
            var users: [ChatMessage] = [], process: [ChatMessage] = [], results: [ChatMessage] = []
            for message in values {
                if message.role == .user { users.append(message); continue }
                let hasVisibleResult = !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !message.attachments.isEmpty || !message.changes.isEmpty
                let result = hasVisibleResult && state == .completed && message.transcript?.role == .finalAnswer && message.role == .assistant && !message.isStreaming && !message.steps.contains { $0.status == .running || $0.status == .waiting }
                guard result else { process.append(message); continue }
                if message.reasoning?.isEmpty == false || !message.steps.isEmpty {
                    var work = message; work.id = "transcript-process:" + message.id
                    work.text = ""; work.attachments = []; work.changes = []; work.forkTarget = nil; work.feedback = 0
                    work.transcript?.role = .process; process.append(work)
                }
                var answer = message; answer.reasoning = nil; answer.steps = []; answer.elapsed = nil
                results.append(answer)
            }
            return .init(id: key, messages: values, userMessages: users, processMessages: process, resultMessages: results, state: state)
        }
    }
}

extension TranscriptTurn {
    var reasoningCount: Int {
        processMessages.reduce(0) { count, message in
            let reasoning = message.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return count + (reasoning.isEmpty ? 0 : 1)
        }
    }
    var toolCount: Int { processMessages.reduce(0) { $0 + $1.steps.count } }
    var hasFailedStep: Bool { processMessages.contains { $0.steps.contains { $0.status == .failed } } }
    var hasWaitingStep: Bool { processMessages.contains { $0.steps.contains { $0.status == .waiting } } }
    var needsAttention: Bool { state == .failed || state == .interrupted || hasFailedStep || hasWaitingStep }
    var latestActiveStep: ToolStep? {
        let steps = processMessages.flatMap(\.steps)
        return steps.last { $0.status == .waiting } ?? steps.last { $0.status == .running }
    }
    var latestProcessText: ChatMessage? {
        processMessages.last { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    /// A failed step from earlier in the turn must not tint the live "replying"
    /// state red; wait for the turn to settle before showing a failure.
    var activityIndicator: TranscriptActivityIndicator {
        if let step = latestActiveStep {
            if step.status == .waiting { return .waiting }
            if step.status == .running { return .tool(step.activityKind.symbol) }
        }
        if state == .running { return .replying }
        if state == .failed || hasFailedStep { return .failed }
        if hasWaitingStep { return .waiting }
        return .steps
    }

    /// One line for the compact phone transcript: current tool while working,
    /// then reasoning/tool counts and duration once the turn settles.
    func activitySummary(at now: Date) -> String {
        if let step = latestActiveStep {
            let detail = step.activitySummary.trimmingCharacters(in: .whitespacesAndNewlines)
            var live = [detail.isEmpty ? step.activityStatus : "\(step.activityStatus) \(detail)"]
            if let duration = durationText(at: now) { live.append(duration) }
            return live.joined(separator: " · ")
        }
        if state == .running {
            var live = [latestProcessText == nil ? "正在工作" : "正在回复"]
            if let duration = durationText(at: now) { live.append(duration) }
            return live.joined(separator: " · ")
        }
        var parts: [String] = []
        switch state {
        case .failed: parts.append("执行失败")
        case .interrupted: parts.append("已中断")
        default: break
        }
        if reasoningCount > 0 { parts.append("思考 \(reasoningCount)") }
        if toolCount > 0 { parts.append("工具 \(toolCount)") }
        if let duration = durationText(at: now) { parts.append(duration) }
        return parts.isEmpty ? "执行过程" : parts.joined(separator: " · ")
    }

    func durationText(at now: Date) -> String? {
        if let elapsed = processMessages.compactMap(\.elapsed).last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return elapsed
        }
        let dates = messages.map(\.createdAt)
        guard let start = dates.min() else { return nil }
        let end = isComplete ? (dates.max() ?? now) : now
        let seconds = max(0, Int(end.timeIntervalSince(start).rounded()))
        guard seconds > 0 else { return nil }
        if seconds < 60 { return "\(seconds) 秒" }
        let minutes = seconds / 60, remainder = seconds % 60
        return remainder == 0 ? "\(minutes) 分钟" : "\(minutes) 分 \(remainder) 秒"
    }
}
