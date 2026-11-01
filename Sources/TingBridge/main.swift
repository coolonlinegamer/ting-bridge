import AppKit
import ApplicationServices
import AVFoundation
import CoreAudio
import Darwin
import Foundation

enum TingControlEvent: Equatable {
    case ready
    case error(String)
    case handle(Bool)
    case green(Bool)
}

enum TingControlTransition: Equatable {
    case handleChanged(isPressed: Bool)
    case greenReleased
}

struct TingControlState {
    private var handlePressed = false
    private var greenPressed = false

    mutating func transition(for event: TingControlEvent) -> TingControlTransition? {
        switch event {
        case let .handle(isPressed):
            guard isPressed != handlePressed else { return nil }
            handlePressed = isPressed
            return .handleChanged(isPressed: isPressed)
        case let .green(isPressed):
            guard isPressed != greenPressed else { return nil }
            greenPressed = isPressed
            return isPressed ? nil : .greenReleased
        case .ready, .error:
            return nil
        }
    }
}

enum TingSerialProtocol {
    static func devicePath(from names: [String]) -> String? {
        names
            .filter { $0.hasPrefix("cu.usbmodemEPTX") }
            .sorted()
            .first
            .map { "/dev/\($0)" }
    }

    static func event(from line: String) -> TingControlEvent? {
        let fields = line.split(separator: " ")
        guard fields.count == 2 else { return nil }
        switch (fields[0], fields[1]) {
        case ("TING_READY", "1"):
            return .ready
        case ("TING_ERROR", let message):
            return .error(String(message))
        case ("TING_HANDLE", "0"):
            return .handle(false)
        case ("TING_HANDLE", "1"):
            return .handle(true)
        case ("TING_GREEN", "0"):
            return .green(true)
        case ("TING_GREEN", "1"):
            return .green(false)
        default:
            return nil
        }
    }
}

enum AudioProbeError: Error, CustomStringConvertible {
    case noInputChannels
    case permissionDenied

    var description: String {
        switch self {
        case .noInputChannels:
            return "The selected audio input has no readable channels."
        case .permissionDenied:
            return "Microphone access was denied."
        }
    }
}

final class AudioMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0
    private var sumSquares: Double = 0
    private var sampleCount: UInt64 = 0

    func consume(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return }

        var localPeak: Float = 0
        var localSquares: Double = 0
        for channel in 0..<channelCount {
            for frame in 0..<frames {
                let sample = channels[channel][frame]
                localPeak = max(localPeak, abs(sample))
                localSquares += Double(sample * sample)
            }
        }

        lock.lock()
        peak = max(peak, localPeak)
        sumSquares += localSquares
        sampleCount += UInt64(frames * channelCount)
        lock.unlock()
    }

    func result() -> (peak: Float, rms: Float) {
        lock.lock()
        defer { lock.unlock() }
        let rms = sampleCount == 0 ? 0 : Float(sqrt(sumSquares / Double(sampleCount)))
        return (peak, rms)
    }
}

func requestMicrophonePermission() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        return true
    case .notDetermined:
        return await AVCaptureDevice.requestAccess(for: .audio)
    default:
        return false
    }
}

func probeAudio(seconds: Double) async throws {
    guard await requestMicrophonePermission() else {
        throw AudioProbeError.permissionDenied
    }

    let engine = AVAudioEngine()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.channelCount > 0 else {
        throw AudioProbeError.noInputChannels
    }

    let meter = AudioMeter()
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
        meter.consume(buffer)
    }

    defer {
        input.removeTap(onBus: 0)
        engine.stop()
    }

    try engine.start()
    print("AUDIO_PROBE_STARTED channels=\(format.channelCount) sample_rate=\(Int(format.sampleRate)) seconds=\(seconds)")
    try await Task.sleep(for: .seconds(seconds))

    let result = meter.result()
    let peakDB = result.peak > 0 ? 20 * log10(result.peak) : -.infinity
    let rmsDB = result.rms > 0 ? 20 * log10(result.rms) : -.infinity
    print(String(format: "AUDIO_PROBE_RESULT peak=%.6f peak_db=%.1f rms=%.6f rms_db=%.1f", result.peak, peakDB, result.rms, rmsDB))
}

enum SupportedApp: String {
    case codex = "com.openai.codex"
    case claude = "com.anthropic.claudefordesktop"
    case terminal = "com.googlecode.iterm2"

    struct FocusedInfo {
        let app: SupportedApp?
        let pid: pid_t
        let bundleID: String
    }

    static func matching(bundleID: String) -> SupportedApp? {
        [SupportedApp.codex, .claude, .terminal].first {
            bundleID == $0.rawValue || bundleID.hasPrefix($0.rawValue + ".")
        }
    }

    static func focused() -> FocusedInfo? {
        if let focused = focusedThroughAccessibility() {
            return focused
        }

        if let active = NSWorkspace.shared.runningApplications.first(where: { $0.isActive }),
           let bundleID = active.bundleIdentifier {
            return focusedInfo(pid: active.processIdentifier, bundleID: bundleID)
        }

        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        for window in windows {
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pidNumber = window[kCGWindowOwnerPID as String] as? NSNumber,
                  let running = NSRunningApplication(processIdentifier: pidNumber.int32Value),
                  let bundleID = running.bundleIdentifier else {
                continue
            }
            return focusedInfo(pid: running.processIdentifier, bundleID: bundleID)
        }
        return nil
    }

    private static func focusedThroughAccessibility() -> FocusedInfo? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue,
        CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return nil
        }

        let focusedElement = focusedValue as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementGetPid(focusedElement, &pid) == .success,
              let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else {
            return nil
        }
        return focusedInfo(pid: pid, bundleID: bundleID)
    }

    private static func focusedInfo(pid: pid_t, bundleID: String) -> FocusedInfo {
        guard let app = matching(bundleID: bundleID) else {
            return FocusedInfo(app: nil, pid: pid, bundleID: bundleID)
        }

        let mainPID = NSRunningApplication
            .runningApplications(withBundleIdentifier: app.rawValue)
            .first?
            .processIdentifier ?? pid
        return FocusedInfo(app: app, pid: mainPID, bundleID: bundleID)
    }
}

private func envMilliseconds(_ name: String, default fallback: Int) -> Int {
    guard let raw = ProcessInfo.processInfo.environment[name],
          let value = Int(raw),
          value > 0,
          value <= 5000 else {
        return fallback
    }
    return value
}

// The Ting's analog out feeds a separate audio interface (the dock's mic input),
// so dictation only hears it if that interface is the default input. macOS can
// fall back to the built-in mic on redock, so re-select it on every handle press.
enum DefaultInputSelector {
    static let deviceName = ProcessInfo.processInfo.environment["TING_BRIDGE_INPUT_DEVICE"]
        ?? "CalDigit Thunderbolt 3 Audio"

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func allDevices() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else {
            return []
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var addr = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr,
              let value = name?.takeRetainedValue() else {
            return nil
        }
        return value as String
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func currentDefault() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else {
            return nil
        }
        return id
    }

    static func ensureSelected() {
        guard let target = allDevices().first(where: { hasInput($0) && name(of: $0) == deviceName }) else {
            log("Input device \"\(deviceName)\" not found; leaving default input unchanged")
            return
        }
        guard currentDefault() != target else { return }
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = target
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                                UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        if status == noErr {
            log("Default input switched to \"\(deviceName)\"")
        } else {
            log("Failed to set default input to \"\(deviceName)\" (OSStatus \(status))")
        }
    }
}

final class InputController {
    private enum DictationSession {
        case none
        case codexPossiblyRecording
        case codexAlreadyRecording
        case claude
        case terminal
    }

    private var dictationSession: DictationSession = .none
    private var claudeButtonPoint: CGPoint?
    private var savedMousePoint: CGPoint?
    private var loggedClaudeButtons = false
    private var spaceRepeatTimer: DispatchSourceTimer?
    private let spaceRepeatQueue = DispatchQueue(label: "com.bubblymagic.tingbridge.spacerepeat")
    private static let spaceInitialDelay = envMilliseconds("TING_BRIDGE_SPACE_INITIAL_MS", default: 30)
    private static let spaceRepeatInterval = envMilliseconds("TING_BRIDGE_SPACE_REPEAT_MS", default: 15)

    private enum CodexDictationState {
        case idle
        case recording
        case unknown
    }

    private struct AXButtonInfo {
        let element: AXUIElement
        let label: String
        let center: CGPoint?
    }

    func handleChanged(isPressed: Bool) {
        if isPressed {
            DefaultInputSelector.ensureSelected()
            startDictation()
        } else {
            stopDictation()
        }
    }

    func greenReleased() {
        guard let focused = SupportedApp.focused(), let app = focused.app else {
            let bundleID = SupportedApp.focused()?.bundleID ?? "unknown"
            log("Ignoring green button because focused app is unsupported: \(bundleID)")
            return
        }
        switch app {
        case .codex:
            postKey(keyCode: 36)
            log("Green -> Return in Codex")
        case .claude:
            logClaudeFocusedElement(pid: focused.pid, context: "green pressed")
            guard focusClaudePrompt(pid: focused.pid) else {
                log("Green -> refused: could not verify focus on a visible Claude text entry")
                return
            }
            usleep(50_000)
            postKey(keyCode: 36)
            log("Green -> Return sent to verified Claude prompt")
        case .terminal:
            postKey(keyCode: 36)
            log("Green -> Return in terminal")
        }
    }

    func releaseAnythingHeld() {
        stopDictation()
    }

    private func startDictation() {
        if case .codexPossiblyRecording = dictationSession,
           !isCodexRunning() {
            log("Clearing retained Codex recording state because Codex is no longer running")
            clearDictationSession()
        }
        guard case .none = dictationSession else {
            log("Ignoring handle because a prior dictation session still requires a verified release")
            return
        }
        guard let focused = SupportedApp.focused(), let app = focused.app else {
            let bundleID = SupportedApp.focused()?.bundleID ?? "unknown"
            log("Ignoring handle because focused app is unsupported: \(bundleID)")
            return
        }

        switch app {
        case .codex:
            guard let button = findCodexDictationButton(pid: focused.pid), let point = button.center else {
                log("Could not find Codex's microphone button")
                return
            }
            switch codexDictationState(for: button.label) {
            case .recording:
                dictationSession = .codexAlreadyRecording
                log("Handle down -> Codex was already recording; leaving its control unchanged")
            case .idle:
                guard clickPhysically(at: point, expectedApp: .codex) else { return }
                dictationSession = .codexPossiblyRecording
                usleep(300_000)
                guard let current = findCodexDictationButton(pid: focused.pid),
                      codexDictationState(for: current.label) == .recording else {
                    log("Handle down -> Codex start click was not confirmed; retaining possible recording state until stop is verified")
                    return
                }
                log("Handle down -> started Codex dictation and confirmed stop state")
            case .unknown:
                log("Handle down -> refusing Codex click because dictation state is unknown: \(button.label)")
            }
        case .claude:
            guard let point = findClaudeDictationButtonCenter(pid: focused.pid) else {
                log("Could not find Claude's 'Press and hold to record' button")
                return
            }
            guard targetAt(point, belongsTo: .claude) else {
                log("Refusing Claude mouse-down because the target point does not belong to Claude")
                return
            }
            savedMousePoint = CGEvent(source: nil)?.location
            claudeButtonPoint = point
            postMouse(type: .mouseMoved, at: point)
            postMouse(type: .leftMouseDown, at: point)
            dictationSession = .claude
            log("Handle down -> holding Claude dictation button")
        case .terminal:
            postKey(keyCode: 49, autoRelease: false)
            startSpaceRepeat()
            dictationSession = .terminal
            log("Handle down -> holding space in terminal")
        }
    }

    private func stopDictation() {
        switch dictationSession {
        case .none:
            return
        case .codexAlreadyRecording:
            log("Handle up -> Codex was already recording before Ting Bridge acted; leaving it unchanged")
            clearDictationSession()
        case .codexPossiblyRecording:
            if let focused = SupportedApp.focused(),
               focused.app == .codex,
               let button = findCodexDictationButton(pid: focused.pid),
               let point = button.center {
                switch codexDictationState(for: button.label) {
                case .recording:
                    guard clickPhysically(at: point, expectedApp: .codex) else {
                        log("Handle up -> could not safely click Codex; retaining possible recording state")
                        return
                    }
                    usleep(300_000)
                    guard let current = findCodexDictationButton(pid: focused.pid),
                          codexDictationState(for: current.label) == .idle else {
                        log("Handle up -> Codex stop click was not confirmed; retaining possible recording state")
                        return
                    }
                    log("Handle up -> stopped Codex dictation and confirmed idle state")
                    clearDictationSession()
                case .idle:
                    log("Handle up -> Codex is confirmed idle")
                    clearDictationSession()
                case .unknown:
                    log("Handle up -> refusing Codex click because dictation state is unknown; retaining possible recording state: \(button.label)")
                }
            } else {
                log("Handle up -> refused to click because Codex is no longer focused or its control is obscured; retaining possible recording state")
            }
        case .claude:
            if let point = claudeButtonPoint {
                postMouse(type: .leftMouseUp, at: point)
            }
            if let focused = SupportedApp.focused(), focused.app == .claude {
                if focusClaudePrompt(pid: focused.pid) {
                    log("Handle up -> restored focus to visible Claude prompt")
                }
            }
            if let point = savedMousePoint {
                postMouse(type: .mouseMoved, at: point)
            }
            log("Handle up -> released Claude dictation button")
            clearDictationSession()
        case .terminal:
            stopSpaceRepeat()
            postKey(keyCode: 49, keyDown: false)
            if let focused = SupportedApp.focused(), focused.app != .terminal {
                log("Handle up -> released space, but focus had moved to \(focused.bundleID)")
            } else {
                log("Handle up -> released space in terminal")
            }
            clearDictationSession()
        }
    }

    private func clearDictationSession() {
        stopSpaceRepeat()
        dictationSession = .none
        claudeButtonPoint = nil
        savedMousePoint = nil
    }

    private func isCodexRunning() -> Bool {
        !NSRunningApplication
            .runningApplications(withBundleIdentifier: SupportedApp.codex.rawValue)
            .isEmpty
    }

    private func codexDictationState(for label: String) -> CodexDictationState {
        if label.contains("stop") || label.contains("recording") || label.contains("finish") {
            return .recording
        }
        if label.contains("dictat") || label.contains("microphone") ||
            (label.contains("voice") && label.contains("input")) {
            return .idle
        }
        return .unknown
    }

    private func findCodexDictationButton(pid: pid_t) -> AXButtonInfo? {
        let root = AXUIElementCreateApplication(pid)
        var buttons: [AXButtonInfo] = []
        collectButtons(in: root, depth: 0, into: &buttons)

        if let labeled = buttons.max(by: { codexButtonScore($0.label) < codexButtonScore($1.label) }),
           codexButtonScore(labeled.label) > 0 {
            return labeled
        }

        if let send = buttons
            .filter({ $0.label.contains("send") || $0.label.contains("submit") })
            .compactMap({ button -> (AXButtonInfo, CGPoint)? in
                guard let point = button.center else { return nil }
                return (button, point)
            })
            .max(by: { $0.1.x < $1.1.x }),
           let microphone = buttons
            .filter({ button in
                guard let point = button.center else { return false }
                return point.x < send.1.x
                    && send.1.x - point.x < 120
                    && abs(point.y - send.1.y) < 50
            })
            .max(by: { ($0.center?.x ?? -.infinity) < ($1.center?.x ?? -.infinity) }) {
            log("Codex microphone matched by position immediately left of Send; AX label: \(microphone.label)")
            return microphone
        }

        let diagnostic = buttons
            .map(\.label)
            .filter({ !$0.isEmpty })
            .prefix(40)
            .joined(separator: " | ")
        log("Codex AX buttons visible (\(buttons.count)): \(diagnostic)")
        return nil
    }

    private func codexButtonScore(_ label: String) -> Int {
        var score = 0
        if label.contains("dictat") { score += 100 }
        if label.contains("microphone") { score += 90 }
        if label.contains("record") { score += 70 }
        if label.contains("voice") && label.contains("input") { score += 60 }
        if label.contains("stop") || label.contains("finish") { score += 20 }
        return score
    }

    private func collectButtons(
        in element: AXUIElement,
        depth: Int,
        into buttons: inout [AXButtonInfo]
    ) {
        guard depth < 40 else { return }

        let role = copyStringAttribute(element, kAXRoleAttribute as CFString)
        if role == kAXButtonRole as String {
            let attributes = [
                kAXTitleAttribute as CFString,
                kAXDescriptionAttribute as CFString,
                kAXHelpAttribute as CFString,
                kAXIdentifierAttribute as CFString,
                kAXRoleDescriptionAttribute as CFString,
            ]
            let label = attributes
                .compactMap { copyStringAttribute(element, $0) }
                .filter { !$0.isEmpty }
                .joined(separator: " / ")
                .lowercased()
            buttons.append(AXButtonInfo(element: element, label: label, center: center(of: element)))
        }

        guard let children = copyElementsAttribute(element, kAXChildrenAttribute as CFString) else {
            return
        }
        for child in children {
            collectButtons(in: child, depth: depth + 1, into: &buttons)
        }
    }

    // AXPress was tested first: macOS returned success, but Codex ignored it.
    // A real pointer down/up sequence is required by the current Codex mic control.
    private func clickPhysically(at point: CGPoint, expectedApp: SupportedApp) -> Bool {
        guard targetAt(point, belongsTo: expectedApp) else {
            log("Refusing physical click because the target point belongs to another process or is obscured")
            return false
        }
        let originalPoint = CGEvent(source: nil)?.location
        postMouse(type: .mouseMoved, at: point)
        usleep(30_000)
        postMouse(type: .leftMouseDown, at: point)
        usleep(50_000)
        postMouse(type: .leftMouseUp, at: point)
        usleep(30_000)
        if let originalPoint {
            postMouse(type: .mouseMoved, at: originalPoint)
        }
        return true
    }

    private func targetAt(_ point: CGPoint, belongsTo expectedApp: SupportedApp) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var target: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide,
            Float(point.x),
            Float(point.y),
            &target
        ) == .success,
        let target else {
            return false
        }

        var actualPID: pid_t = 0
        guard AXUIElementGetPid(target, &actualPID) == .success,
              let bundleID = NSRunningApplication(processIdentifier: actualPID)?.bundleIdentifier else {
            return false
        }
        return SupportedApp.matching(bundleID: bundleID) == expectedApp
    }

    private func startSpaceRepeat() {
        spaceRepeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: spaceRepeatQueue)
        timer.schedule(
            deadline: .now() + .milliseconds(InputController.spaceInitialDelay),
            repeating: .milliseconds(InputController.spaceRepeatInterval)
        )
        timer.setEventHandler {
            self.postKey(keyCode: 49, autoRelease: false, autorepeat: true)
        }
        spaceRepeatTimer = timer
        timer.resume()
    }

    private func stopSpaceRepeat() {
        spaceRepeatTimer?.cancel()
        spaceRepeatTimer = nil
    }

    private func postKey(
        keyCode: CGKeyCode,
        keyDown: Bool = true,
        flags: CGEventFlags = [],
        autoRelease: Bool = true,
        autorepeat: Bool = false
    ) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown) else {
            return
        }
        event.flags = flags
        if autorepeat {
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        }
        event.post(tap: .cghidEventTap)
        if keyDown && autoRelease && flags.isEmpty {
            usleep(20_000)
            CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)?.post(tap: .cghidEventTap)
        }
    }

    private func postMouse(type: CGEventType, at point: CGPoint) {
        CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }

    private func findClaudeDictationButtonCenter(pid: pid_t) -> CGPoint? {
        guard let root = focusedWindow(pid: pid) else { return nil }
        guard let point = findButton(in: root, depth: 0) else {
            if !loggedClaudeButtons {
                loggedClaudeButtons = true
                logButtons(in: root)
            }
            return nil
        }
        if let windowFrame = frameOf(root), !windowFrame.contains(point) {
            log("Ignoring off-window 'hold to record' element at \(Int(point.x)),\(Int(point.y))")
            return nil
        }
        return point
    }

    private struct AXTextEntryInfo {
        let element: AXUIElement
        let summary: String
        let frame: CGRect
        var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
    }

    private func isTextEntryRole(_ element: AXUIElement) -> Bool {
        let role = copyStringAttribute(element, kAXRoleAttribute as CFString)
        return role == kAXTextAreaRole as String || role == kAXTextFieldRole as String
    }

    private func focusedElement(pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func summarize(_ element: AXUIElement) -> String {
        let role = copyStringAttribute(element, kAXRoleAttribute as CFString) ?? "?"
        var parts = [role]
        let named: [(String, CFString)] = [
            ("desc", kAXDescriptionAttribute as CFString),
            ("title", kAXTitleAttribute as CFString),
            ("id", kAXIdentifierAttribute as CFString),
            ("placeholder", "AXPlaceholderValue" as CFString),
        ]
        for (name, attribute) in named {
            if let value = copyStringAttribute(element, attribute), !value.isEmpty {
                parts.append("\(name)='\(value.prefix(60))'")
            }
        }
        if let frame = frameOf(element) {
            parts.append("frame=(\(Int(frame.origin.x)),\(Int(frame.origin.y)) \(Int(frame.width))x\(Int(frame.height)))")
        }
        return parts.joined(separator: " ")
    }

    private func logClaudeFocusedElement(pid: pid_t, context: String) {
        if let focused = focusedElement(pid: pid) {
            log("Claude focused element (\(context)): \(summarize(focused))")
        } else {
            log("Claude focused element (\(context)): none reported")
        }
    }

    private func frameOf(_ element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func collectTextEntries(
        in element: AXUIElement,
        depth: Int,
        into entries: inout [AXTextEntryInfo]
    ) {
        guard depth < 40 else { return }
        if isTextEntryRole(element), let frame = frameOf(element) {
            entries.append(AXTextEntryInfo(element: element, summary: summarize(element), frame: frame))
        }
        guard let children = copyElementsAttribute(element, kAXChildrenAttribute as CFString) else {
            return
        }
        for child in children {
            collectTextEntries(in: child, depth: depth + 1, into: &entries)
        }
    }

    private func isSameOrDescendant(_ element: AXUIElement, of ancestor: AXUIElement) -> Bool {
        var current = element
        for _ in 0..<12 {
            if CFEqual(current, ancestor) { return true }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent,
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else {
                return false
            }
            current = parent as! AXUIElement
        }
        return false
    }

    private func hitPointIsInside(
        _ expectedEntry: AXUIElement,
        at point: CGPoint,
        expectedApp: SupportedApp
    ) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var target: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide,
            Float(point.x),
            Float(point.y),
            &target
        ) == .success,
        let target else {
            return false
        }
        var actualPID: pid_t = 0
        guard AXUIElementGetPid(target, &actualPID) == .success,
              let bundleID = NSRunningApplication(processIdentifier: actualPID)?.bundleIdentifier,
              SupportedApp.matching(bundleID: bundleID) == expectedApp else {
            return false
        }
        return isSameOrDescendant(target, of: expectedEntry)
    }

    // Home and code mode live in the same window, so hidden home-mode elements can
    // match label searches; only geometry (real size, on-window center) separates
    // the visible composer from stale views. Focus via AX first; a physical click
    // is allowed only when the point under it hit-tests inside that selected
    // prompt, so a mis-aimed click can never activate another text field or
    // the attach control.
    private func focusClaudePrompt(pid: pid_t) -> Bool {
        guard let window = focusedWindow(pid: pid), let windowFrame = frameOf(window) else {
            log("Claude focused window unavailable")
            return false
        }
        var entries: [AXTextEntryInfo] = []
        collectTextEntries(in: window, depth: 0, into: &entries)
        let visible = entries.filter { entry in
            entry.frame.width >= 40 && entry.frame.height >= 10
                && windowFrame.insetBy(dx: -1, dy: -1).contains(entry.center)
        }
        log("Claude text entries in focused window: total=\(entries.count) visible=\(visible.count)")
        for entry in visible.prefix(6) {
            log("Claude text entry candidate: \(entry.summary)")
        }
        guard let prompt = visible.max(by: { $0.center.y < $1.center.y }) else {
            log("No visible Claude text entry found; refusing to act")
            return false
        }

        if let focused = focusedElement(pid: pid), isSameOrDescendant(focused, of: prompt.element) {
            log("Claude focus already on the selected prompt: \(prompt.summary)")
            return true
        }

        AXUIElementSetAttributeValue(prompt.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        usleep(80_000)
        if let focused = focusedElement(pid: pid),
           isSameOrDescendant(focused, of: prompt.element) {
            log("Claude prompt focused via Accessibility: \(prompt.summary)")
            return true
        }

        let point = prompt.center
        guard hitPointIsInside(prompt.element, at: point, expectedApp: .claude) else {
            log("Refusing Claude focus click: element under \(Int(point.x)),\(Int(point.y)) is not inside the selected Claude prompt")
            return false
        }
        guard clickPhysically(at: point, expectedApp: .claude) else {
            log("Could not physically focus the visible Claude prompt")
            return false
        }
        usleep(80_000)
        if let focused = focusedElement(pid: pid), isSameOrDescendant(focused, of: prompt.element) {
            log("Claude prompt focused via physical click: \(prompt.summary)")
            return true
        }
        log("Claude prompt focus could not be verified after click; refusing to act")
        return false
    }

    private func focusedWindow(pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        // Electron keeps its web content out of the AX tree until a client asks for it.
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &value
        )
        guard result == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID() else {
            log("Focused window lookup failed for pid \(pid): AXError \(result.rawValue), trusted=\(AXIsProcessTrusted())")
            return nil
        }
        return (value as! AXUIElement)
    }

    private func findButton(in element: AXUIElement, depth: Int) -> CGPoint? {
        guard depth < 80 else { return nil }

        let description = copyStringAttribute(element, kAXDescriptionAttribute as CFString) ?? ""
        let title = copyStringAttribute(element, kAXTitleAttribute as CFString) ?? ""
        if description.localizedCaseInsensitiveContains("hold to record") ||
           title.localizedCaseInsensitiveContains("hold to record") {
            return center(of: element)
        }

        guard let children = copyElementsAttribute(element, kAXChildrenAttribute as CFString) else {
            return nil
        }
        for child in children {
            if let result = findButton(in: child, depth: depth + 1) {
                return result
            }
        }
        return nil
    }

    private func logButtons(in element: AXUIElement, depth: Int = 0) {
        guard depth < 80 else {
            log("Claude button search hit depth limit")
            return
        }
        let role = copyStringAttribute(element, kAXRoleAttribute as CFString) ?? ""
        let labelled = !(copyStringAttribute(element, kAXDescriptionAttribute as CFString) ?? "").isEmpty ||
            !(copyStringAttribute(element, kAXTitleAttribute as CFString) ?? "").isEmpty
        if role == kAXButtonRole as String || (labelled && (frameOf(element)?.minY ?? 0) > 700) {
            log("Claude button d\(depth): \(summarize(element))")
        }
        for child in copyElementsAttribute(element, kAXChildrenAttribute as CFString) ?? [] {
            logButtons(in: child, depth: depth + 1)
        }
    }

    private func center(of element: AXUIElement) -> CGPoint? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
    }

    private func copyStringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func copyElementsAttribute(_ element: AXUIElement, _ attribute: CFString) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? [AXUIElement]
    }
}

final class TingSerialBridge {
    private let controller: InputController
    private var lineBuffer = ""
    private var controlState = TingControlState()
    private var serialProcess: Process?

    init(controller: InputController) {
        self.controller = controller
    }

    deinit {
        serialProcess?.terminate()
        controller.releaseAnythingHeld()
    }

    func shutdown() -> Never {
        controller.releaseAnythingHeld()
        serialProcess?.terminate()
        Foundation.exit(0)
    }

    func runForever() -> Never {
        while true {
            autoreleasepool {
                runSerialSessionIfAvailable()
            }
            usleep(500_000)
        }
    }

    private func runSerialSessionIfAvailable() {
        guard let path = serialDevicePath() else { return }
        lineBuffer = ""
        controlState = TingControlState()
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", pythonSerialReader, path]
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        serialProcess = process

        do {
            try process.run()
        } catch {
            log("Could not start serial reader: \(error)")
            serialProcess = nil
            return
        }

        log("Connected to Ting at \(path)")
        while true {
            let data = output.fileHandleForReading.availableData
            if data.isEmpty { break }
            lineBuffer += String(decoding: data, as: UTF8.self)
            processCompleteLines()
        }

        process.waitUntilExit()
        serialProcess = nil
        controller.releaseAnythingHeld()
        lineBuffer = ""
        log("Ting disconnected; waiting for it to return")
    }

    private func processCompleteLines() {
        while let newline = lineBuffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(lineBuffer[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
            lineBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            process(line: line)
        }
    }

    private func process(line: String) {
        guard let event = TingSerialProtocol.event(from: line) else {
            if line.contains("Traceback") || line.contains("Error") {
                log("Ting REPL: \(line)")
            }
            return
        }
        switch event {
        case .ready:
            log("Ting controls ready")
        case let .error(message):
            log("Ting serial error: \(message)")
        case .handle, .green:
            switch controlState.transition(for: event) {
            case let .handleChanged(isPressed):
                controller.handleChanged(isPressed: isPressed)
            case .greenReleased:
                controller.greenReleased()
            case nil:
                break
            }
        }
    }

    private func serialDevicePath() -> String? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/dev") else {
            return nil
        }
        return TingSerialProtocol.devicePath(from: names)
    }

    private var pythonSerialReader: String {
        #"""
        import fcntl, os, re, select, sys, termios, time

        path = sys.argv[1]
        parent_pid = os.getppid()
        fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        attrs = termios.tcgetattr(fd)
        attrs[0] = 0
        attrs[1] = 0
        attrs[2] = (attrs[2] & ~(termios.PARENB | termios.CSTOPB | termios.CSIZE)) | termios.CS8 | termios.CREAD | termios.CLOCAL
        attrs[3] = 0
        attrs[4] = termios.B115200
        attrs[5] = termios.B115200
        attrs[6][termios.VMIN] = 0
        attrs[6][termios.VTIME] = 1
        termios.tcsetattr(fd, termios.TCSANOW, attrs)
        fcntl.fcntl(fd, fcntl.F_SETFL, fcntl.fcntl(fd, fcntl.F_GETFL) & ~os.O_NONBLOCK)

        def write_all(data):
            view = memoryview(data)
            while view:
                view = view[os.write(fd, view):]

        write_all(b'\x03\x03\r')
        time.sleep(0.25)
        termios.tcflush(fd, termios.TCIFLUSH)
        code = '''import time,ui
        lh=ui.sw(4)
        lg=ui.sw(1)
        print("TING_READY",1)
        while True:
         h=ui.sw(4)
         g=ui.sw(1)
         if h!=lh:
          print("TING_HANDLE",h)
          lh=h
         if g!=lg:
          print("TING_GREEN",g)
          lg=g
         time.sleep_ms(15)'''
        write_all(('exec(' + repr(code) + ')\r').encode())

        try:
            serial_buffer = b''
            ready = False
            ready_deadline = time.monotonic() + 5.0
            while True:
                if os.getppid() != parent_pid:
                    break
                if not ready and time.monotonic() >= ready_deadline:
                    print('TING_ERROR no_ready', flush=True)
                    sys.exit(1)
                readable, _, _ = select.select([fd], [], [], 0.2)
                if not readable:
                    continue
                data = os.read(fd, 4096)
                if not data:
                    break
                serial_buffer += data
                while b'\n' in serial_buffer or b'\r' in serial_buffer:
                    newline = min(
                        (index for index in (serial_buffer.find(b'\n'), serial_buffer.find(b'\r')) if index >= 0),
                        default=-1,
                    )
                    if newline < 0:
                        break
                    line, serial_buffer = serial_buffer[:newline], serial_buffer[newline + 1:]
                    match = re.search(rb'(TING_(?:READY|HANDLE|GREEN) [01])', line)
                    if match:
                        normalized = match.group(1)
                        if normalized == b'TING_READY 1':
                            ready = True
                        sys.stdout.buffer.write(normalized + b'\n')
                        sys.stdout.buffer.flush()
        finally:
            os.close(fd)
        """#
    }
}

func runAXDump() {
    func diagnostic(_ message: String) {
        print("AXDUMP \(message)")
        fflush(stdout)
    }

    let trusted = AXIsProcessTrusted()
    diagnostic("starting; process trusted=\(trusted)")
    guard trusted else {
        diagnostic("aborted: this process is not trusted for Accessibility")
        return
    }
    guard let claude = NSRunningApplication
        .runningApplications(withBundleIdentifier: SupportedApp.claude.rawValue)
        .first else {
        diagnostic("aborted: Claude is not running")
        return
    }
    let pid = claude.processIdentifier
    let app = AXUIElementCreateApplication(pid)

    func str(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
    func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }
    func frame(_ element: AXUIElement) -> String {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID(),
              AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return "frame=?"
        }
        return "frame=(\(Int(position.x)),\(Int(position.y)) \(Int(size.width))x\(Int(size.height)))"
    }
    func describe(_ element: AXUIElement) -> String {
        let role = str(element, kAXRoleAttribute as String) ?? "?"
        var parts = [role]
        let named: [(String, String)] = [
            ("desc", kAXDescriptionAttribute as String),
            ("title", kAXTitleAttribute as String),
            ("id", kAXIdentifierAttribute as String),
            ("placeholder", "AXPlaceholderValue"),
            ("help", kAXHelpAttribute as String),
        ]
        for (name, attribute) in named {
            if let value = str(element, attribute), !value.isEmpty {
                parts.append("\(name)='\(value.prefix(80))'")
            }
        }
        var rawValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &rawValue) == .success,
           let text = rawValue as? String, !text.isEmpty {
            parts.append("value=redacted")
        }
        parts.append(frame(element))
        return parts.joined(separator: " ")
    }

    var focusedValue: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
       let focusedValue,
       CFGetTypeID(focusedValue) == AXUIElementGetTypeID() {
        diagnostic("focused-element: \(describe(focusedValue as! AXUIElement))")
    } else {
        diagnostic("focused-element: none reported")
    }

    var lineCount = 0
    func walk(_ element: AXUIElement, depth: Int) {
        guard depth < 45, lineCount < 1200 else { return }
        let role = str(element, kAXRoleAttribute as String) ?? "?"
        let description = describe(element)
        let alwaysShow = ["AXButton", "AXTextArea", "AXTextField", "AXWindow", "AXWebArea", "AXPopUpButton", "AXCheckBox"]
            .contains(role)
        let hasLabel = description.contains("desc='") || description.contains("title='")
            || description.contains("id='") || description.contains("placeholder='")
        if alwaysShow || hasLabel {
            diagnostic("\(String(repeating: ".", count: min(depth, 30))) \(description)")
            lineCount += 1
        }
        for child in children(element) {
            walk(child, depth: depth + 1)
        }
    }

    var windowsValue: CFTypeRef?
    var windows: [AXUIElement] = []
    if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue) == .success {
        windows = windowsValue as? [AXUIElement] ?? []
    }
    var focusedWindowValue: CFTypeRef?
    let focusedWindow: AXUIElement? = {
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedWindowValue) == .success,
              let focusedWindowValue,
              CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return (focusedWindowValue as! AXUIElement)
    }()
    diagnostic("Claude pid=\(pid) windows=\(windows.count)")
    for (index, window) in windows.enumerated() {
        let isFocused = focusedWindow.map { CFEqual($0, window) } ?? false
        diagnostic("window[\(index)] focused=\(isFocused) \(describe(window))")
        walk(window, depth: 0)
    }
    diagnostic("complete; \(lineCount) elements printed")
}

func log(_ message: String) {
    let formatter = ISO8601DateFormatter()
    let line = "[\(formatter.string(from: Date()))] \(message)\n"
    print(line, terminator: "")
    fflush(stdout)

    let path = NSHomeDirectory() + "/Library/Logs/TingBridge.log"
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    guard let handle = FileHandle(forWritingAtPath: path) else { return }
    defer { try? handle.close() }
    do {
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
    } catch {
        // Terminal logging remains available if file logging fails.
    }
}

func runSelfTest() {
    var controlState = TingControlState()
    let checks: [(String, Bool)] = [
        (
            "rejects unrelated serial devices",
            TingSerialProtocol.devicePath(from: ["cu.usbmodemArduino", "cu.usbmodem3DPrinter"]) == nil
        ),
        (
            "selects the known Ting serial device",
            TingSerialProtocol.devicePath(from: ["cu.usbmodemArduino", "cu.usbmodemEPTXZ9"])
                == "/dev/cu.usbmodemEPTXZ9"
        ),
        ("parses known handle events", TingSerialProtocol.event(from: "TING_HANDLE 1") == .handle(true)),
        ("rejects malformed control events", TingSerialProtocol.event(from: "TING_HANDLE 2") == nil),
        ("emits initial handle transition", controlState.transition(for: .handle(true)) == .handleChanged(isPressed: true)),
        ("suppresses duplicate handle transition", controlState.transition(for: .handle(true)) == nil),
        ("ignores green press", controlState.transition(for: .green(true)) == nil),
        ("emits green release", controlState.transition(for: .green(false)) == .greenReleased),
        ("suppresses duplicate green release", controlState.transition(for: .green(false)) == nil),
    ]

    for (name, passed) in checks {
        guard passed else {
            fputs("SELF_TEST_FAILED: \(name)\n", stderr)
            Foundation.exit(1)
        }
    }
    print("SELF_TEST_OK")
}

func runBridge() -> Never {
    let supportDirectory = NSHomeDirectory() + "/Library/Application Support/TingBridge"
    try? FileManager.default.createDirectory(
        atPath: supportDirectory,
        withIntermediateDirectories: true
    )
    let lockFile = open(supportDirectory + "/bridge.lock", O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard lockFile >= 0, flock(lockFile, LOCK_EX | LOCK_NB) == 0 else {
        log("Another Ting Bridge instance is already running; exiting")
        Foundation.exit(0)
    }

    var trusted = AXIsProcessTrustedWithOptions([
        "AXTrustedCheckOptionPrompt": true,
    ] as CFDictionary)
    if !trusted {
        log("Accessibility permission is required. Toggle Ting Bridge off and on in System Settings > Privacy & Security > Accessibility. Waiting up to 5 minutes...")
        let deadline = Date().addingTimeInterval(300)
        while !trusted && Date() < deadline {
            sleep(2)
            trusted = AXIsProcessTrusted()
        }
    }
    if !trusted {
        log("Accessibility permission was not granted in time; exiting.")
        Foundation.exit(3)
    }

    log("Ting Bridge starting; allowed apps: Codex, Claude and iTerm2")
    let controller = InputController()
    let bridge = TingSerialBridge(controller: controller)

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let signalSources = [SIGINT, SIGTERM].map { signalNumber -> DispatchSourceSignal in
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
        source.setEventHandler {
            log("Received signal \(signalNumber); releasing held input and exiting")
            bridge.shutdown()
        }
        source.resume()
        return source
    }
    _ = signalSources

    bridge.runForever()
}

@main
struct TingBridgeCommand {
    static func main() async {
        let arguments = CommandLine.arguments.dropFirst()
        switch arguments.first {
        case "audio-probe":
            let seconds = arguments.dropFirst().first.flatMap(Double.init) ?? 8
            do {
                try await probeAudio(seconds: seconds)
            } catch {
                fputs("Audio probe failed: \(error)\n", stderr)
                Foundation.exit(1)
            }
        case "run":
            runBridge()
        case "ax-dump":
            runAXDump()
        case "self-test":
            runSelfTest()
        default:
            print("Usage: ting-bridge audio-probe [seconds] | run | ax-dump | self-test")
            Foundation.exit(2)
        }
    }
}
