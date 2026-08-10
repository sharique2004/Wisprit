import XCTest
import WispritEval
@testable import WispritMac

/// `Wisprit eval record` / `eval verify` — the script grammar, the resume rule,
/// the clip naming, the split rule, the WAVE header, and the review decisions.
///
/// Nothing here opens a microphone. That is not a compromise, it is the design:
/// a recording session is an hour of somebody's voice that cannot be replayed
/// from a cache, so everything that can be wrong about one was pushed into pure
/// types and the interactive shells were left with a `readLine` loop. What a
/// live session would add over these tests is the tap itself, which is
/// `MicCapture` and already the live path's own.
///
/// The last test in this file parses the 13 shipped `human-v1` scripts, so a
/// typo in a directive fails `swift test` rather than a recording session.
final class EvalRecordTests: XCTestCase {

    // MARK: - the script grammar

    func testAPlainLineIsItsOwnReference() throws {
        let script = try EvalScript.parse("""
            # category: homophones
            # Pace: normal.

            They said their flight lands at noon.
            It's been running for three days.
            """, name: "05-homophones.txt")

        XCTAssertEqual(script.category, "homophones")
        XCTAssertEqual(script.prefix, "ho")
        XCTAssertEqual(script.directions, ["Pace: normal."])
        XCTAssertEqual(script.lines.map(\.clipID), ["ho-01", "ho-02"])
        XCTAssertEqual(script.lines.first?.spoken, "They said their flight lands at noon.")
        XCTAssertEqual(script.lines.first?.ref, script.lines.first?.spoken)
        XCTAssertEqual(script.lines.first?.terms, [])
        XCTAssertNil(script.lines.first?.refineBypass)
        XCTAssertNil(script.lines.first?.expectation,
                     "a line that expects nothing must carry no expectation at all")
    }

    func testDirectivesAreStrippedBeforeTheTextIsUsed() throws {
        let script = try EvalScript.parse("""
            # category: spelled-runs
            The payload is J-S-O-N, not YAML.|bypass=has_letter_run|ref=The payload is JSON, not YAML.
            Hi Sharique, add this to Wisprit.|terms=Sharique, Wisprit
            """, name: "s.txt")

        let spelled = try XCTUnwrap(script.lines.first)
        XCTAssertEqual(spelled.spoken, "The payload is J-S-O-N, not YAML.")
        XCTAssertEqual(spelled.ref, "The payload is JSON, not YAML.")
        XCTAssertEqual(spelled.expectation, CorpusExpectation(refineBypass: "has_letter_run"))

        let named = try XCTUnwrap(script.lines.last)
        XCTAssertEqual(named.spoken, "Hi Sharique, add this to Wisprit.")
        XCTAssertEqual(named.ref, named.spoken, "no ref= means the line is the reference")
        XCTAssertEqual(named.terms, ["Sharique", "Wisprit"], "terms are split and trimmed")
    }

    /// A suffix is a directive only when it spells `|<lowercase-word>=`. Text
    /// that merely contains a pipe is text — a reading script is prose and the
    /// separator must not be able to eat a sentence.
    func testABarePipeInTheSentenceSurvives() throws {
        let script = try EvalScript.parse("""
            # category: tech-jargon
            Pipe it through grep | head and see what comes out.
            Run cat foo | wc -l first.|terms=grep
            """, name: "t.txt")
        XCTAssertEqual(script.lines.first?.ref, "Pipe it through grep | head and see what comes out.")
        XCTAssertEqual(script.lines.last?.ref, "Run cat foo | wc -l first.")
        XCTAssertEqual(script.lines.last?.terms, ["grep"])
    }

    /// The typo case, and the reason unknown keys are refused rather than kept
    /// as text: `|term=Wisprit` would otherwise be read aloud AND scored.
    func testAMisspelledDirectiveIsAFailureNotText() {
        assertScriptError("""
            # category: proper-nouns
            Hi Sharique.|term=Sharique
            """, contains: ["unknown directive", "term"])
    }

    func testEveryOtherWayAScriptCanBeWrong() {
        assertScriptError("Hi Sharique.", contains: ["# category:"])
        assertScriptError("# pace: normal\nHi.", contains: ["# category:"])
        assertScriptError("# category: Proper Nouns\nHi.", contains: ["lowercase letters"])
        assertScriptError("# category: proper-nouns\n", contains: ["no utterances"])
        assertScriptError("# category: proper-nouns\nHi.|terms=", contains: ["no value"])
        assertScriptError("# category: proper-nouns\nHi.|terms= , ", contains: ["no value"])
        assertScriptError("# category: addresses\nShip it.|bypass=timeout",
                          contains: ["bypass", "has_address"])
        assertScriptError("# category: proper-nouns\nHi.|terms=A|terms=B",
                          contains: ["given twice"])
        assertScriptError("# category: proper-nouns\n|terms=A", contains: ["read aloud"])
    }

    /// `bypass` is an allowlist and not `RefineOutcome(rawValue:)` on purpose:
    /// `timeout` is a real outcome and a meaningless expectation, and a script
    /// must not be able to assert something that can only ever fail.
    func testOnlyTheTwoBypassesAnUtteranceCanAssertAreAccepted() {
        XCTAssertEqual(EvalScript.knownBypasses, ["has_address", "has_letter_run"])
    }

    /// The prefix is derived, so a new script file cannot forget to declare one
    /// — and `validate` is what makes a derivation that can collide safe.
    func testCategoryPrefixes() {
        let expected = [
            "proper-nouns": "pn", "control-names": "cn", "product-terms": "pt",
            "tech-jargon": "tj", "homophones": "ho", "addresses": "ad",
            "postal-address": "pa", "spelled-runs": "sr", "numbers-dates": "nd",
            "spoken-commands": "sc", "disfluent-speech": "ds", "long-form": "lf",
            "adversarial-quiet": "aq",
        ]
        for (category, prefix) in expected {
            XCTAssertEqual(EvalScript.prefix(for: category), prefix, category)
        }
        XCTAssertEqual(Set(expected.values).count, expected.count, "the shipped set must not collide")
        XCTAssertEqual(EvalScript.clipID(prefix: "pn", index: 7), "pn-07")
        XCTAssertEqual(EvalScript.clipID(prefix: "pn", index: 130), "pn-130")
    }

    func testCollidingPrefixesAreRefused() {
        let files = [
            EvalScript.File(category: "proper-nouns", prefix: "pn", directions: [], lines: []),
            EvalScript.File(category: "postal-notes", prefix: "pn", directions: [], lines: []),
        ]
        XCTAssertThrowsError(try EvalScript.validate(files)) { error in
            XCTAssertEqual(error as? EvalScript.ScriptError,
                           .prefixCollision(prefix: "pn",
                                            categories: ["postal-notes", "proper-nouns"]))
        }
    }

    // MARK: - naming

    /// The clip id is category + index and is what the reader sees. The manifest
    /// id has to be more: the corpus holds every speaker's take of `pn-01`, plus
    /// one per microphone, and `Corpus.parse` refuses duplicates.
    func testTheManifestIdSeparatesSpeakersAndMicrophones() {
        let internalMic = EvalRecordPlan.manifestID(speaker: "spk01", mic: "internal",
                                                    clipID: "pn-01")
        XCTAssertEqual(internalMic, "spk01.internal.pn-01")
        XCTAssertEqual(EvalRecordPlan.audioPath(speaker: "spk01", id: internalMic),
                       "audio/spk01/spk01.internal.pn-01.wav")

        let ids = Set([
            internalMic,
            EvalRecordPlan.manifestID(speaker: "spk01", mic: "airpods-pro", clipID: "pn-01"),
            EvalRecordPlan.manifestID(speaker: "spk02", mic: "internal", clipID: "pn-01"),
        ])
        XCTAssertEqual(ids.count, 3, "the same line on another mic or speaker is a NEW clip")
    }

    func testLabelsBecomeSafeIdComponents() {
        XCTAssertEqual(EvalRecordPlan.slug("AirPods Pro"), "airpods-pro")
        XCTAssertEqual(EvalRecordPlan.slug("  MacBook   internal  "), "macbook-internal")
        XCTAssertEqual(EvalRecordPlan.slug("spk01"), "spk01")
        // ASCII only: an accent that is precomposed on one machine and
        // decomposed on another would be two ids for one microphone.
        XCTAssertEqual(EvalRecordPlan.slug("internal/café"), "internal-caf")
        XCTAssertEqual(EvalRecordPlan.slug("!!!"), "", "an unusable label must read as empty")
    }

    // MARK: - the split

    func testTheSplitIsBySpeaker() {
        XCTAssertEqual(EvalRecordPlan.split(forSpeaker: "spk01"), "dev")
        XCTAssertEqual(EvalRecordPlan.split(forSpeaker: "spk02"), "held")
        XCTAssertEqual(EvalRecordPlan.split(forSpeaker: "spk09"), "held")
        // The override is for a speaker joining an existing side, and it wins
        // in both directions.
        XCTAssertEqual(EvalRecordPlan.split(forSpeaker: "spk01", override: "held"), "held")
        XCTAssertEqual(EvalRecordPlan.split(forSpeaker: "spk04", override: "dev"), "dev")
    }

    /// The manifest carries the split, so the partition survives the session
    /// that produced it — and an unsplit clip (the synthetic corpus) joins
    /// neither side rather than defaulting into held.
    func testTheCorpusPartitionsOnTheManifestField() {
        let corpus = Corpus(id: "human-v1", split: "all", entries: [
            entry(id: "spk01.internal.pn-01", speaker: "spk01", split: "dev"),
            entry(id: "spk02.internal.pn-01", speaker: "spk02", split: "held"),
            entry(id: "spk03.internal.pn-01", speaker: "spk03", split: "held"),
            entry(id: "tts.pn-01", speaker: "tts-samantha", split: nil),
        ])
        XCTAssertEqual(corpus.entries(inSplit: "dev").map(\.speaker), ["spk01"])
        XCTAssertEqual(corpus.entries(inSplit: "held").map(\.speaker), ["spk02", "spk03"])
        XCTAssertEqual(corpus.speakers, ["spk01", "spk02", "spk03", "tts-samantha"])
    }

    // MARK: - the resume rule

    func testAResumedSessionRecordsOnlyWhatIsMissing() throws {
        let script = try EvalScript.parse("""
            # category: proper-nouns
            Hi Sharique.|terms=Sharique
            Ask Khatri.|terms=Khatri
            Thanks Sharique.
            """, name: "01-proper-nouns.txt")

        let steps = EvalRecordPlan.steps(
            script: script, speaker: "spk01", mic: "internal",
            recorded: ["spk01.internal.pn-01", "spk01.internal.pn-03"])
        XCTAssertEqual(steps.map(isDone), [true, false, true])
        XCTAssertEqual(EvalRecordPlan.outstanding(steps).map(\.id), ["spk01.internal.pn-02"])

        // A different microphone shares no ids with the pass already recorded,
        // so the Bluetooth pass is a full pass and not an empty one.
        let bluetooth = EvalRecordPlan.steps(
            script: script, speaker: "spk01", mic: "airpods-pro",
            recorded: ["spk01.internal.pn-01", "spk01.internal.pn-03"])
        XCTAssertEqual(EvalRecordPlan.outstanding(bluetooth).count, 3)
    }

    func testTheManifestLineCarriesEverythingAScoreboardRowNeeds() throws {
        let script = try EvalScript.parse("""
            # category: spelled-runs
            The payload is J-S-O-N.|bypass=has_letter_run|ref=The payload is JSON.|terms=JSON
            """, name: "08-spelled-runs.txt")
        let line = try XCTUnwrap(script.lines.first)
        let made = EvalRecordPlan.entry(
            line: line, id: "spk02.airpods-pro.sr-01", category: script.category,
            speaker: "spk02", mic: "airpods-pro", split: "held", sha256: "abc", durationMs: 2100)

        XCTAssertEqual(made.id, "spk02.airpods-pro.sr-01")
        XCTAssertEqual(made.audio, "audio/spk02/spk02.airpods-pro.sr-01.wav")
        XCTAssertEqual(made.source, .human, "the whole point of the verb")
        XCTAssertEqual(made.ref, "The payload is JSON.", "ref is what the document should say")
        XCTAssertEqual(made.script, "The payload is J-S-O-N.", "script is what was read aloud")
        XCTAssertEqual(made.category, "spelled-runs")
        XCTAssertEqual(made.speaker, "spk02")
        XCTAssertEqual(made.mic, "airpods-pro")
        XCTAssertEqual(made.split, "held")
        XCTAssertEqual(made.durationMs, 2100)
        XCTAssertNil(made.verified, "nobody has reviewed it yet, and that is not the same as false")
        XCTAssertEqual(made.expect, CorpusExpectation(terms: ["JSON"],
                                                      refineBypass: "has_letter_run"))
    }

    /// A line the recorder wrote has to survive the parser the scoreboard reads
    /// it with — the two are different code paths over the same file.
    func testAWrittenManifestLineParsesBack() throws {
        let original = entry(id: "spk01.internal.pn-01", speaker: "spk01", split: "dev")
        let text = try Corpus.jsonl([original])
        XCTAssertTrue(text.contains("\"audio\":\"audio/spk01/spk01.internal.pn-01.wav\""),
                      "slashes must not be escaped: \(text)")
        XCTAssertEqual(try Corpus.parse(jsonl: text), [original])
    }

    // MARK: - the keys

    /// Return and space-then-Return are different keys, so the parser must not
    /// trim before testing for empty — that is the one bug that would make
    /// "keep" and "re-take" the same keystroke.
    func testTheRecordingKeys() {
        let cases: [(String?, EvalRecordPlan.Key)] = [
            ("", .go), ("\n", .go),
            (" ", .retake), (" \n", .retake), ("r", .retake), ("R\n", .retake),
            ("s", .skip), (" S ", .skip),
            ("q", .quit), ("q\r\n", .quit),
            (nil, .quit),                     // EOF: a piped stdin must not loop
            ("x", .unknown("x")),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(EvalRecordPlan.key(for: input), expected,
                           "\(input.map { "'\($0)'" } ?? "nil")")
        }
    }

    func testTheReviewKeys() {
        let cases: [(String?, EvalVerifyPlan.Decision)] = [
            ("", .accept), ("a", .accept), (" A ", .accept),
            ("f", .fix), ("d", .discard), ("q", .quit),
            (nil, .quit),
            ("yes", .unknown("yes")),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(EvalVerifyPlan.decision(for: input), expected,
                           "\(input.map { "'\($0)'" } ?? "nil")")
        }
    }

    // MARK: - the review decisions

    func testAcceptMarksVerifiedAndChangesNothingElse() throws {
        let original = entry(id: "a", speaker: "spk01", split: "dev")
        let outcome = try XCTUnwrap(EvalVerifyPlan.apply(.accept, to: original))
        guard case .verified(let updated) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(updated.verified, true)
        XCTAssertEqual(updated.ref, original.ref)
        XCTAssertEqual(EvalVerifyPlan.applying(outcome, to: [original]), [updated])
    }

    func testFixRewritesTheReferenceAndRemembersWhatItWas() throws {
        let original = entry(id: "a", speaker: "spk01", split: "dev")
        let outcome = try XCTUnwrap(
            EvalVerifyPlan.apply(.fix, to: original, fixed: "  The payload is XML.  "))
        guard case let .corrected(updated, was) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(updated.ref, "The payload is XML.")
        XCTAssertEqual(updated.verified, true)
        XCTAssertEqual(was, original.ref)
    }

    /// A fix that changes nothing is a reviewer who pressed `f` and then changed
    /// their mind. Recording it as a rewrite would put a `corrected` note in the
    /// log with nothing behind it.
    func testAnEmptyOrUnchangedFixIsJustAnAccept() throws {
        let original = entry(id: "a", speaker: "spk01", split: "dev")
        for edit in [nil, "", "   ", original.ref] {
            let outcome = try XCTUnwrap(EvalVerifyPlan.apply(.fix, to: original, fixed: edit))
            guard case .verified(let updated) = outcome else { return XCTFail("\(outcome)") }
            XCTAssertEqual(updated.ref, original.ref)
            XCTAssertEqual(updated.verified, true)
        }
    }

    func testDiscardDropsTheLineAndRenamesRatherThanDeletesTheAudio() throws {
        let entries = [entry(id: "a", speaker: "spk01", split: "dev"),
                       entry(id: "b", speaker: "spk01", split: "dev")]
        let outcome = try XCTUnwrap(EvalVerifyPlan.apply(.discard, to: entries[0]))
        XCTAssertEqual(outcome, .removed(id: "a", audio: entries[0].audio))
        XCTAssertEqual(EvalVerifyPlan.applying(outcome, to: entries).map(\.id), ["b"])
        XCTAssertEqual(EvalVerifyPlan.discardedPath("audio/spk01/a.wav"),
                       "audio/spk01/a.wav.discarded")
    }

    func testQuitAndAnUnknownKeyDecideNothing() {
        let original = entry(id: "a", speaker: "spk01", split: "dev")
        XCTAssertNil(EvalVerifyPlan.apply(.quit, to: original))
        XCTAssertNil(EvalVerifyPlan.apply(.unknown("yes"), to: original))
    }

    /// A review resumes for the same reason a recording does: nobody gets
    /// through 130 clips in one sitting.
    func testAReviewSkipsWhatIsAlreadyVerifiedAndHonoursTheSpeakerFilter() {
        var verified = entry(id: "a", speaker: "spk01", split: "dev")
        verified.verified = true
        let entries = [verified,
                       entry(id: "b", speaker: "spk01", split: "dev"),
                       entry(id: "c", speaker: "spk02", split: "held")]
        XCTAssertEqual(EvalVerifyPlan.pending(entries).map(\.id), ["b", "c"])
        XCTAssertEqual(EvalVerifyPlan.pending(entries, speaker: "spk02").map(\.id), ["c"])
        XCTAssertEqual(EvalVerifyPlan.pending(entries, speaker: "spk01").map(\.id), ["b"])
    }

    /// Read every marker as reference→hypothesis. Case and punctuation are
    /// absent because the diff runs over `.asr` tokens — the same normalization
    /// the WER next to it will use, so the reviewer is looking at the errors
    /// that will actually be counted.
    func testTheDiffShowsWhichSideSaidWhat() {
        XCTAssertEqual(
            EvalVerifyPlan.diff(ref: "The payload is JSON, not YAML.",
                                hyp: "the payload is json not xml"),
            "the payload is json not [yaml→xml]")
        XCTAssertEqual(
            EvalVerifyPlan.diff(ref: "We should just ship it.",
                                hyp: "we should ship it today"),
            "we should [-just] ship it [+today]")
        XCTAssertEqual(EvalVerifyPlan.diff(ref: "Hi Sharique.", hyp: "Hi Sharique!"),
                       "hi sharique")
        XCTAssertEqual(EvalVerifyPlan.diff(ref: "", hyp: ""), "(both empty)")
        XCTAssertTrue(EvalVerifyPlan.summary(ref: "We should just ship it.",
                                             hyp: "we should ship it today")
            .hasPrefix("0 sub, 1 del, 1 ins over 5 words"))
    }

    // MARK: - the WAVE file

    /// The header is asserted byte by byte because the file's sha256 is the ASR
    /// cache key: audio that reads back as anything other than what the tap
    /// produced means every cached transcript describes a clip nobody has.
    func testTheWaveHeaderIsCanonicalSixteenKilohertzMonoInt16() {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let file = WavFile.data(pcm: pcm)
        XCTAssertEqual(file.count, WavFile.headerBytes + pcm.count)
        XCTAssertEqual(Array(file[0..<4]), Array("RIFF".utf8))
        XCTAssertEqual(Array(file[4..<8]), [40, 0, 0, 0])          // 36 + 4
        XCTAssertEqual(Array(file[8..<12]), Array("WAVE".utf8))
        XCTAssertEqual(Array(file[12..<16]), Array("fmt ".utf8))
        XCTAssertEqual(Array(file[16..<20]), [16, 0, 0, 0])        // PCM chunk
        XCTAssertEqual(Array(file[20..<22]), [1, 0])               // format 1 = PCM
        XCTAssertEqual(Array(file[22..<24]), [1, 0])               // mono
        XCTAssertEqual(Array(file[24..<28]), [0x80, 0x3E, 0, 0])   // 16000
        XCTAssertEqual(Array(file[28..<32]), [0x00, 0x7D, 0, 0])   // 32000 bytes/s
        XCTAssertEqual(Array(file[32..<34]), [2, 0])               // block align
        XCTAssertEqual(Array(file[34..<36]), [16, 0])              // bits per sample
        XCTAssertEqual(Array(file[36..<40]), Array("data".utf8))
        XCTAssertEqual(Array(file[40..<44]), [4, 0, 0, 0])
        XCTAssertEqual(Array(file[44...]), Array(pcm), "the samples are stored unchanged")
    }

    func testAnEmptyCaptureStillProducesAValidHeader() {
        let file = WavFile.data(pcm: Data())
        XCTAssertEqual(file.count, WavFile.headerBytes)
        XCTAssertEqual(Array(file[4..<8]), [36, 0, 0, 0])
        XCTAssertEqual(Array(file[40..<44]), [0, 0, 0, 0])
    }

    /// The same integer arithmetic `generate.sh` uses, so a human clip and a
    /// synthetic one of the same length report the same number.
    func testDurationMatchesTheSyntheticCorpusArithmetic() {
        XCTAssertEqual(WavFile.durationMs(pcmBytes: 32_000), 1000)
        XCTAssertEqual(WavFile.durationMs(pcmBytes: 0), 0)
        XCTAssertEqual(WavFile.durationMs(pcmBytes: 104_960), 3280)   // tts pn-01
    }

    // MARK: - the shipped scripts

    /// Parses all of `tools/eval/scripts/human-v1`. A typo in a directive, a
    /// missing header, a bypass that is not one, or two categories abbreviating
    /// to the same prefix all fail HERE — at `swift test` — rather than in front
    /// of somebody who has just sat down to read 135 sentences.
    func testTheShippedHumanScriptsParseAndAreInternallyConsistent() throws {
        let root = try XCTUnwrap(EvalPaths.repoRoot(), "no checkout")
        let directory = root.appendingPathComponent("tools/eval/scripts/human-v1")
        let scripts = try EvalScript.load(directory: directory)

        XCTAssertEqual(scripts.count, 13)
        XCTAssertEqual(scripts.map(\.category), [
            "proper-nouns", "control-names", "product-terms", "tech-jargon", "homophones",
            "addresses", "postal-address", "spelled-runs", "numbers-dates", "spoken-commands",
            "disfluent-speech", "long-form", "adversarial-quiet",
        ], "filename order is the recording order and the README's table order")

        let total = scripts.reduce(0) { $0 + $1.lines.count }
        XCTAssertEqual(total, 135, "the README quotes this number")

        // Ids are unique across the whole set once the speaker and mic are on
        // them — which is what the corpus actually stores.
        let ids = scripts.flatMap { script in
            script.lines.map {
                EvalRecordPlan.manifestID(speaker: "spk01", mic: "internal", clipID: $0.clipID)
            }
        }
        XCTAssertEqual(Set(ids).count, total, "duplicate manifest ids")

        for script in scripts {
            XCTAssertFalse(script.directions.isEmpty,
                           "\(script.category): every file owes the reader pace and distance")
            let directions = script.directions.joined(separator: " ").lowercased()
            XCTAssertTrue(directions.contains("pace"), "\(script.category): no pace direction")
            XCTAssertTrue(directions.contains("distance") || directions.contains(" cm"),
                          "\(script.category): no distance direction")
            for line in script.lines {
                XCTAssertFalse(line.ref.contains("|"), "\(line.clipID): unparsed directive")
                for term in line.terms {
                    XCTAssertTrue(line.ref.localizedCaseInsensitiveContains(term),
                                  "\(line.clipID): expects '\(term)' but the reference has no "
                                    + "such word — term recall could never pass")
                }
            }
        }
    }

    /// The two lines the plan names by hand, because they are the reason the
    /// category exists and a rewrite that quietly drops them would leave the
    /// retro-correction rules untested against their own motivating cases.
    func testTheSpelledRunScriptStillCarriesItsTwoNamedCases() throws {
        let root = try XCTUnwrap(EvalPaths.repoRoot(), "no checkout")
        let url = root.appendingPathComponent(
            "tools/eval/scripts/human-v1/08-spelled-runs.txt")
        let script = try EvalScript.parse(String(contentsOf: url, encoding: .utf8),
                                          name: "08-spelled-runs.txt")

        let spoken = script.lines.map(\.spoken).joined(separator: "\n")
        XCTAssertTrue(spoken.contains("J-S-O-N"), "the never-retro-delete case")
        XCTAssertTrue(spoken.contains("K-R-Z-Y-S-Z-T-O-F"), "the no-candidate case")

        let bypassed = script.lines.filter { $0.refineBypass == "has_letter_run" }
        XCTAssertGreaterThanOrEqual(bypassed.count, 10,
                                    "a spelled run that does not assert the bypass is not "
                                        + "testing the cage")
    }

    /// The must-NOT-join traps are half of the addresses file on purpose: a
    /// pipeline that joins "she works at Stripe" into an address is confidently
    /// wrong on ordinary English, which is worse than missing a real one.
    func testTheAddressScriptIsHalfTraps() throws {
        let root = try XCTUnwrap(EvalPaths.repoRoot(), "no checkout")
        let url = root.appendingPathComponent("tools/eval/scripts/human-v1/06-addresses.txt")
        let script = try EvalScript.parse(String(contentsOf: url, encoding: .utf8),
                                          name: "06-addresses.txt")
        let real = script.lines.filter { $0.refineBypass == "has_address" }
        let traps = script.lines.filter { $0.refineBypass == nil }
        XCTAssertEqual(real.count, traps.count, "the arms have to be the same size to compare")
        XCTAssertGreaterThanOrEqual(traps.count, 5)
    }

    // MARK: - helpers

    private func isDone(_ step: EvalRecordPlan.Step) -> Bool {
        if case .done = step { return true }
        return false
    }

    private func entry(id: String, speaker: String, split: String?) -> CorpusEntry {
        CorpusEntry(id: id, audio: "audio/\(speaker)/\(id).wav", sha256: "abc",
                    ref: "The payload is JSON.", category: "spelled-runs", speaker: speaker,
                    source: .human, mic: "internal", script: "The payload is J-S-O-N.",
                    durationMs: 2100, expect: CorpusExpectation(refineBypass: "has_letter_run"),
                    split: split)
    }

    private func assertScriptError(_ text: String, contains needles: [String],
                                   file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try EvalScript.parse(text, name: "x.txt")
            XCTFail("should not parse: \(text)", file: file, line: line)
        } catch let error as EvalScript.ScriptError {
            for needle in needles {
                XCTAssertTrue(error.description.contains(needle),
                              "\(error.description) is missing '\(needle)'", file: file, line: line)
            }
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }
}
