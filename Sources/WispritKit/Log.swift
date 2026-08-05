import Foundation
import os

/// Unified logging, mirroring the Python `wisprit.<module>` logger convention.
public enum WLog {
    public static func logger(_ module: String) -> Logger {
        Logger(subsystem: "com.wisprit", category: module)
    }
}
