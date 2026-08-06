#if os(macOS)
import Foundation

/// The 2-second refresh.
///
/// `Doctor.gather()` is the honest full picture, but it runs an asset inventory,
/// a FoundationModels probe and an input-method ping — far too much to repeat
/// while a window sits open. The four TCC reads are the only facts that can
/// change *while the user is in System Settings*, and they are pure syscalls, so
/// the window re-reads those on a short timer and everything else on a slow one.
public extension Doctor {

    /// Last full snapshot with the permission facts re-read. Everything else —
    /// speech assets, Apple Intelligence, the input method, the state files — is
    /// carried over untouched.
    static func refreshingPermissions(_ base: DoctorFacts) -> DoctorFacts {
        var facts = base
        facts.accessibility = Permissions.accessibility()
        facts.inputMonitoring = Permissions.inputMonitoring().rawValue
        facts.postEventAccess = Permissions.postEventAccess()
        facts.microphone = Permissions.microphone().rawValue
        facts.secureInputActive = Permissions.secureInput().active
        return facts
    }
}
#endif
