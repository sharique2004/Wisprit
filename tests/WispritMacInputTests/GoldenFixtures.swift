import Foundation
@testable import WispritMacInput

/// GENERATED — every expectation here was produced by RUNNING the Python
/// this target ports (`wisprit/insert.py::_utf16_chunks` and
/// `wisprit/hotkey.py::HotkeyListener._callback`, the latter fed synthetic
/// CGEvents with no tap installed and nothing posted). Regenerate with:
///
///     ~/.meetingscribe/venv/bin/python \
///       /private/tmp/claude-501/-Users-shariquekhatri-Wisprit/\
///       08bd5841-5936-4964-a20b-5f526dba0b52/scratchpad/gen_input_goldens.py \
///       > tests/WispritMacInputTests/GoldenFixtures.swift
///
/// Do not hand-edit: a diff here is a real port divergence.
enum Golden {

    struct ChunkCase { let text: String; let chunks: [String] }

    /// `_utf16_chunks(text, 20)` from insert.py.
    static let chunkCases: [ChunkCase] = [
        ChunkCase(text: "", chunks: []),
        ChunkCase(text: "hello", chunks: ["hello"]),
        ChunkCase(text: "aaaaaaaaaaaaaaaaaaaa", chunks: ["aaaaaaaaaaaaaaaaaaaa"]),
        ChunkCase(text: "aaaaaaaaaaaaaaaaaaaaa", chunks: ["aaaaaaaaaaaaaaaaaaaa", "a"]),
        ChunkCase(text: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", chunks: ["aaaaaaaaaaaaaaaaaaaa", "aaaaaaaaaaaaaaaaaaaa", "aaaaa"]),
        ChunkCase(text: "The quick brown fox jumps over the lazy dog.", chunks: ["The quick brown fox ", "jumps over the lazy ", "dog."]),
        ChunkCase(text: "aaaaaaaaaaaaaaaaaaa😀", chunks: ["aaaaaaaaaaaaaaaaaaa", "😀"]),
        ChunkCase(text: "aaaaaaaaaaaaaaaaaa😀😀", chunks: ["aaaaaaaaaaaaaaaaaa😀", "😀"]),
        ChunkCase(text: "😀😀😀😀😀😀😀😀😀😀😀😀", chunks: ["😀😀😀😀😀😀😀😀😀😀", "😀😀"]),
        ChunkCase(text: "aaaaa👨‍👩‍👧‍👦bbbbb", chunks: ["aaaaa👨‍👩‍👧‍👦bbbb", "b"]),
        ChunkCase(text: "éclair café 日本語", chunks: ["éclair café 日本語"]),
        ChunkCase(text: "🇯🇵🇯🇵🇯🇵🇯🇵🇯🇵🇯🇵", chunks: ["🇯🇵🇯🇵🇯🇵🇯🇵🇯🇵", "🇯🇵"]),
        ChunkCase(text: "line one\nline two\ttab", chunks: ["line one\nline two\tta", "b"]),
        ChunkCase(text: "Sharique Khatri — InsForge, MeetingScribe; done.", chunks: ["Sharique Khatri — In", "sForge, MeetingScrib", "e; done."]),
    ]

    struct HotkeyCase {
        let name: String
        let trigger: TriggerKey
        let recording: Bool
        let steps: [TapInput]
        let emits: [HotkeyEventKind]
    }

    /// Each scenario replayed through the real `HotkeyListener._callback`.
    static let hotkeyCases: [HotkeyCase] = [
        HotkeyCase(name: "fn press then release",
                   trigger: .fn,
                   recording: false,
                   steps: [.flagsChanged(keycode: 63, flags: 0x800000), .flagsChanged(keycode: 63, flags: 0x0)],
                   emits: [.press, .release]),
        HotkeyCase(name: "fn flag on nav keys never arms",
                   trigger: .fn,
                   recording: false,
                   steps: [.flagsChanged(keycode: 126, flags: 0x800000), .flagsChanged(keycode: 123, flags: 0x800000), .flagsChanged(keycode: 63, flags: 0x800000), .flagsChanged(keycode: 63, flags: 0x0)],
                   emits: [.press, .release]),
        HotkeyCase(name: "keycode 63 without fn flag",
                   trigger: .fn,
                   recording: false,
                   steps: [.flagsChanged(keycode: 63, flags: 0x100000)],
                   emits: []),
        HotkeyCase(name: "dirty chord cancels and silences release",
                   trigger: .fn,
                   recording: false,
                   steps: [.flagsChanged(keycode: 63, flags: 0x800000), .keyDown(keycode: 123, flags: 0x800000), .flagsChanged(keycode: 63, flags: 0x0)],
                   emits: [.press, .cancel]),
        HotkeyCase(name: "second chord key emits nothing",
                   trigger: .fn,
                   recording: false,
                   steps: [.flagsChanged(keycode: 63, flags: 0x800000), .keyDown(keycode: 123, flags: 0x0), .keyDown(keycode: 124, flags: 0x0)],
                   emits: [.press, .cancel]),
        HotkeyCase(name: "trigger keycode keydown is not a chord",
                   trigger: .fn,
                   recording: false,
                   steps: [.flagsChanged(keycode: 63, flags: 0x800000), .keyDown(keycode: 63, flags: 0x800000), .flagsChanged(keycode: 63, flags: 0x0)],
                   emits: [.press, .release]),
        HotkeyCase(name: "esc while not recording",
                   trigger: .fn,
                   recording: false,
                   steps: [.keyDown(keycode: 53, flags: 0x0)],
                   emits: []),
        HotkeyCase(name: "esc while recording",
                   trigger: .fn,
                   recording: true,
                   steps: [.keyDown(keycode: 53, flags: 0x0)],
                   emits: [.esc]),
        HotkeyCase(name: "esc during hold is a chord",
                   trigger: .fn,
                   recording: true,
                   steps: [.flagsChanged(keycode: 63, flags: 0x800000), .keyDown(keycode: 53, flags: 0x0)],
                   emits: [.press, .cancel]),
        HotkeyCase(name: "cmd ctrl v pastes last",
                   trigger: .fn,
                   recording: false,
                   steps: [.keyDown(keycode: 9, flags: 0x140000)],
                   emits: [.pasteLast]),
        HotkeyCase(name: "cmd v alone is ignored",
                   trigger: .fn,
                   recording: false,
                   steps: [.keyDown(keycode: 9, flags: 0x100000), .keyDown(keycode: 9, flags: 0x40000), .keyDown(keycode: 9, flags: 0x0)],
                   emits: []),
        HotkeyCase(name: "cmd ctrl shift v still pastes",
                   trigger: .fn,
                   recording: false,
                   steps: [.keyDown(keycode: 9, flags: 0x160000)],
                   emits: [.pasteLast]),
        HotkeyCase(name: "cmd ctrl v during hold is a chord",
                   trigger: .fn,
                   recording: false,
                   steps: [.flagsChanged(keycode: 63, flags: 0x800000), .keyDown(keycode: 9, flags: 0x140000)],
                   emits: [.press, .cancel]),
        HotkeyCase(name: "repeat flags while held",
                   trigger: .fn,
                   recording: false,
                   steps: [.flagsChanged(keycode: 63, flags: 0x800000), .flagsChanged(keycode: 63, flags: 0x820000), .flagsChanged(keycode: 63, flags: 0x0)],
                   emits: [.press, .release]),
        HotkeyCase(name: "release without press",
                   trigger: .fn,
                   recording: false,
                   steps: [.flagsChanged(keycode: 63, flags: 0x0)],
                   emits: []),
        HotkeyCase(name: "tap disabled mid hold",
                   trigger: .fn,
                   recording: false,
                   steps: [.flagsChanged(keycode: 63, flags: 0x800000), .tapDisabled(reason: .timeout), .flagsChanged(keycode: 63, flags: 0x0)],
                   emits: [.press, .cancel]),
        HotkeyCase(name: "tap disabled by user input mid hold",
                   trigger: .fn,
                   recording: false,
                   steps: [.flagsChanged(keycode: 63, flags: 0x800000), .tapDisabled(reason: .userInput)],
                   emits: [.press, .cancel]),
        HotkeyCase(name: "tap disabled while idle",
                   trigger: .fn,
                   recording: false,
                   steps: [.tapDisabled(reason: .timeout)],
                   emits: []),
        HotkeyCase(name: "tap disabled after chord does not double cancel",
                   trigger: .fn,
                   recording: false,
                   steps: [.flagsChanged(keycode: 63, flags: 0x800000), .keyDown(keycode: 123, flags: 0x0), .tapDisabled(reason: .timeout)],
                   emits: [.press, .cancel]),
        HotkeyCase(name: "right option press release",
                   trigger: .rightOption,
                   recording: false,
                   steps: [.flagsChanged(keycode: 61, flags: 0x80000), .flagsChanged(keycode: 61, flags: 0x0)],
                   emits: [.press, .release]),
        HotkeyCase(name: "right option ignores left option keycode",
                   trigger: .rightOption,
                   recording: false,
                   steps: [.flagsChanged(keycode: 58, flags: 0x80000)],
                   emits: []),
        HotkeyCase(name: "right option masking bug with left option held",
                   trigger: .rightOption,
                   recording: false,
                   steps: [.flagsChanged(keycode: 58, flags: 0x80000), .flagsChanged(keycode: 61, flags: 0x80000), .flagsChanged(keycode: 61, flags: 0x80000), .flagsChanged(keycode: 61, flags: 0x0)],
                   emits: [.press, .release]),
        HotkeyCase(name: "fn ignores right option events",
                   trigger: .fn,
                   recording: false,
                   steps: [.flagsChanged(keycode: 61, flags: 0x80000), .flagsChanged(keycode: 61, flags: 0x0)],
                   emits: []),
    ]
}
