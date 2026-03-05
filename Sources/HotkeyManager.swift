import Cocoa
import Carbon

/// Simplified HotkeyManager - only supports Fn (Globe) key for toggle recording
class HotkeyManager {
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var isKeyDown = false
    private var wasPressed = false  // Track if Fn was previously pressed

    var onToggle: (() -> Void)?  // Single callback for toggle action

    /// Start monitoring Fn key (Globe/Emoji key)
    /// Fn key uses toggle mode: press to start recording, press again to stop
    func start() {
        stop()
        isKeyDown = false
        wasPressed = false

        // Fn/Globe key is a modifier key, so we monitor flagsChanged events
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event: event)
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event: event)
            return event
        }
    }

    private func handleFlagsChanged(event: NSEvent) {
        // Fn key has keyCode 63
        guard event.keyCode == 63 else { return }

        // Check if Fn/Globe modifier flag is set
        let flagIsSet = event.modifierFlags.contains(.function)

        if flagIsSet && !isKeyDown {
            // Fn key just pressed down
            isKeyDown = true

            // Only trigger toggle on key press (not release)
            // This implements true toggle mode: press once to start, press again to stop
            onToggle?()
        } else if !flagIsSet && isKeyDown {
            // Fn key released
            isKeyDown = false
        }
    }

    func stop() {
        if let m = globalFlagsMonitor { NSEvent.removeMonitor(m) }
        if let m = localFlagsMonitor { NSEvent.removeMonitor(m) }
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
        isKeyDown = false
        wasPressed = false
    }

    deinit {
        stop()
    }
}
