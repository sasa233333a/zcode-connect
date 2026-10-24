import XCTest
@testable import ZCodeMobile

@MainActor
final class MessageRenderingTests: XCTestCase {
    private func links(in blocks: [MessageTextBlock]) -> [String] {
        var result: [String] = []
        for case .prose(_, let content) in blocks {
            for run in content.runs {
                if let link = content[run.range].link {
                    result.append(link.absoluteString)
                }
            }
        }
        return result
    }

    func testBareURLIsPromotedToLink() {
        let links = links(in: MessageTextCache.parse(text: "See https://example.com/docs for details", user: false))
        XCTAssertEqual(links, ["https://example.com/docs"])
    }

    func testMarkdownLinkRemainsTappable() {
        let links = links(in: MessageTextCache.parse(text: "[Apple](https://www.apple.com)", user: false))
        XCTAssertEqual(links, ["https://www.apple.com"])
    }
}
