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

    private static let modes = [
        PolishModeItem(key: "clean", label: "Clean up"),
        PolishModeItem(key: "formal", label: "Make formal"),
        PolishModeItem(key: "casual", label: "Make casual"),
        PolishModeItem(key: "prompt", label: "As an AI prompt"),
    ]

    func testDefaultMenuStructure() {
        let items = StatusMenuModel.build(StatusMenuState(
            dictationEnabled: true, aiCleanupEnabled: true, aiAvailability: nil, recents: [],
            polishModes: StatusMenuModelTests.modes))
        XCTAssertEqual(titles(items), [
            "Open Wisprit…",
            "---",
            "Dictation On",
            "AI Cleanup (Apple Intelligence)",
            "Polish Last",
            "Enable Live Typing…",
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

    /// A menu-bar-only app whose icon can hide behind the notch needs a way back
    /// to itself, and it has to be the first thing in the menu.
    func testOpenWindowIsTheFirstRow() {
        let items = StatusMenuModel.build(StatusMenuState())
        XCTAssertEqual(items[0].title, "Open Wisprit…")
        XCTAssertEqual(items[0].action, .openWindow)
        XCTAssertTrue(items[0].isEnabled)
        XCTAssertTrue(items[1].isSeparator)
        XCTAssertEqual(items.compactMap(\.action).filter { $0 == .openWindow }.count, 1)
    }

    func testDictationToggleTitleAndCheckmark() {
        let on = StatusMenuModel.build(StatusMenuState(dictationEnabled: true))[2]
        XCTAssertEqual(on.title, "Dictation On")
        XCTAssertTrue(on.isChecked)
        XCTAssertEqual(on.action, .toggleDictation)

        let off = StatusMenuModel.build(StatusMenuState(dictationEnabled: false))[2]
        XCTAssertEqual(off.title, "Dictation Off")
        XCTAssertFalse(off.isChecked)
    }

    // MARK: - AI Cleanup tri-state

    func testAiCleanupShownWhileProbing() {
        let row = StatusMenuModel.build(
            StatusMenuState(aiCleanupEnabled: true, aiAvailability: nil))[3]
        XCTAssertEqual(row.title, "AI Cleanup (Apple Intelligence)")
        XCTAssertEqual(row.action, .toggleAiCleanup)
        XCTAssertTrue(row.isEnabled)
        XCTAssertTrue(row.isChecked)
    }

    func testAiCleanupShownWhenAvailableAndUnchecked() {
        let row = StatusMenuModel.build(
            StatusMenuState(aiCleanupEnabled: false, aiAvailability: true))[3]
        XCTAssertEqual(row.title, "AI Cleanup (Apple Intelligence)")
        XCTAssertFalse(row.isChecked)
        XCTAssertEqual(row.action, .toggleAiCleanup)
    }

    func testAiCleanupReplacedByDisabledRowWhenUnavailable() {
        let row = StatusMenuModel.build(
            StatusMenuState(aiCleanupEnabled: true, aiAvailability: false))[3]
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
                aiAvailability: availability, recents: ["one", "two"],
                polishAvailability: availability,
                polishModes: StatusMenuModelTests.modes))
            for item in items where !item.isSeparator {
                if item.isSubmenu {
                    XCTAssertNil(item.action, "a parent row carries no action of its own")
                    XCTAssertTrue(item.isEnabled, "submenu row '\(item.title)' must be enabled")
                } else if item.action == nil {
                    XCTAssertFalse(item.isEnabled, "inert row '\(item.title)' must be disabled")
                } else {
                    XCTAssertTrue(item.isEnabled, "action row '\(item.title)' must be enabled")
                }
            }
        }
    }

    // MARK: - Polish Last

    func testPolishSubmenuCarriesTheFourPythonModeKeys() {
        let row = StatusMenuModel.build(
            StatusMenuState(polishModes: StatusMenuModelTests.modes))[4]
        XCTAssertEqual(row.title, "Polish Last")
        XCTAssertNil(row.action, "the parent row is a container")
        XCTAssertTrue(row.isEnabled)
        let children = row.submenu ?? []
        XCTAssertEqual(children.map(\.title),
                       ["Clean up", "Make formal", "Make casual", "As an AI prompt"])
        XCTAssertEqual(children.map(\.action), [
            .polishLast(mode: "clean"), .polishLast(mode: "formal"),
            .polishLast(mode: "casual"), .polishLast(mode: "prompt"),
        ])
        XCTAssertEqual(children.map(\.representedText),
                       ["clean", "formal", "casual", "prompt"],
                       "the represented object stays byte-compatible with polish.py's MODES")
    }

    func testPolishShownWhileProbingJustLikeAiCleanup() {
        let row = StatusMenuModel.build(StatusMenuState(
            polishAvailability: nil, polishModes: StatusMenuModelTests.modes))[4]
        XCTAssertTrue(row.isSubmenu)
    }

    func testPolishReplacedByDisabledRowWhenUnavailable() {
        let row = StatusMenuModel.build(StatusMenuState(
            polishAvailability: false,
            polishUnavailableReason: "Apple Intelligence is off",
            polishModes: StatusMenuModelTests.modes))[4]
        XCTAssertEqual(row.title, "Polish Last unavailable — Apple Intelligence is off")
        XCTAssertNil(row.action)
        XCTAssertNil(row.submenu)
        XCTAssertFalse(row.isEnabled)
    }

    func testPolishUnavailableWithoutAReasonPointsAtDoctor() {
        let row = StatusMenuModel.build(StatusMenuState(polishAvailability: false))[4]
        XCTAssertEqual(row.title, "Polish Last unavailable — run Doctor")
    }

    func testPolishWithNoModesIsInertRatherThanAnEmptySubmenu() {
        let row = StatusMenuModel.build(StatusMenuState(polishModes: []))[4]
        XCTAssertNil(row.submenu)
        XCTAssertFalse(row.isEnabled)
    }

    // MARK: - Live typing

    func testLiveTypingRowReflectsEachStageOfOnboarding() {
        func row(_ status: LiveTypingMenuStatus) -> MenuItemModel {
            StatusMenuModel.build(StatusMenuState(liveTyping: status))[5]
        }

        XCTAssertEqual(row(.notInstalled).title, "Enable Live Typing…")
        XCTAssertEqual(row(.notInstalled).action, .enableLiveTyping)
        XCTAssertEqual(row(.needsEnable).action, .enableLiveTyping)
        XCTAssertEqual(row(.needsUpdate).title, "Update Live Typing…")
        XCTAssertEqual(row(.needsUpdate).action, .enableLiveTyping)

        XCTAssertEqual(row(.readyOff).title, "Live Typing")
        XCTAssertEqual(row(.readyOff).action, .toggleLiveTyping)
        XCTAssertFalse(row(.readyOff).isChecked)
        XCTAssertTrue(row(.readyOn).isChecked)
        XCTAssertEqual(row(.readyOn).action, .toggleLiveTyping)

        XCTAssertNil(row(.probing).action)
        XCTAssertNil(row(.unsupported).action)
        XCTAssertEqual(row(.unsupported).title, "Live Typing unavailable — run Doctor")
    }

    func testEnablingLiveTypingIsNeverOfferedTwiceInOneMenu() {
        for status in LiveTypingMenuStatus.allCases {
            let actions = StatusMenuModel.build(StatusMenuState(liveTyping: status))
                .compactMap(\.action)
            XCTAssertLessThanOrEqual(actions.filter { $0 == .enableLiveTyping }.count, 1,
                                     "\(status)")
        }
    }

    func testTailActionsArePresentExactlyOnce() {
        let items = StatusMenuModel.build(StatusMenuState(
            polishModes: StatusMenuModelTests.modes))
        let actions = items.compactMap(\.action)
        for expected: MenuAction in [.pasteLast, .openDictionary, .openConfig,
                                     .runDoctor, .purgeHistory, .quit] {
            XCTAssertEqual(actions.filter { $0 == expected }.count, 1, "\(expected)")
        }
    }

    func testThreeSeparators() {
        XCTAssertEqual(StatusMenuModel.build(StatusMenuState()).filter(\.isSeparator).count, 4)
    }
}
