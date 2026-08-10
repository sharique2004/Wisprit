import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// The streak grid's intensity ramp — `docs/design/ui-redesign.md` §3.3.
///
/// Four steps of `ink`, and **not orange**: a heatmap is history, not live
/// audio, and the tally only means something because nothing else borrows it
/// (§1.6). Pure so the bucketing is testable.
public enum StreakIntensity {
    /// α for steps 0…3. Step 0 is an empty cell, still visible — an invisible
    /// zero would make a sparse month look like a missing month.
    public static let alphas: [Double] = [0.08, 0.22, 0.45, 0.75]

    /// Four buckets: none, one, a couple, a working day.
    public static func step(for count: Int) -> Int {
        switch count {
        case ..<1: return 0
        case 1: return 1
        case 2...3: return 2
        default: return 3
        }
    }

    public static func alpha(for count: Int) -> Double {
        alphas[step(for: count)]
    }
}

#if canImport(SwiftUI)
/// 18 weeks × 7 days at 8 pt cells with 2 pt gaps → 178 × 68.
public struct StreakGrid: View {
    public static let cell: Double = 8
    public static let gap: Double = 2

    /// Weeks × 7 counts, oldest week first — `HomeModel.heatmap`.
    private let weeks: [[Int]]
    /// Index of today, as (week, day), for the 1 pt ring.
    private let today: (week: Int, day: Int)?

    public init(weeks: [[Int]], today: (week: Int, day: Int)? = nil) {
        self.weeks = weeks
        self.today = today
    }

    public static func size(weeks: Int) -> CGSize {
        CGSize(width: Double(weeks) * cell + Double(max(0, weeks - 1)) * gap,
               height: 7 * cell + 6 * gap)
    }

    public var body: some View {
        HStack(spacing: StreakGrid.gap) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { weekIndex, days in
                VStack(spacing: StreakGrid.gap) {
                    ForEach(Array(days.enumerated()), id: \.offset) { dayIndex, count in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Theme.ink.opacity(StreakIntensity.alpha(for: count)))
                            .frame(width: StreakGrid.cell, height: StreakGrid.cell)
                            .overlay {
                                if today?.week == weekIndex && today?.day == dayIndex {
                                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                                        .strokeBorder(Theme.ink, lineWidth: 1)
                                }
                            }
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}
#endif
