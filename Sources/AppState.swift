import Foundation
import Combine
import AppKit
import AVFoundation
import CoreAudio
import ServiceManagement
import os.log

private let recordingLog = OSLog(subsystem: "com.simplevoiceinput.app", category: "Recording")

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .history: return "History"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

final class AppState: ObservableObject, @unchecked Sendable {
    private let apiKeyStorageKey = "gemini_api_key"
    private let modelNameStorageKey = "gemini_model_name"
    private let customVocabularyStorageKey = "custom_vocabulary"
    private let selectedMicrophoneStorageKey = "selected_microphone_id"
    private let systemPromptStorageKey = "system_prompt"
    private let systemPromptLastModifiedStorageKey = "system_prompt_last_modified"
    private let systemPromptBackupsStorageKey = "system_prompt_backups"
    private let transcribingIndicatorDelay: TimeInterval = 1.0
    let maxPipelineHistoryCount = Int.max

    @Published var hasCompletedSetup: Bool {
        didSet {
            UserDefaults.standard.set(hasCompletedSetup, forKey: "hasCompletedSetup")
        }
    }

    @Published var apiKey: String {
        didSet {
            persistAPIKey(apiKey)
        }
    }

    @Published var modelName: String {
        didSet {
            UserDefaults.standard.set(modelName, forKey: modelNameStorageKey)
        }
    }

    @Published var customVocabulary: String {
        didSet {
            UserDefaults.standard.set(customVocabulary, forKey: customVocabularyStorageKey)
        }
    }

    @Published var systemPrompt: String {
        didSet {
            UserDefaults.standard.set(systemPrompt, forKey: systemPromptStorageKey)
        }
    }

    @Published var systemPromptLastModified: String {
        didSet {
            UserDefaults.standard.set(systemPromptLastModified, forKey: "system_prompt_last_modified")
        }
    }

    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var lastTranscript: String = ""
    @Published var errorMessage: String?
    @Published var statusText: String = "Ready"
    @Published var hasAccessibility = false
    @Published var isDebugOverlayActive = false
    @Published var selectedSettingsTab: SettingsTab? = .general
    @Published var pipelineHistory: [PipelineHistoryItem] = []
    @Published var debugStatusMessage = "Idle"
    @Published var lastTranscriptPrompt: String = ""
    @Published var lastTranscriptionStatus: String = ""
    @Published var launchAtLogin: Bool {
        didSet { setLaunchAtLogin(launchAtLogin) }
    }

    @Published var selectedMicrophoneID: String {
        didSet {
            UserDefaults.standard.set(selectedMicrophoneID, forKey: selectedMicrophoneStorageKey)
        }
    }
    @Published var availableMicrophones: [AudioDevice] = []

    let audioRecorder = AudioRecorder()
    let hotkeyManager = HotkeyManager()
    let overlayManager = RecordingOverlayManager()
    private var accessibilityTimer: Timer?
    private var audioLevelCancellable: AnyCancellable?
    private var debugOverlayTimer: Timer?
    private var transcribingIndicatorTask: Task<Void, Never>?
    private var audioDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private let pipelineHistoryStore = PipelineHistoryStore()
    private var injectionTargetPID: pid_t?

    private struct SystemPromptBackup: Codable {
        let timestamp: Date
        let prompt: String
    }

    init() {
        let hasCompletedSetup = UserDefaults.standard.bool(forKey: "hasCompletedSetup")
        let apiKey = Self.loadStoredAPIKey(account: apiKeyStorageKey)
        let modelName = UserDefaults.standard.string(forKey: modelNameStorageKey) ?? "gemini-3-flash-preview"
        let customVocabulary = UserDefaults.standard.string(forKey: customVocabularyStorageKey) ?? ""
        let systemPrompt = UserDefaults.standard.string(forKey: systemPromptStorageKey) ?? Self.loadDefaultSystemPrompt()
        let systemPromptLastModified = UserDefaults.standard.string(forKey: systemPromptLastModifiedStorageKey) ?? ""
        let initialAccessibility = AXIsProcessTrusted()
        let savedHistory = pipelineHistoryStore.loadAllHistory()

        let selectedMicrophoneID = UserDefaults.standard.string(forKey: selectedMicrophoneStorageKey) ?? "default"

        self.hasCompletedSetup = hasCompletedSetup
        self.apiKey = apiKey
        self.modelName = modelName
        self.customVocabulary = customVocabulary
        self.systemPrompt = systemPrompt
        self.systemPromptLastModified = systemPromptLastModified
        self.pipelineHistory = savedHistory
        self.hasAccessibility = initialAccessibility
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.selectedMicrophoneID = selectedMicrophoneID

        refreshAvailableMicrophones()
        installAudioDeviceListener()
    }

    func saveSystemPrompt(_ newPrompt: String) {
        let trimmed = newPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let existing = systemPrompt
        if trimmed != existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var backups: [SystemPromptBackup] = []
            if let data = UserDefaults.standard.data(forKey: systemPromptBackupsStorageKey),
               let decoded = try? JSONDecoder().decode([SystemPromptBackup].self, from: data) {
                backups = decoded
            }
            backups.append(SystemPromptBackup(timestamp: Date(), prompt: existing))
            if backups.count > 50 {
                backups.removeFirst(backups.count - 50)
            }
            if let encoded = try? JSONEncoder().encode(backups) {
                UserDefaults.standard.set(encoded, forKey: systemPromptBackupsStorageKey)
            }
        }

        systemPrompt = trimmed
        systemPromptLastModified = ISO8601DateFormatter().string(from: Date())
    }

    deinit {
        removeAudioDeviceListener()
    }

    private func installAudioDeviceListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshAvailableMicrophones()
            }
        }
        audioDeviceListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            block
        )
    }

    private func removeAudioDeviceListener() {
        guard let block = audioDeviceListenerBlock else { return }
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            block
        )
        audioDeviceListenerBlock = nil
    }

    private static func loadStoredAPIKey(account: String) -> String {
        if let storedKey = AppSettingsStorage.load(account: account), !storedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return storedKey
        }
        return ""
    }

    private func persistAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            AppSettingsStorage.delete(account: apiKeyStorageKey)
        } else {
            AppSettingsStorage.save(trimmed, account: apiKeyStorageKey)
        }
    }

    private static func loadDefaultSystemPrompt() -> String {
        if let url = Bundle.main.url(forResource: "gemini3_prompt", withExtension: "md"),
           let content = try? String(contentsOf: url) {
            return content
        }
        return ""
    }

    static func audioStorageDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appName = "SimpleVoiceInput"
        let audioDir = appSupport.appendingPathComponent("\(appName)/audio", isDirectory: true)
        if !FileManager.default.fileExists(atPath: audioDir.path) {
            try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        }
        return audioDir
    }

    static func saveAudioFile(from tempURL: URL) -> String? {
        let fileName = UUID().uuidString + "." + tempURL.pathExtension
        let destURL = audioStorageDirectory().appendingPathComponent(fileName)
        do {
            try FileManager.default.copyItem(at: tempURL, to: destURL)
            return fileName
        } catch {
            return nil
        }
    }

    static func deleteAudioFile(_ fileName: String) {
        let fileURL = audioStorageDirectory().appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
    }

    func clearPipelineHistory() {
        do {
            let removedAudioFileNames = try pipelineHistoryStore.clearAll()
            for audioFileName in removedAudioFileNames {
                Self.deleteAudioFile(audioFileName)
            }
            pipelineHistory = []
        } catch {
            errorMessage = "Unable to clear run history: \(error.localizedDescription)"
        }
    }

    func deleteHistoryEntry(id: UUID) {
        guard let index = pipelineHistory.firstIndex(where: { $0.id == id }) else { return }
        do {
            if let audioFileName = try pipelineHistoryStore.delete(id: id) {
                Self.deleteAudioFile(audioFileName)
            }
            pipelineHistory.remove(at: index)
        } catch {
            errorMessage = "Unable to delete run history entry: \(error.localizedDescription)"
        }
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func startAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let trusted = AXIsProcessTrusted()
            if trusted != self.hasAccessibility {
                self.hasAccessibility = trusted
                if trusted {
                    self.stopAccessibilityPolling()
                }
            }
        }
    }

    func stopAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to set launch at login: \(error)")
        }
    }

    func refreshLaunchAtLoginStatus() {
        let current = SMAppService.mainApp.status == .enabled
        if current != launchAtLogin {
            launchAtLogin = current
        }
    }

    func refreshAvailableMicrophones() {
        availableMicrophones = AudioDevice.availableInputDevices()
    }

    func startHotkeyMonitoring() {
        hotkeyManager.onToggle = { [weak self] in
            DispatchQueue.main.async {
                self?.handleHotkeyPress()
            }
        }
        hotkeyManager.start()
    }

    private func handleHotkeyPress() {
        os_log(.info, log: recordingLog, "handleHotkeyPress() fired, isRecording=%{public}d, isTranscribing=%{public}d", isRecording, isTranscribing)
        toggleRecording()
    }

    func toggleRecording() {
        os_log(.info, log: recordingLog, "toggleRecording() called, isRecording=%{public}d", isRecording)
        if isRecording {
            stopAndTranscribe()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        let t0 = CFAbsoluteTimeGetCurrent()
        os_log(.info, log: recordingLog, "startRecording() entered")
        captureInjectionTargetIfNeeded()
        guard hasAccessibility else {
            injectionTargetPID = nil
            errorMessage = "Accessibility permission required. Grant access in System Settings > Privacy & Security > Accessibility."
            statusText = "No Accessibility"
            showAccessibilityAlert()
            return
        }
        os_log(.info, log: recordingLog, "accessibility check passed: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        guard ensureMicrophoneAccess() else { return }
        os_log(.info, log: recordingLog, "mic access check passed: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        beginRecording()
        os_log(.info, log: recordingLog, "startRecording() finished: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }

    private func ensureMicrophoneAccess() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.beginRecording()
                    } else {
                        self?.injectionTargetPID = nil
                        self?.errorMessage = "Microphone permission denied. Grant access in System Settings > Privacy & Security > Microphone."
                        self?.statusText = "No Microphone"
                        self?.showMicrophonePermissionAlert()
                    }
                }
            }
            return false
        default:
            injectionTargetPID = nil
            errorMessage = "Microphone permission denied. Grant access in System Settings > Privacy & Security > Microphone."
            statusText = "No Microphone"
            showMicrophonePermissionAlert()
            return false
        }
    }

    private func beginRecording() {
        os_log(.info, log: recordingLog, "beginRecording() entered")
        errorMessage = nil

        isRecording = true
        statusText = "Starting..."

        // Show initializing dots only if engine takes longer than 0.5s to start
        var overlayShown = false
        let initTimer = DispatchSource.makeTimerSource(queue: .main)
        initTimer.schedule(deadline: .now() + 0.5)
        initTimer.setEventHandler { [weak self] in
            guard let self, !overlayShown else { return }
            overlayShown = true
            os_log(.info, log: recordingLog, "engine slow — showing initializing overlay")
            self.overlayManager.showInitializing()
        }
        initTimer.resume()

        // Transition to waveform when first real audio arrives (any non-zero RMS)
        let deviceUID = selectedMicrophoneID
        audioRecorder.onRecordingReady = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                initTimer.cancel()
                os_log(.info, log: recordingLog, "first real audio — transitioning to waveform")
                self.statusText = "Recording..."
                if overlayShown {
                    self.overlayManager.transitionToRecording()
                } else {
                    self.overlayManager.showRecording()
                }
                overlayShown = true
                NSSound(named: "Tink")?.play()
            }
        }

        // Start engine on background thread so UI isn't blocked
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            do {
                try self.audioRecorder.startRecording(deviceUID: deviceUID)
                os_log(.info, log: recordingLog, "audioRecorder.startRecording() done: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
                DispatchQueue.main.async {
                    self.audioLevelCancellable = self.audioRecorder.$audioLevel
                        .receive(on: DispatchQueue.main)
                        .sink { [weak self] level in
                            self?.overlayManager.updateAudioLevel(level)
                        }
                }
            } catch {
                DispatchQueue.main.async {
                    initTimer.cancel()
                    self.isRecording = false
                    self.errorMessage = self.formattedRecordingStartError(error)
                    self.statusText = "Error"
                }
            }
        }
    }

    private func formattedRecordingStartError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain {
            return "Failed to start recording (audio subsystem error \(nsError.code)). Check microphone permissions and selected input device."
        }
        return "Failed to start recording: \(error.localizedDescription)"
    }

    func showMicrophonePermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Permission Required"
        alert.informativeText = "SimpleVoiceInput cannot record audio without Microphone access.\n\nGo to System Settings > Privacy & Security > Microphone and enable SimpleVoiceInput."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Dismiss")
        alert.icon = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            if let url = settingsURL {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "SimpleVoiceInput cannot type transcriptions without Accessibility access.\n\nGo to System Settings > Privacy & Security > Accessibility and enable SimpleVoiceInput."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Dismiss")
        alert.icon = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    private func stopAndTranscribe() {
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        debugStatusMessage = "Preparing audio"
        lastTranscriptPrompt = ""
        lastTranscriptionStatus = ""

        guard let fileURL = audioRecorder.stopRecording() else {
            audioRecorder.cleanup()
            injectionTargetPID = nil
            errorMessage = "No audio recorded"
            isRecording = false
            statusText = "Error"
            return
        }
        let savedAudioFileName = Self.saveAudioFile(from: fileURL)
        isRecording = false
        isTranscribing = true
        statusText = "Transcribing..."
        debugStatusMessage = "Processing audio with Gemini"
        errorMessage = nil
        NSSound(named: "Pop")?.play()
        overlayManager.slideUpToNotch { }

        transcribingIndicatorTask?.cancel()
        let indicatorDelay = transcribingIndicatorDelay
        transcribingIndicatorTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(indicatorDelay * 1_000_000_000))
                let shouldShowTranscribing = self?.isTranscribing ?? false
                guard shouldShowTranscribing else { return }
                await MainActor.run { [weak self] in
                    self?.overlayManager.showTranscribing()
                }
            } catch {}
        }

        let geminiService = GeminiService(apiKey: apiKey, model: modelName)

        Task {
            do {
                let result = try await geminiService.processAudio(
                    fileURL: fileURL,
                    systemPrompt: systemPrompt
                )

                await MainActor.run {
                    let trimmedTranscript = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.lastTranscriptPrompt = result.promptUsed
                    self.lastTranscriptionStatus = "Success"
                    self.lastTranscript = trimmedTranscript

                    self.recordPipelineHistoryEntry(
                        transcript: trimmedTranscript,
                        prompt: result.promptUsed,
                        processingStatus: "Success",
                        audioFileName: savedAudioFileName
                    )

                    self.transcribingIndicatorTask?.cancel()
                    self.transcribingIndicatorTask = nil
                    self.isTranscribing = false
                    self.debugStatusMessage = "Done"

                    if trimmedTranscript.isEmpty {
                        self.statusText = "Nothing to transcribe"
                        self.overlayManager.dismiss()
                    } else {
                        self.statusText = "Copied to clipboard!"
                        self.overlayManager.showDone()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                            self.overlayManager.dismiss()
                        }

                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(trimmedTranscript, forType: .string)

                        self.injectTranscriptAtCursor()
                    }

                    self.audioRecorder.cleanup()

                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if self.statusText == "Copied to clipboard!" || self.statusText == "Nothing to transcribe" {
                            self.statusText = "Ready"
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.transcribingIndicatorTask?.cancel()
                    self.transcribingIndicatorTask = nil
                    self.errorMessage = error.localizedDescription
                    self.injectionTargetPID = nil
                    self.isTranscribing = false
                    self.statusText = "Error"
                    self.audioRecorder.cleanup()
                    self.overlayManager.dismiss()
                    self.lastTranscript = ""
                    self.lastTranscriptionStatus = "Error: \(error.localizedDescription)"
                    self.lastTranscriptPrompt = ""
                    self.recordPipelineHistoryEntry(
                        transcript: "",
                        prompt: "",
                        processingStatus: "Error: \(error.localizedDescription)",
                        audioFileName: savedAudioFileName
                    )
                }
            }
        }
    }

    private func recordPipelineHistoryEntry(
        transcript: String,
        prompt: String,
        processingStatus: String,
        audioFileName: String? = nil
    ) {
        let newEntry = PipelineHistoryItem(
            timestamp: Date(),
            rawTranscript: transcript,
            postProcessedTranscript: transcript,
            postProcessingPrompt: prompt.isEmpty ? nil : prompt,
            contextSummary: "",
            contextPrompt: nil,
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "N/A",
            postProcessingStatus: processingStatus,
            debugStatus: debugStatusMessage,
            customVocabulary: customVocabulary,
            audioFileName: audioFileName
        )
        do {
            let removedAudioFileNames = try pipelineHistoryStore.append(newEntry, maxCount: maxPipelineHistoryCount)
            for audioFileName in removedAudioFileNames {
                Self.deleteAudioFile(audioFileName)
            }
            pipelineHistory = pipelineHistoryStore.loadAllHistory()
        } catch {
            errorMessage = "Unable to save run history entry: \(error.localizedDescription)"
        }
    }

    func toggleDebugOverlay() {
        if isDebugOverlayActive {
            stopDebugOverlay()
        } else {
            startDebugOverlay()
        }
    }

    private func startDebugOverlay() {
        isDebugOverlayActive = true
        overlayManager.showRecording()

        // Simulate audio levels with a timer
        var phase: Double = 0.0
        debugOverlayTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            phase += 0.15
            // Generate a fake audio level that oscillates like speech
            let base = 0.3 + 0.2 * sin(phase)
            let noise = Float.random(in: -0.15...0.15)
            let level = min(max(Float(base) + noise, 0.0), 1.0)
            self.overlayManager.updateAudioLevel(level)
        }
    }

    private func stopDebugOverlay() {
        debugOverlayTimer?.invalidate()
        debugOverlayTimer = nil
        isDebugOverlayActive = false
        overlayManager.dismiss()
    }

    func toggleDebugPanel() {
        selectedSettingsTab = .history
        NotificationCenter.default.post(name: .showSettings, object: nil)
    }

    func openRecordingDirectory() {
        let audioDir = Self.audioStorageDirectory()
        NSWorkspace.shared.open(audioDir)
    }

    func locateRecordingFile(audioFileName: String?) {
        guard let fileName = audioFileName else { return }
        let fileURL = Self.audioStorageDirectory().appendingPathComponent(fileName)
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    private func captureInjectionTargetIfNeeded() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        guard let frontmost, frontmost.processIdentifier != NSRunningApplication.current.processIdentifier else { return }
        injectionTargetPID = frontmost.processIdentifier
    }

    private func captureInjectionTarget() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        guard let frontmost, frontmost.processIdentifier != NSRunningApplication.current.processIdentifier else { return }
        injectionTargetPID = frontmost.processIdentifier
    }

    private func injectTranscriptAtCursor() {
        guard !lastTranscript.isEmpty else {
            injectionTargetPID = nil
            return
        }

        // If target PID is lost, try to capture current frontmost (might be us if overlay took focus, but better than nothing)
        if injectionTargetPID == nil {
            captureInjectionTarget()
        }

        var appToActivate: NSRunningApplication?
        if let pid = injectionTargetPID {
            appToActivate = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid })
        }

        if let app = appToActivate {
            // Force activate the target application
            let success = app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            if !success {
                os_log(.error, log: recordingLog, "Failed to activate target app PID %{public}d", app.processIdentifier)
            }
        }

        // Wait for app activation to complete before pasting
        // 0.6s should be enough for most context switches
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.pasteAtCursor()
            self?.injectionTargetPID = nil
        }
    }

    private func pasteAtCursor() {
        // Use .hidSystemState for more reliable event posting
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            os_log(.error, log: recordingLog, "Failed to create CGEventSource")
            return
        }

        // Command + V
        let cmdFlag = CGEventFlags.maskCommand
        
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // 0x09 is 'v'
        keyDown?.flags = cmdFlag
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = cmdFlag
        keyUp?.post(tap: .cghidEventTap)
        
        os_log(.info, log: recordingLog, "Posted Cmd+V events")
    }
}
