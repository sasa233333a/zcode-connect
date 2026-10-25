import XCTest
@testable import ZCodeMobile

final class ConversationDensityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func process(_ steps: [ToolStep] = [], reasoning: String? = nil,
                         status: TranscriptMessageSemantics.State = .completed,
                         text: String = "", elapsed: String? = nil) -> ChatMessage {
        ChatMessage(id: "process", role: .assistant, text: text,
                    createdAt: now.addingTimeInterval(-12), elapsed: elapsed, steps: steps,
                    reasoning: reasoning,
                    transcript: .init(turnID: "t", state: status, role: .process))
    }

    private func turn(_ process: ChatMessage, result: String? = nil,
                      state: TranscriptMessageSemantics.State = .completed) -> TranscriptTurn {
        var results: [ChatMessage] = []
        if let result {
            results = [ChatMessage(id: "result", role: .assistant, text: result, createdAt: now,
                                   transcript: .init(turnID: "t", state: state, role: .finalAnswer))]
        }
        return TranscriptTurn(id: "turn:t", messages: [process] + results, userMessages: [],
                              processMessages: [process], resultMessages: results, state: state)
    }

    func testCompletedTurnSummarizesReasoningToolsAndDuration() {
        let value = turn(process([
            ToolStep(id: "read", title: "Read", detail: "", inputJSON: #"{"path":"/tmp/A.swift"}"#),
            ToolStep(id: "bash", title: "Bash", detail: "", inputJSON: #"{"command":"swift test"}"#)
        ], reasoning: "Check the failing test", elapsed: "12 秒"), result: "Fixed.")
        XCTAssertEqual(value.activitySummary(at: now), "思考 1 · 工具 2 · 12 秒")
        XCTAssertFalse(value.needsAttention)
        XCTAssertFalse(ConversationDensity.concise.expandsProcess(for: value))
        XCTAssertFalse(ConversationDensity.standard.expandsProcess(for: value))
        XCTAssertTrue(ConversationDensity.detailed.expandsProcess(for: value))
    }

    func testRunningTurnShowsOnlyCurrentToolAndElapsedTime() {
        let value = turn(process([
            ToolStep(id: "bash", title: "Bash", detail: "", status: .running,
                     inputJSON: #"{"command":"swift test"}"#)
        ], status: .running), state: .running)
        XCTAssertEqual(value.activitySummary(at: now), "正在运行 swift test · 12 秒")
        XCTAssertFalse(value.needsAttention)
        XCTAssertFalse(ConversationDensity.concise.expandsProcess(for: value))
        XCTAssertTrue(ConversationDensity.standard.expandsProcess(for: value))
    }

    func testWaitingToolKeepsAttentionVisibleInConciseMode() {
        let value = turn(process([
            ToolStep(id: "bash", title: "Bash", detail: "", status: .waiting,
                     inputJSON: #"{"command":"rm -rf build"}"#)
        ], status: .running), state: .running)
        XCTAssertTrue(value.needsAttention)
        XCTAssertTrue(ConversationDensity.concise.expandsProcess(for: value))
        XCTAssertTrue(value.activitySummary(at: now).hasPrefix("等待确认 rm -rf build"))
    }

    func testFailedStepExpandsInConciseMode() {
        let value = turn(process([
            ToolStep(id: "bash", title: "Bash", detail: "", status: .failed)
        ], status: .failed), state: .failed)
        XCTAssertTrue(value.needsAttention)
        XCTAssertTrue(ConversationDensity.concise.expandsProcess(for: value))
        XCTAssertTrue(value.activitySummary(at: now).hasPrefix("执行失败"))
    }

    func testRunningTurnWithoutToolsShowsReplyAndComputesDuration() {
        let value = turn(process(status: .running, text: "Working on it"), state: .running)
        XCTAssertEqual(value.latestProcessText?.text, "Working on it")
        XCTAssertEqual(value.activitySummary(at: now), "正在回复 · 12 秒")
    }
}
