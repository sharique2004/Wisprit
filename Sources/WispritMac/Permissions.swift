#if os(macOS)
import ApplicationServices
import AVFoundation
import Carbon
import CoreGraphics
import Foundation
import IOKit.hid
import WispritKit

/// TCC probes for the grants Wisprit needs — port of `wisprit/permissions.py`.
///
/// - **Accessibility** (`AXIsProcessTrusted`) — required to post the ⌘V paste
///   event. Without it macOS *silently drops* posted events, which is why the
///   inserter refuses rather than clobbering the clipboard for a paste that can
///   never land.
/// - **Input Monitoring** (`IOHIDCheckAccess`) — required for the listen-only
///   CGEventTap that watches the Fn key. Documented caveat: this can report
///   `denied` while events actually flow (stale TCC cache), so a live tap is
///   also treated as proof.
/// - **Post-event access** (`CGPreflightPostEventAccess`) — the newer,
///   event-posting-specific gate; distinct from Accessibility on recent macOS.
/// - **Microphone** — reported without prompting.
///
/// Every probe is read-only except `requestAccessibilityPrompt`, which is
/// invoked explicitly.
public enum Permissions {

    public enum Status: String, Sendable, Equatable {
        case granted, denied, undetermined, restricted
    }

    /// True if this process is trusted for Accessibility.
    public static func accessibility() -> Bool {
        AXIsProcessTrusted()
    }

    /// Raise the system Accessibility prompt (adds this process to the list).
    @discardableResult
    public static func requestAccessibilityPrompt() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`.
    public static func inputMonitoring() -> Status {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .undetermined
        }
    }

    /// Whether this process may post synthetic events. On recent macOS this is
    /// a separate gate from Accessibility, and it is the one the paste needs.
    public static func postEventAccess() -> Bool {
        CGPreflightPostEventAccess()
    }

    /// Microphone authorization, without prompting.
    public static func microphone() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    /// Raise the microphone prompt for THIS identity if undetermined. Grants
    /// are per-binary/per-bundle, so a new launcher must ask even when the old
    /// one was already granted.
    public static func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    /// Secure Keyboard Entry state. While it is on, the tap cannot see keys and
    /// nothing may be injected.
    ///
    /// The holder is reported as nil: macOS exposes no public API for it, and
    /// the Python returned nil too — guessing an app name would be inventing a
    /// diagnosis.
    public static func secureInput() -> (active: Bool, holder: String?) {
        (IsSecureEventInputEnabled(), nil)
    }
}
#endif
