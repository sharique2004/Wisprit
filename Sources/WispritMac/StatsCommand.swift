#if os(macOS)
import Foundation
import WispritKit
import WispritPersistence

/// `Wisprit stats [--days N]` — what `~/.wisprit/metrics.log` actually says.
///
/// The aggregation and the rendering both belong to `MetricsSummary`, which is
/// pure. This file owns exactly the two things a subcommand has to own — the
/// argument and the clock — so the numbers a user reads on the terminal are the
/// numbers a fixture test asserts on.
enum StatsCommand {

    static let usage = "usage: Wisprit stats [--days N]"

    /// What the arguments asked for, or why they could not be read. Parsed
    /// separately from the run so the argument spelling is pinned by a test
    /// rather than by a string comparison inside `main`.
    enum Parsed: Equatable {
        case window(MetricsWindow)
        case invalid(String)
    }

    /// The whole file by default. metrics.log spans the Python era, the
    /// pre-telemetry Swift era and this one; a first look should see all of it,
    /// and `--days` is how you ask about now.
    static func parse(_ arguments: [String]) -> Parsed {
        var days: Double?
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            let raw: String?
            if argument == "--days" {
                index += 1
                raw = index < arguments.endIndex ? arguments[index] : nil
            } else if argument.hasPrefix("--days=") {
                raw = String(argument.dropFirst("--days=".count))
            } else {
                return .invalid("unknown option: \(argument)")
            }
            guard let raw, let value = Double(raw), value > 0, value.isFinite else {
                return .invalid("--days needs a positive number of days")
            }
            days = value
            index += 1
        }
        return .window(MetricsWindow(days: days))
    }

    static func run(arguments: [String], now: Double = Date().timeIntervalSince1970) -> Int32 {
        switch parse(arguments) {
        case .invalid(let message):
            FileHandle.standardError.write(Data("\(message)\n\(usage)\n".utf8))
            return 2
        case .window(let window):
            let summary = MetricsSummary.summarize(MetricsWriter().readAll(),
                                                   window: window, now: now)
            print(MetricsSummary.render(for: summary))
            return 0
        }
    }
}
#endif
