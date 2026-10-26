import XCTest

final class ComposerSuggestionUITests: XCTestCase {
    private func launch(_ screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--reference", "--screen", screen]
        app.launch()
        return app
    }

    private func composerValue(_ app: XCUIApplication) -> String {
        let field = app.descendants(matching: .any).matching(identifier: "composer.text").firstMatch
        return field.value as? String ?? ""
    }

    func testSlashSuggestionsUseFloatingPanel() {
        let app = launch("slash-review")
        let review = app.buttons["composer.slashSuggestion.review"]
        XCTAssertTrue(review.waitForExistence(timeout: 60), app.debugDescription)
        XCTAssertTrue(app.staticTexts["/review"].exists)
        XCTAssertTrue(app.staticTexts["检查当前改动 · [范围]"].exists)

        review.tap()
        XCTAssertEqual(composerValue(app), "/review ")
        XCTAssertTrue(review.waitForNonExistence(timeout: 5))
    }

    func testMentionSuggestionsUseFloatingPanel() {
        let app = launch("mention-review")
        let folder = app.buttons["composer.mentionSuggestion.DemoApp"]
        XCTAssertTrue(folder.waitForExistence(timeout: 60), app.debugDescription)
        XCTAssertTrue(app.staticTexts["DemoApp"].exists)

        folder.tap()
        XCTAssertTrue(composerValue(app).hasPrefix("@DemoApp/"), composerValue(app))
        XCTAssertTrue(folder.waitForNonExistence(timeout: 5))
    }
}
