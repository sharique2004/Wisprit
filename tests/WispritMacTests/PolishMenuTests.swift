import XCTest
import WispritMacUI
import WispritPolish
@testable import WispritMac

/// The "Polish Last" menu glue: what the submenu offers and what the pill says.
final class PolishMenuTests: XCTestCase {

    func testModeItemsMatchThePythonKeysAndLabelsExactly() {
        XCTAssertEqual(PolishMenu.modeItems, [
            PolishModeItem(key: "clean", label: "Clean up"),
            PolishModeItem(key: "formal", label: "Make formal"),
            PolishModeItem(key: "casual", label: "Make casual"),
            PolishModeItem(key: "prompt", label: "As an AI prompt"),
        ])
    }

    func testEveryModeIsOffered() {
        XCTAssertEqual(PolishMenu.modeItems.count, PolishMode.allCases.count)
    }

    func testARepresentedObjectFromAnOlderBuildStillResolves() {
        for item in PolishMenu.modeItems {
            XCTAssertEqual(PolishMode.named(item.key).rawValue, item.key)
        }
        XCTAssertEqual(PolishMode.named("something-else"), .cleanUp,
                       "unknown modes fall back to clean, exactly as polish.py did")
    }

    func testSuccessNoticeTellsTheUserWhereTheTextWent() {
        // Polish lands on the clipboard, not in the field — the notice has to
        // say so or the user will look for text that is not there.
        XCTAssertEqual(PolishMenu.successNotice(for: .makeFormal), "Make formal — ⌘V to paste")
        for mode in PolishMode.allCases {
            XCTAssertTrue(PolishMenu.successNotice(for: mode).hasSuffix("⌘V to paste"))
        }
    }

    func testFailureNoticeIsTheCagesOwnWording() {
        let result = PolishResult.failure(.tooLong(350))
        XCTAssertEqual(PolishMenu.failureNotice(for: result),
                       "Transcript is too long to polish (350-word limit).")
        XCTAssertNil(PolishMenu.failureNotice(for: .success("ok")))
    }
}
