import Foundation
import WispritKit

/// The data inventory — every class of thing Wisprit keeps on this Mac, with
/// its size and its delete (FINAL-PLAN R17 / judge-soul §4.4).
///
/// The identity claim this file exists to make good on: *the app that asks
/// before reading should also show what it kept and delete on command.* Until
/// this page, "Delete All Transcripts" purged history while `metrics.log` was
/// purge-immune — a data estate the purge did not cover. Now every store is
/// listed in one place, each with its own delete, plus delete-everything; a
/// purge button that misses a file is a lie with a UI (soul test 6).
///
/// This is a *catalog*, not a new store: every entry names files their owning
/// stores already know (`WispritPaths`, `PendingLearnStore.defaultPath`, the
/// doctor's models-dir convention). Sizes are read from disk on demand, off the
/// main actor, by whoever calls `status()`.
public enum DataStoreID: String, CaseIterable, Sendable, Equatable {
    /// `history.sqlite` (+ SQLite sidecars) — everything the user dictated.
    case transcripts
    /// `metrics.log` — one line of timings and counters per utterance. Its
    /// FIRST delete surface: the file predates this page by three eras.
    case metrics
    /// `dictionary.json` (+ the cleanup backup) — the user's terms and the
    /// spellings Wisprit learned from their corrections.
    case dictionary
    /// `learn_pending.json` — evidence for terms not yet proposed, and the
    /// user's permanent dismissals.
    case learnLedger
    /// `models/` — optional engine downloads (Parakeet). Bytes, not words.
    case models
    /// `config.json` — preferences. Listed for honesty, not deletable from
    /// here: deleting settings is not "forget what you heard", and the file
    /// holds nothing the user said.
    case settings
}

/// One row of the inventory as the page shows it: what the class is, what it
/// weighs, and whether it can be deleted here.
public struct DataStoreStatus: Identifiable, Sendable, Equatable {
    public var id: DataStoreID
    public var title: String
    /// One line, in the user's language, about what lives here and why.
    public var summary: String
    /// On-disk footprint across every file of the class, bytes. 0 when nothing
    /// has been written yet — an empty store is a real (and good) state.
    public var byteSize: Int64
    /// At least one of the class's files exists on disk.
    public var exists: Bool
    /// Whether the page offers a per-class delete. False only for `.settings`.
    public var deletable: Bool

    public init(id: DataStoreID, title: String, summary: String,
                byteSize: Int64, exists: Bool, deletable: Bool) {
        self.id = id
        self.title = title
        self.summary = summary
        self.byteSize = byteSize
        self.exists = exists
        self.deletable = deletable
    }
}

public enum DataInventory {

    /// The classes whose delete the page's "Delete everything" must reach.
    /// `.settings` is excluded by definition (see `DataStoreID.settings`);
    /// everything else is exactly the "one purge that reaches every store"
    /// promise.
    public static var deletableClasses: [DataStoreID] {
        DataStoreID.allCases.filter { $0 != .settings }
    }

    /// Every file a class owns, by the same conventions the stores use.
    ///
    /// `root` is a parameter (defaulting to the live state dir) so a test can
    /// point this at a temp directory without touching the global override.
    public static func files(for id: DataStoreID,
                             root: URL = WispritPaths.stateDir) -> [URL] {
        switch id {
        case .transcripts:
            // SQLite in WAL mode leaves sidecars beside the database; a purge
            // report that ignored them would under-count what is on disk.
            let db = root.appendingPathComponent("history.sqlite")
            return [db,
                    URL(fileURLWithPath: db.path + "-wal"),
                    URL(fileURLWithPath: db.path + "-shm")]
        case .metrics:
            return [root.appendingPathComponent("metrics.log")]
        case .dictionary:
            let file = root.appendingPathComponent("dictionary.json")
            // The cleanup backup (`LearnedTermCleanup`) is the same class of
            // content and must not survive a dictionary delete.
            return [file, URL(fileURLWithPath: file.path + ".bak")]
        case .learnLedger:
            return [root.appendingPathComponent("learn_pending.json")]
        case .models:
            return [root.appendingPathComponent("models", isDirectory: true)]
        case .settings:
            return [root.appendingPathComponent("config.json")]
        }
    }

    /// The whole inventory, sizes read from disk. Call off the main actor —
    /// it stats every file Wisprit writes (and walks the models dir).
    public static func status(root: URL = WispritPaths.stateDir) -> [DataStoreStatus] {
        DataStoreID.allCases.map { id in
            let size = byteSize(of: files(for: id, root: root))
            return DataStoreStatus(id: id,
                                   title: title(for: id),
                                   summary: summary(for: id),
                                   byteSize: size.bytes,
                                   exists: size.exists,
                                   deletable: id != .settings)
        }
    }

    /// Delete a class's files. `.transcripts` is deliberately NOT handled here:
    /// the history database has a live SQLite handle, and its purge is the
    /// store's own (`History.purge()` — DELETE + VACUUM), which the window
    /// model routes through the existing port. `.settings` is never deleted.
    ///
    /// Removal is complete by construction for the classes this does handle:
    /// `MetricsWriter` appends through `O_CREAT` and recreates the file;
    /// `PendingLearnStore` re-reads the file inside every operation; the
    /// dictionary's owner must `reload()` after this (the app controller
    /// does), because `DictionaryStore.maybeReload` deliberately keeps its
    /// in-memory copy when the file vanishes.
    public static func purge(_ id: DataStoreID, root: URL = WispritPaths.stateDir) {
        switch id {
        case .transcripts, .settings:
            return
        case .metrics, .dictionary, .learnLedger, .models:
            let manager = FileManager.default
            for url in files(for: id, root: root) {
                try? manager.removeItem(at: url)
            }
        }
    }

    // MARK: - copy

    static func title(for id: DataStoreID) -> String {
        switch id {
        case .transcripts: return "Transcripts"
        case .metrics: return "Usage metrics"
        case .dictionary: return "Dictionary"
        case .learnLedger: return "Learning ledger"
        case .models: return "Downloaded models"
        case .settings: return "Settings"
        }
    }

    static func summary(for id: DataStoreID) -> String {
        switch id {
        case .transcripts:
            return "Everything you've dictated — what History shows and "
                + "Paste Last pastes."
        case .metrics:
            return "One line of timings and counters per dictation. How long "
                + "things took — never what you said."
        case .dictionary:
            return "Your terms, plus spellings Wisprit learned from your "
                + "corrections. Learned terms live here on purpose, so they "
                + "survive a transcript purge — visible, editable, and "
                + "forgotten only here."
        case .learnLedger:
            return "Evidence for terms Wisprit is still deciding whether to "
                + "propose, and the ones you said no to."
        case .models:
            return "Optional speech-model downloads. Bytes of model, nothing "
                + "personal — deleting frees the disk space."
        case .settings:
            return "Your preferences. Nothing you said lives here, so "
                + "deleting your data leaves it alone."
        }
    }

    /// The section footnote — where the derived-data sentence gets said out
    /// loud (soul §4.4): deletion is per-store on purpose, and what survives a
    /// purge survives it visibly.
    public static let footnote =
        "Everything Wisprit keeps lives in these files, on this Mac, and "
        + "nowhere else. Deleting transcripts does not delete learned terms — "
        + "the dictionary is your own file, listed above, with its own delete."

    /// The size cell. "nothing yet" beats "Zero KB": an empty store is not a
    /// measurement, it is the absence of one.
    public static func sizeLabel(_ status: DataStoreStatus) -> String {
        guard status.exists, status.byteSize > 0 else { return "nothing yet" }
        return ByteCountFormatter.string(fromByteCount: status.byteSize,
                                         countStyle: .file)
    }

    // MARK: - sizes

    /// Total bytes across files and directory trees, plus whether anything
    /// exists at all.
    static func byteSize(of urls: [URL]) -> (bytes: Int64, exists: Bool) {
        let manager = FileManager.default
        var total: Int64 = 0
        var exists = false
        for url in urls {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                continue
            }
            exists = true
            if isDirectory.boolValue {
                let walker = manager.enumerator(at: url,
                                                includingPropertiesForKeys: [.fileSizeKey],
                                                options: [])
                while let entry = walker?.nextObject() as? URL {
                    total += Int64((try? entry.resourceValues(forKeys: [.fileSizeKey])
                        .fileSize) ?? 0)
                }
            } else {
                let attributes = try? manager.attributesOfItem(atPath: url.path)
                total += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        return (total, exists)
    }
}
