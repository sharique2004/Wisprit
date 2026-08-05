import XCTest
@testable import WispritMacUI

/// Pure menu-model tests — the structure `app.py`'s `_rebuild_menu` produces,
/// asserted without ever creating an NSStatusItem.
final class StatusMenuModelTests: XCTestCase {

    private func titles(_ items: [MenuItemModel]) -> [String] {
        items.map { $0.isSeparator ? "---" : $0.title }
    }

    // MARK: - glyphs

    func testStateGlyphs() {
        XCTAssertEqual(StatusMenuModel.glyph(for: .idle), "🎙")
        XCTAssertEqual(StatusMenuModel.glyph(for: .recording), "🔴")
        XCTAssertEqual(StatusMenuModel.glyph(for: .finalizing), "…")
        XCTAssertEqual(StatusMenuModel.glyph(for: .inserting), "⌨")
        XCTAssertEqual(StatusMenuModel.glyph(forStateNamed: "recording"), "🔴")
        XCTAssertEqual(StatusMenuModel.glyph(forStateNamed: "nonsense"), "🎙",
                       "_STATE_GLYPH.get(state, '🎙')")
    }

    // MARK: - eliding

    func testElideMatchesPythonBudget() {
        XCTAssertEqual(StatusMenuModel.elide("short one"), "short one")

        let exactly48 = String(repeating: "a", count: 48)
        XCTAssertEqual(StatusMenuModel.elide(exactly48), exactly48, "48 is not > 48")

        let long = String(repeating: "b", count: 60)
        let elided = StatusMenuModel.elide(long)
        XCTAssertEqual(elided.count, 48)
        XCTAssertEqual(elided, String(repeating: "b", count: 47) + "…")
    }

    func testElideFlattensNewlinesOnly() {
        XCTAssertEqual(StatusMenuModel.elide("line one\nline two"), "line one line two")
        XCTAssertEqual(StatusMenuModel.elide("double  spaced"), "double  spaced",
                       "the Python only replaces \\n; inner runs survive")
    }

    // MARK: - full structure

    func testDefaultMenuStructure() {
        let items = StatusMenuModel.build(StatusMenuState(
            dictationEnabled: true, aiCleanupEnabled: true, aiAvailability: nil, recents: []))
        XCTAssertEqual(titles(items), [
            "Dictation On",
            "AI Cleanup (Apple Intelligence)",
            "---",
            "Recent transcripts",
            "  (none yet)",
            "---",
            "Paste Last Transcript  (⌘⌃V)",
            "Open Dictionary…",
            "Open Config…",
            "Run Doctor…",
            "Purge History",
            "---",
            "Quit Wisprit",
        ])
    }

    func testDictationToggleTitleAndCheckmark() {
        let on = StatusMenuModel.build(StatusMenuState(dictationEnabled: true))[0]
        XCTAssertEqual(on.title, "Dictation On")
        XCTAssertTrue(on.isChecked)
        XCTAssertEqual(on.action, .toggleDictation)

        let off = StatusMenuModel.build(StatusMenuState(dictationEnabled: false))[0]
        XCTAssertEqual(off.title, "Dictation Off")
        XCTAssertFalse(off.isChecked)
    }

    // MARK: - AI Cleanup tri-state

    func testAiCleanupShownWhileProbing() {
        let row = StatusMenuModel.build(
            StatusMenuState(aiCleanupEnabled: true, aiAvailability: nil))[1]
        XCTAssertEqual(row.title, "AI Cleanup (Apple Intelligence)")
        XCTAssertEqual(row.action, .toggleAiCleanup)
        XCTAssertTrue(row.isEnabled)
        XCTAssertTrue(row.isChecked)
    }

    func testAiCleanupShownWhenAvailableAndUnchecked() {
        let row = StatusMenuModel.build(
            StatusMenuState(aiCleanupEnabled: false, aiAvailability: true))[1]
        XCTAssertEqual(row.title, "AI Cleanup (Apple Intelligence)")
        XCTAssertFalse(row.isChecked)
        XCTAssertEqual(row.action, .toggleAiCleanup)
    }

    func testAiCleanupReplacedByDisabledRowWhenUnavailable() {
        let row = StatusMenuModel.build(
            StatusMenuState(aiCleanupEnabled: true, aiAvailability: false))[1]
        XCTAssertEqual(row.title, "AI Cleanup unavailable — run Doctor")
        XCTAssertNil(row.action)
        XCTAssertFalse(row.isEnabled)
        XCTAssertFalse(row.isChecked)
    }

    // MARK: - recents

    func testRecentsAreIndentedElidedAndCarryTheFullText() {
        let long = String(repeating: "z", count: 60)
        let items = StatusMenuModel.build(StatusMenuState(recents: ["hello world", long]))
        let recents = items.filter {
            if case .copyRecent = $0.action { return true } else { return false }
        }
        XCTAssertEqual(recents.count, 2)
        XCTAssertEqual(recents[0].title, "  hello world")
        XCTAssertEqual(recents[0].action, .copyRecent(index: 0))
        XCTAssertEqual(recents[0].representedText, "hello world")
        XCTAssertEqual(recents[1].title, "  " + String(repeating: "z", count: 47) + "…")
        XCTAssertEqual(recents[1].representedText, long, "the clipboard gets the whole thing")
        XCTAssertTrue(recents.allSatisfy { $0.isEnabled })
    }

    func testRecentsAreCappedAtFive() {
        let items = StatusMenuModel.build(
            StatusMenuState(recents: (1...9).map { "utterance \($0)" }))
        let recents = items.filter {
            if case .copyRecent = $0.action { return true } else { return false }
        }
        XCTAssertEqual(recents.count, 5)
        XCTAssertEqual(recents.first?.title, "  utterance 1")
        XCTAssertEqual(recents.last?.action, .copyRecent(index: 4))
    }

    func testRecentHeaderIsAlwaysAnInertRow() {
        let items = StatusMenuModel.build(StatusMenuState(recents: ["a"]))
        let header = items.first { $0.title == "Recent transcripts" }
        XCTAssertNotNil(header)
        XCTAssertNil(header?.action)
        XCTAssertFalse(header?.isEnabled ?? true)
    }

    func testEmptyStateRowIsInert() {
        let items = StatusMenuModel.build(StatusMenuState(recents: []))
        let none = items.first { $0.title == "  (none yet)" }
        XCTAssertNotNil(none)
        XCTAssertNil(none?.action)
        XCTAssertFalse(none?.isEnabled ?? true)
    }

    // MARK: - invariants

    func testEveryActionRowIsEnabledAndEveryInertRowIsNot() {
        for availability in [nil, true, false] as [Bool?] {
            let items = StatusMenuModel.build(StatusMenuState(
                aiAvailability: availability, recents: ["one", "two"]))
            for item in items where !item.isSeparator {
                if item.action == nil {
                    XCTAssertFalse(item.isEnabled, "inert row '\(item.title)' must be disabled")
                } else {
                    XCTAssertTrue(item.isEnabled, "action row '\(item.title)' must be enabled")
                }
            }
        }
    }

    func testTailActionsArePresentExactlyOnce() {
        let items = StatusMenuModel.build(StatusMenuState())
        let actions = items.compactMap(\.action)
        for expected: MenuAction in [.pasteLast, .openDictionary, .openConfig,
                                     .runDoctor, .purgeHistory, .quit] {
            XCTAssertEqual(actions.filter { $0 == expected }.count, 1, "\(expected)")
        }
    }

    func testThreeSeparators() {
        XCTAssertEqual(StatusMenuModel.build(StatusMenuState()).filter(\.isSeparator).count, 3)
    }
}
