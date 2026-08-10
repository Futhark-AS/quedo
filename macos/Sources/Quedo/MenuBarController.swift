import AppKit
import QuedoCore

/// Manages the NSStatusItem menu bar UI and action routing.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private var actionHandler: ((AppAction) -> Void)?
    private var lastSnapshot: AppLifecycleSnapshot?
    private var lastContract: UIStateContract?
    private var completionResetWorkItem: DispatchWorkItem?
    private var processingAnimationTimer: DispatchSourceTimer?
    private var processingAnimationFrame: Int = 0

    init(statusItem: NSStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)) {
        self.statusItem = statusItem
        super.init()
        configureStatusItemAppearance(iconName: "mic", phase: .ready)
    }

    func setActionHandler(_ handler: @escaping (AppAction) -> Void) {
        actionHandler = handler
    }

    func update(snapshot: AppLifecycleSnapshot, contract: UIStateContract) {
        let previousPhase = lastSnapshot?.phase
        lastSnapshot = snapshot
        lastContract = contract

        if previousPhase == .outputting && snapshot.phase == .ready {
            showCompletionIndicator()
        } else {
            completionResetWorkItem?.cancel()
            completionResetWorkItem = nil
            configureStatusItemAppearance(iconName: contract.icon, phase: snapshot.phase)
        }

        let menu = NSMenu()

        let versionItem = NSMenuItem(title: appVersionMenuTitle(), action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(.separator())

        if let copy = contract.notificationCopy {
            let status = NSMenuItem(title: copy, action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            menu.addItem(.separator())
        }

        for action in contract.actions {
            menu.addItem(makeActionItem(for: action))
        }

        if snapshot.phase != .ready {
            if snapshot.currentSessionID != nil {
                menu.addItem(makeActionItem(for: .forceStop))
            }
            menu.addItem(makeActionItem(for: .viewLastError))
            menu.addItem(makeActionItem(for: .exportDiagnostics))
        }

        menu.addItem(.separator())
        menu.addItem(makeActionItem(for: .quit))

        statusItem.menu = menu
    }

    private func showCompletionIndicator() {
        completionResetWorkItem?.cancel()
        completionResetWorkItem = nil
        stopProcessingAnimation()

        if let image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Transcription complete") {
            image.isTemplate = true
            statusItem.button?.image = image
            statusItem.button?.title = ""
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard
                let self,
                let snapshot = self.lastSnapshot,
                snapshot.phase == .ready,
                let contract = self.lastContract
            else {
                return
            }
            self.configureStatusItemAppearance(iconName: contract.icon, phase: snapshot.phase)
        }
        completionResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)
    }

    private func configureStatusItemAppearance(iconName: String, phase: AppPhase) {
        guard let button = statusItem.button else {
            return
        }

        button.toolTip = lastContract?.notificationCopy ?? "Quedo ready"
        button.setAccessibilityLabel(lastContract?.notificationCopy ?? "Quedo")

        if isProcessingAnimationPhase(phase) {
            startProcessingAnimation()
            button.title = ""
            return
        }

        stopProcessingAnimation()

        if let image = NSImage(systemSymbolName: iconName, accessibilityDescription: "Quedo") {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = "Q"
        }
    }

    private func isProcessingAnimationPhase(_ phase: AppPhase) -> Bool {
        switch phase {
        case .processing, .streamingPartial:
            return true
        default:
            return false
        }
    }

    private func startProcessingAnimation() {
        if processingAnimationTimer != nil {
            return
        }

        processingAnimationFrame = 0
        renderProcessingAnimationFrame()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.11, repeating: 0.11)
        timer.setEventHandler { [weak self] in
            self?.advanceProcessingAnimation()
        }
        processingAnimationTimer = timer
        timer.resume()
    }

    private func stopProcessingAnimation() {
        processingAnimationTimer?.cancel()
        processingAnimationTimer = nil
        processingAnimationFrame = 0
    }

    private func advanceProcessingAnimation() {
        processingAnimationFrame = (processingAnimationFrame + 1) % 24
        renderProcessingAnimationFrame()
    }

    private func renderProcessingAnimationFrame() {
        guard let button = statusItem.button else {
            return
        }
        let image = processingAnimationImage(frame: processingAnimationFrame)
        image.isTemplate = true
        button.image = image
        button.title = ""
    }

    private func processingAnimationImage(frame: Int) -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size, flipped: false) { _ in
            let center = NSPoint(x: 11, y: 11)

            NSColor.white.setFill()
            NSColor.white.setStroke()

            let dotRadius: CGFloat = 1.8
            let dotRect = NSRect(
                x: center.x - dotRadius, y: center.y - dotRadius,
                width: dotRadius * 2, height: dotRadius * 2
            )
            NSBezierPath(ovalIn: dotRect).fill()

            let radii: [CGFloat] = [3.8, 5.8, 7.8]
            let arcSpan: CGFloat = 64
            let baseRotation = CGFloat(frame) * 15 - 90

            for (index, radius) in radii.enumerated() {
                let phaseOffset = CGFloat(index) * 30
                let startAngle = baseRotation + phaseOffset - arcSpan / 2
                let endAngle = startAngle + arcSpan
                let arc = NSBezierPath()
                arc.lineWidth = 2.0
                arc.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
                arc.stroke()
            }

            return true
        }

        return image
    }

    private func makeActionItem(for action: AppAction) -> NSMenuItem {
        let item = NSMenuItem(title: action.rawValue, action: #selector(handleMenuAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action.rawValue
        if action == .quit {
            item.keyEquivalent = "q"
        }
        return item
    }

    @objc
    private func handleMenuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = AppAction(rawValue: raw) else {
            return
        }

        if action == .quit {
            NSApplication.shared.terminate(nil)
            return
        }

        actionHandler?(action)
    }

    private func appVersionMenuTitle() -> String {
        let info = Bundle.main.infoDictionary
        let shortVersion = (info?["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedVersion: String
        if let shortVersion, !shortVersion.isEmpty {
            normalizedVersion = shortVersion.hasPrefix("v") ? shortVersion : "v\(shortVersion)"
        } else {
            normalizedVersion = "dev"
        }
        return "Quedo \(normalizedVersion)"
    }
}
