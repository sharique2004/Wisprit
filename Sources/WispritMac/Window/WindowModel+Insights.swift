#if os(macOS)
import Foundation
import WispritMacUI

/// Insights' history half.
///
/// The streak grid and the speaking rate are not in `metrics.log`; they come
/// from the transcripts the window already reads off the main thread — the
/// stat rail (`homeStats`, the whole retained table) and the newest page of
/// history (`homeItems`). This derives the page's figures from those two and
/// adds no query of its own. Nil until the stat rail has been read once.
extension WispritWindowModel {
    func insightsActivity(now: Date = Date(), calendar: Calendar = .current) -> InsightsActivity? {
        guard let stats = homeStats else { return nil }
        return InsightsActivity.make(stats: stats, items: homeItems, now: now, calendar: calendar)
    }
}
#endif
