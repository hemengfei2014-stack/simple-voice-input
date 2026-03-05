import Foundation
import AppKit

final class HotkeyManager {
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var isFnDown = false

    var onToggle: (() -> Void)?

    func start() {
        stop()
        isFnDown = false

        // Use NSEvent monitors exclusively as they are more reliable for modifier keys
        // and handle system permissions more gracefully than CGEventTap.
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event: event)
        }
        
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event: event)
            return event
        }
    }

    private func handleFlagsChanged(event: NSEvent) {
        // Fn key code is typically 63
        guard event.keyCode == 63 else { return }

        // Check if the Function modifier flag is set
        let flagIsSet = event.modifierFlags.contains(.function)
        
        if flagIsSet {
            // Key Down
            if !isFnDown {
                isFnDown = true
                DispatchQueue.main.async { [weak self] in
                    self?.onToggle?()
                }
            }
        } else {
            // Key Up
            if isFnDown {
                isFnDown = false
            }
        }
    }

    func stop() {
        if let m = globalFlagsMonitor { NSEvent.removeMonitor(m) }
        if let m = localFlagsMonitor { NSEvent.removeMonitor(m) }
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
        isFnDown = false
    }

    deinit { stop() }
}
