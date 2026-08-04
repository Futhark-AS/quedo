import AppKit
import ApplicationServices
import Foundation

/// Output targets that were successfully executed.
public enum OutputTarget: String, Sendable {
    /// Clipboard write target.
    case clipboard
    /// Synthetic paste target.
    case pasteAtCursor
}

/// Errors thrown during transcript output routing.
public enum OutputRouterError: Error, Sendable {
    /// Paste target is not allowed for current build profile.
    case pasteUnavailableInProfile
    /// Accessibility permission is missing.
    case accessibilityPermissionRequired
    /// Synthetic key event could not be posted.
    case syntheticPasteFailed
}

public extension OutputRouterError {
    /// Stable output failure code for diagnostics.
    var diagnosticCode: String {
        switch self {
        case .pasteUnavailableInProfile:
            return "paste_unavailable_in_profile"
        case .accessibilityPermissionRequired:
            return "accessibility_permission_required"
        case .syntheticPasteFailed:
            return "synthetic_paste_failed"
        }
    }
}

/// Routes transcript text to configured output destinations.
public actor OutputRouter {
    /// Creates output router.
    public init() {}

    /// Routes text to configured targets and returns successful targets.
    public func route(text: String, mode: OutputMode, profile: BuildProfile) throws -> [OutputTarget] {
        switch mode {
        case .none:
            return []
        case .clipboard:
            copyToClipboard(text)
            return [.clipboard]
        case .pasteAtCursor:
            guard profile == .direct else {
                throw OutputRouterError.pasteUnavailableInProfile
            }
            copyToClipboard(text)
            try pasteViaSyntheticCommandV()
            return [.clipboard, .pasteAtCursor]
        case .clipboardAndPaste:
            copyToClipboard(text)
            if profile == .mas {
                return [.clipboard]
            }
            try pasteViaSyntheticCommandV()
            return [.clipboard, .pasteAtCursor]
        }
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func pasteViaSyntheticCommandV() throws {
        let trusted = AXIsProcessTrusted()
        guard trusted else {
            throw OutputRouterError.accessibilityPermissionRequired
        }

        guard
            let source = CGEventSource(stateID: .combinedSessionState),
            let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false),
            let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)
        else {
            throw OutputRouterError.syntheticPasteFailed
        }

        commandDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        commandDown.post(tap: .cghidEventTap)
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        commandUp.post(tap: .cghidEventTap)
    }
}
