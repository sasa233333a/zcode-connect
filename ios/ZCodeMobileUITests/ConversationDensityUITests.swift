import XCTest

final class ConversationDensityUITests: XCTestCase {
    private func launch(_ density: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--reference", "--screen", "turn-review", "--conversation-density", density]
        app.launch()
        return app
    }

    func testConciseSummaryExpandsProcessOnDemand() {
        let app = launch("concise")
        let summary = app.buttons["turn.process.turn:review-completed"]
        XCTAssertTrue(summary.waitForExistence(timeout: 60), app.debugDescription)
        XCTAssertFalse(app.staticTexts["思考过程"].exists)
        XCTAssertTrue(app.staticTexts["星期五 21:53"].waitForExistence(timeout: 5),
                      "Concise mode keeps the message time in the chat pane")

        summary.tap()
        XCTAssertTrue(app.staticTexts["我先核对源码和测试记录。"].waitForExistence(timeout: 5))
        XCTAssertEqual(summary.value as? String, "已展开")
        XCTAssertTrue(app.buttons["回复操作"].exists)
    }

    func testStandardModeKeepsInlineReplyActions() {
        let app = launch("standard")
        XCTAssertTrue(app.staticTexts["星期五 21:53"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.buttons["复制回复"].exists, "Standard mode keeps the inline action row")
        XCTAssertFalse(app.buttons["回复操作"].exists, "Standard mode has no compact overflow menu")
    }
}
