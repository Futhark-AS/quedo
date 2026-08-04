import AppKit
import Carbon
import Foundation

/// Errors thrown by global hotkey registration.
public enum HotkeyError: Error, Sendable {
    /// Requested key combination is already owned by another app.
    case conflict
    /// Registration failed for an unknown reason.
    case registrationFailed(status: OSStatus)
    /// Event handler could not be installed.
    case eventHandlerInstallFailed(status: OSStatus)
}

/// Hybrid hotkey manager using Carbon plus NSEvent monitoring for Fn-based combos.
public final class HotkeyManager: @unchecked Sendable {
    private struct MonitoredHotkey: Hashable {
        let keyCode: UInt32
        let modifiers: HotkeyModifiers
    }

    private static let signature: OSType = 0x57415354 // WAST
    private static let logQueue = DispatchQueue(label: "com.futhark.quedo.hotkeys.log", qos: .utility)
    private static let maxHotkeyLogBytes = 2_000_000
    private static let maxHotkeyLogFiles = 5

    private var handlerRef: EventHandlerRef?
    private var hotkeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var actionByID: [UInt32: String] = [:]
    private var monitoredBindings: [MonitoredHotkey: String] = [:]
    private var modifierOnlyCombos: Set<MonitoredHotkey> = []
    private var registeredBindings: [HotkeyBinding] = []
    private var onHotkey: (@Sendable (String, HotkeyEvent) -> Void)?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var globalKeyUpMonitor: Any?
    private var localKeyUpMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var activeModifierOnlyCombos: Set<MonitoredHotkey> = []
    private var lastDispatchByMonitoredHotkeyEvent: [String: Date] = [:]
    private let lock = NSLock()
    private var wakeObserver: NSObjectProtocol?

    /// Creates a hotkey manager and installs event callback handler.
    public init() throws {
        try installEventHandler()
        installWakeObserver()
        logDebug("manager_init")
    }

    deinit {
        logDebug("manager_deinit")
        if let wakeObserver {
            NotificationCenter.default.removeObserver(wakeObserver)
        }
        unregisterAll()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    /// Activates hotkey bindings with bounded retry.
    public func setBindings(
        _ bindings: [HotkeyBinding],
        handler: @escaping @Sendable (String, HotkeyEvent) -> Void
    ) async throws {
        updateBindingsSnapshot(bindings: bindings, handler: handler)
        logDebug("set_bindings count=\(bindings.count) bindings=\(bindings.map(describe).joined(separator: ","))")

        do {
            try registerAll(bindings: bindings)
        } catch {
            logDebug("set_bindings_retry reason=\(String(describing: error))")
            try? await Task.sleep(for: .milliseconds(300))
            try registerAll(bindings: bindings)
        }
    }

    /// Unregisters all active hotkeys.
    public func deactivate() {
        logDebug("deactivate")
        unregisterAll()
    }

    /// Retries registration after wake with bounded delays.
    public func recoverAfterWake() async {
        let bindings = currentBindingsSnapshot()

        guard !bindings.isEmpty else {
            return
        }

        for delay in [300, 1000] {
            do {
                try registerAll(bindings: bindings)
                logDebug("recover_after_wake_success delay_ms=\(delay)")
                return
            } catch {
                logDebug("recover_after_wake_retry delay_ms=\(delay) reason=\(String(describing: error))")
                try? await Task.sleep(for: .milliseconds(delay))
            }
        }
    }

    private func installEventHandler() throws {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else {
                    return noErr
                }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.handleHotkeyEvent(event)
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &handlerRef
        )

        guard status == noErr else {
            throw HotkeyError.eventHandlerInstallFailed(status: status)
        }
    }

    private func registerAll(bindings: [HotkeyBinding]) throws {
        unregisterAll()

        var seenCombos = Set<MonitoredHotkey>()
        for binding in bindings {
            let combo = MonitoredHotkey(keyCode: binding.keyCode, modifiers: normalizedModifiers(binding.modifiers))
            if seenCombos.contains(combo) {
                logDebug("register_conflict duplicate=\(describe(combo))")
                throw HotkeyError.conflict
            }
            seenCombos.insert(combo)
        }

        let carbonBindings = bindings.filter { !shouldUseEventMonitor(for: $0) }
        let monitored = bindings.filter { shouldUseEventMonitor(for: $0) }

        for (index, binding) in carbonBindings.enumerated() {
            var ref: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: Self.signature, id: UInt32(index + 1))
            let status = RegisterEventHotKey(
                UInt32(binding.keyCode),
                carbonModifiers(from: binding.modifiers),
                identifier,
                GetApplicationEventTarget(),
                0,
                &ref
            )

            if status == eventHotKeyExistsErr {
                unregisterAll()
                logDebug("register_conflict carbon_exists action=\(binding.actionID) key_code=\(binding.keyCode)")
                throw HotkeyError.conflict
            }

            guard status == noErr, let ref else {
                unregisterAll()
                logDebug("register_failed status=\(status) action=\(binding.actionID) key_code=\(binding.keyCode)")
                throw HotkeyError.registrationFailed(status: status)
            }

            lock.lock()
            hotkeyRefs[identifier.id] = ref
            actionByID[identifier.id] = binding.actionID
            lock.unlock()
            logDebug("register_carbon action=\(binding.actionID) id=\(identifier.id) key_code=\(binding.keyCode)")
        }

        configureEventMonitors(bindings: monitored)
        logDebug("register_complete carbon=\(carbonBindings.count) monitored=\(monitored.count)")
    }

    private func unregisterAll() {
        lock.lock()
        let refs = Array(hotkeyRefs.values)
        let hadState = !refs.isEmpty || !monitoredBindings.isEmpty || !modifierOnlyCombos.isEmpty
        hotkeyRefs.removeAll(keepingCapacity: true)
        actionByID.removeAll(keepingCapacity: true)
        monitoredBindings.removeAll(keepingCapacity: true)
        modifierOnlyCombos.removeAll(keepingCapacity: true)
        activeModifierOnlyCombos.removeAll(keepingCapacity: true)
        lastDispatchByMonitoredHotkeyEvent.removeAll(keepingCapacity: true)
        lock.unlock()

        for ref in refs {
            UnregisterEventHotKey(ref)
        }

        removeEventMonitors()
        if hadState {
            logDebug("unregister_all")
        }
    }

    private func handleHotkeyEvent(_ event: EventRef) {
        var hotkeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotkeyID
        )

        guard status == noErr else {
            logDebug("carbon_event_param_failed status=\(status)")
            return
        }

        let (action, handler) = currentActionAndHandler(for: hotkeyID.id)

        guard let action else {
            logDebug("carbon_event_unmapped id=\(hotkeyID.id)")
            return
        }
        let eventKind = GetEventKind(event)
        let hotkeyEvent: HotkeyEvent = (eventKind == UInt32(kEventHotKeyReleased)) ? .released : .pressed
        logDebug("carbon_dispatch id=\(hotkeyID.id) action=\(action) edge=\(hotkeyEvent.rawValue)")
        handler?(action, hotkeyEvent)
    }

    private func handleMonitoredKeyDownEvent(_ event: NSEvent) {
        guard !event.isARepeat else {
            return
        }

        let combo = MonitoredHotkey(
            keyCode: UInt32(event.keyCode),
            modifiers: normalizedModifiers(hotkeyModifiers(from: event.modifierFlags))
        )
        guard combo.keyCode != HotkeyBinding.modifiersOnlyKeyCode else {
            return
        }
        let (action, handler, shouldDispatch) = currentMonitoredActionAndHandler(for: combo, event: .pressed)
        guard shouldDispatch, let action else {
            return
        }
        logDebug("monitored_keydown_dispatch combo=\(describe(combo)) action=\(action)")
        handler?(action, .pressed)
    }

    private func handleMonitoredKeyUpEvent(_ event: NSEvent) {
        let combo = MonitoredHotkey(
            keyCode: UInt32(event.keyCode),
            modifiers: normalizedModifiers(hotkeyModifiers(from: event.modifierFlags))
        )
        guard combo.keyCode != HotkeyBinding.modifiersOnlyKeyCode else {
            return
        }

        let (action, handler, shouldDispatch) = currentMonitoredActionAndHandler(for: combo, event: .released)
        guard shouldDispatch, let action else {
            return
        }
        logDebug("monitored_keyup_dispatch combo=\(describe(combo)) action=\(action)")
        handler?(action, .released)
    }

    private func handleMonitoredFlagsChangedEvent(_ event: NSEvent) {
        let currentModifiers = normalizedModifiers(hotkeyModifiers(from: event.modifierFlags))
        let combos = currentModifierOnlyCombosSnapshot()

        for combo in combos {
            if combo.modifiers == currentModifiers {
                let shouldDispatchOnEdge = markModifierOnlyComboEntered(combo)
                guard shouldDispatchOnEdge else {
                    continue
                }

                let (action, handler, shouldDispatch) = currentMonitoredActionAndHandler(for: combo, event: .pressed)
                guard shouldDispatch, let action else {
                    continue
                }
                logDebug("monitored_modifiers_dispatch combo=\(describe(combo)) action=\(action)")
                handler?(action, .pressed)
            } else {
                let shouldDispatchOnEdge = markModifierOnlyComboExited(combo)
                guard shouldDispatchOnEdge else {
                    continue
                }

                let (action, handler, shouldDispatch) = currentMonitoredActionAndHandler(for: combo, event: .released)
                guard shouldDispatch, let action else {
                    continue
                }
                logDebug("monitored_modifiers_release combo=\(describe(combo)) action=\(action)")
                handler?(action, .released)
            }
        }
    }

    private func updateBindingsSnapshot(
        bindings: [HotkeyBinding],
        handler: @escaping @Sendable (String, HotkeyEvent) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        self.registeredBindings = bindings
        self.onHotkey = handler
    }

    private func currentBindingsSnapshot() -> [HotkeyBinding] {
        lock.lock()
        defer { lock.unlock() }
        return registeredBindings
    }

    private func currentActionAndHandler(for hotkeyID: UInt32) -> (String?, (@Sendable (String, HotkeyEvent) -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        return (actionByID[hotkeyID], onHotkey)
    }

    private func currentMonitoredActionAndHandler(
        for combo: MonitoredHotkey,
        event: HotkeyEvent
    ) -> (String?, (@Sendable (String, HotkeyEvent) -> Void)?, Bool) {
        lock.lock()
        defer { lock.unlock() }

        guard let action = monitoredBindings[combo] else {
            return (nil, onHotkey, false)
        }

        let now = Date()
        let dispatchKey = "\(combo.keyCode):\(combo.modifiers.rawValue):\(event.rawValue)"
        if let previous = lastDispatchByMonitoredHotkeyEvent[dispatchKey], now.timeIntervalSince(previous) < 0.20 {
            return (nil, onHotkey, false)
        }
        lastDispatchByMonitoredHotkeyEvent[dispatchKey] = now
        return (action, onHotkey, true)
    }

    private func currentModifierOnlyCombosSnapshot() -> [MonitoredHotkey] {
        lock.lock()
        defer { lock.unlock() }
        return Array(modifierOnlyCombos)
    }

    private func markModifierOnlyComboEntered(_ combo: MonitoredHotkey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if activeModifierOnlyCombos.contains(combo) {
            return false
        }
        activeModifierOnlyCombos.insert(combo)
        return true
    }

    private func markModifierOnlyComboExited(_ combo: MonitoredHotkey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeModifierOnlyCombos.remove(combo) != nil
    }

    private func carbonModifiers(from modifiers: HotkeyModifiers) -> UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) {
            flags |= UInt32(cmdKey)
        }
        if modifiers.contains(.option) {
            flags |= UInt32(optionKey)
        }
        if modifiers.contains(.control) {
            flags |= UInt32(controlKey)
        }
        if modifiers.contains(.shift) {
            flags |= UInt32(shiftKey)
        }
        return flags
    }

    private func hotkeyModifiers(from flags: NSEvent.ModifierFlags) -> HotkeyModifiers {
        var modifiers: HotkeyModifiers = []
        if flags.contains(.command) {
            modifiers.insert(.command)
        }
        if flags.contains(.option) {
            modifiers.insert(.option)
        }
        if flags.contains(.control) {
            modifiers.insert(.control)
        }
        if flags.contains(.shift) {
            modifiers.insert(.shift)
        }
        if flags.contains(.function) {
            modifiers.insert(.function)
        }
        return modifiers
    }

    private func normalizedModifiers(_ modifiers: HotkeyModifiers) -> HotkeyModifiers {
        var result: HotkeyModifiers = []
        if modifiers.contains(.command) {
            result.insert(.command)
        }
        if modifiers.contains(.option) {
            result.insert(.option)
        }
        if modifiers.contains(.control) {
            result.insert(.control)
        }
        if modifiers.contains(.shift) {
            result.insert(.shift)
        }
        if modifiers.contains(.function) {
            result.insert(.function)
        }
        return result
    }

    private func shouldUseEventMonitor(for binding: HotkeyBinding) -> Bool {
        // Carbon RegisterEventHotKey only supports classic modifier bits and requires a concrete key.
        binding.modifiers.contains(.function) || binding.keyCode == HotkeyBinding.modifiersOnlyKeyCode
    }

    private func configureEventMonitors(bindings: [HotkeyBinding]) {
        guard !bindings.isEmpty else {
            lock.lock()
            monitoredBindings.removeAll(keepingCapacity: true)
            modifierOnlyCombos.removeAll(keepingCapacity: true)
            activeModifierOnlyCombos.removeAll(keepingCapacity: true)
            lastDispatchByMonitoredHotkeyEvent.removeAll(keepingCapacity: true)
            lock.unlock()
            removeEventMonitors()
            logDebug("event_monitors_removed")
            return
        }

        var mapped: [MonitoredHotkey: String] = [:]
        for binding in bindings {
            let combo = MonitoredHotkey(
                keyCode: binding.keyCode,
                modifiers: normalizedModifiers(binding.modifiers)
            )
            mapped[combo] = binding.actionID
        }

        lock.lock()
        monitoredBindings = mapped
        modifierOnlyCombos = Set(mapped.keys.filter { $0.keyCode == HotkeyBinding.modifiersOnlyKeyCode })
        activeModifierOnlyCombos.removeAll(keepingCapacity: true)
        lastDispatchByMonitoredHotkeyEvent.removeAll(keepingCapacity: true)
        lock.unlock()

        installEventMonitorsIfNeeded()
        logDebug("event_monitors_configured count=\(bindings.count)")
    }

    private func installEventMonitorsIfNeeded() {
        let install = { [weak self] in
            guard let self else {
                return
            }
            if self.globalMonitor == nil {
                self.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    self?.handleMonitoredKeyDownEvent(event)
                }
            }
            if self.localMonitor == nil {
                self.localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    self?.handleMonitoredKeyDownEvent(event)
                    return event
                }
            }
            if self.globalKeyUpMonitor == nil {
                self.globalKeyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
                    self?.handleMonitoredKeyUpEvent(event)
                }
            }
            if self.localKeyUpMonitor == nil {
                self.localKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
                    self?.handleMonitoredKeyUpEvent(event)
                    return event
                }
            }
            if self.globalFlagsMonitor == nil {
                self.globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                    self?.handleMonitoredFlagsChangedEvent(event)
                }
            }
            if self.localFlagsMonitor == nil {
                self.localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                    self?.handleMonitoredFlagsChangedEvent(event)
                    return event
                }
            }
        }

        if Thread.isMainThread {
            install()
        } else {
            DispatchQueue.main.sync(execute: install)
        }
    }

    private func removeEventMonitors() {
        let remove = { [weak self] in
            guard let self else {
                return
            }
            if let globalMonitor {
                NSEvent.removeMonitor(globalMonitor)
                self.globalMonitor = nil
            }
            if let localMonitor {
                NSEvent.removeMonitor(localMonitor)
                self.localMonitor = nil
            }
            if let globalKeyUpMonitor {
                NSEvent.removeMonitor(globalKeyUpMonitor)
                self.globalKeyUpMonitor = nil
            }
            if let localKeyUpMonitor {
                NSEvent.removeMonitor(localKeyUpMonitor)
                self.localKeyUpMonitor = nil
            }
            if let globalFlagsMonitor {
                NSEvent.removeMonitor(globalFlagsMonitor)
                self.globalFlagsMonitor = nil
            }
            if let localFlagsMonitor {
                NSEvent.removeMonitor(localFlagsMonitor)
                self.localFlagsMonitor = nil
            }
        }

        if Thread.isMainThread {
            remove()
        } else {
            DispatchQueue.main.sync(execute: remove)
        }
    }

    private func installWakeObserver() {
        wakeObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else {
                return
            }
            Task {
                await self.recoverAfterWake()
            }
        }
    }

    private func describe(_ binding: HotkeyBinding) -> String {
        "action=\(binding.actionID)|key_code=\(binding.keyCode)|mods=\(describe(binding.modifiers))"
    }

    private func describe(_ combo: MonitoredHotkey) -> String {
        if combo.keyCode == HotkeyBinding.modifiersOnlyKeyCode {
            return "modifier_only|mods=\(describe(combo.modifiers))"
        }
        return "key_code=\(combo.keyCode)|mods=\(describe(combo.modifiers))"
    }

    private func describe(_ modifiers: HotkeyModifiers) -> String {
        var parts: [String] = []
        if modifiers.contains(.function) { parts.append("fn") }
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.command) { parts.append("cmd") }
        return parts.isEmpty ? "none" : parts.joined(separator: "+")
    }

    private static func hotkeyLogURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quedo", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        return base.appendingPathComponent("hotkeys.log")
    }

    private func logDebug(_ message: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
        let line = "\(timestamp) \(message)\n"
        let url = Self.hotkeyLogURL()

        Self.logQueue.async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) {
                    _ = FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                if
                    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                    let size = attributes[.size] as? NSNumber,
                    size.intValue > Self.maxHotkeyLogBytes
                {
                    try Self.rotateHotkeyLog(at: url)
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                if let data = line.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
            } catch {
                // Avoid surfacing diagnostics write failures to runtime flow.
            }
        }
    }

    private static func rotateHotkeyLog(at active: URL) throws {
        let fileManager = FileManager.default
        for index in stride(from: maxHotkeyLogFiles - 1, through: 1, by: -1) {
            let current = active.deletingLastPathComponent().appendingPathComponent("hotkeys.\(index).log")
            let next = active.deletingLastPathComponent().appendingPathComponent("hotkeys.\(index + 1).log")
            if fileManager.fileExists(atPath: next.path) {
                try fileManager.removeItem(at: next)
            }
            if fileManager.fileExists(atPath: current.path) {
                try fileManager.moveItem(at: current, to: next)
            }
        }

        let first = active.deletingLastPathComponent().appendingPathComponent("hotkeys.1.log")
        if fileManager.fileExists(atPath: first.path) {
            try fileManager.removeItem(at: first)
        }
        if fileManager.fileExists(atPath: active.path) {
            try fileManager.moveItem(at: active, to: first)
        }
        _ = fileManager.createFile(atPath: active.path, contents: nil)
    }
}
