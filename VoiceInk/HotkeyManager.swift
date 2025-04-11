import Foundation
import KeyboardShortcuts
import Carbon
import AppKit

extension KeyboardShortcuts.Name {
    static let toggleMiniRecorder = Self("toggleMiniRecorder")
    static let escapeRecorder = Self("escapeRecorder")
    static let toggleEnhancement = Self("toggleEnhancement")
    // Prompt selection shortcuts
    static let selectPrompt1 = Self("selectPrompt1")
    static let selectPrompt2 = Self("selectPrompt2")
    static let selectPrompt3 = Self("selectPrompt3")
    static let selectPrompt4 = Self("selectPrompt4")
    static let selectPrompt5 = Self("selectPrompt5")
    static let selectPrompt6 = Self("selectPrompt6")
    static let selectPrompt7 = Self("selectPrompt7")
    static let selectPrompt8 = Self("selectPrompt8")
    static let selectPrompt9 = Self("selectPrompt9")
}

@MainActor
class HotkeyManager: ObservableObject {
    @Published var isListening = false
    @Published var isShortcutConfigured = false
    @Published var isPushToTalkEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isPushToTalkEnabled, forKey: "isPushToTalkEnabled")
            resetKeyStates()
            setupKeyMonitor()
        }
    }
    @Published var pushToTalkKey: PushToTalkKey {
        didSet {
            UserDefaults.standard.set(pushToTalkKey.rawValue, forKey: "pushToTalkKey")
            resetKeyStates()
        }
    }
    
    private var whisperState: WhisperState
    private var currentKeyState = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var visibilityTask: Task<Void, Never>?
    
    // Key handling properties
    private var keyPressStartTime: Date?
    private let briefPressThreshold = 1.0 // 1 second threshold for brief press
    private var isHandsFreeMode = false   // Track if we're in hands-free recording mode

    // Add cooldown management
    private var lastShortcutTriggerTime: Date?
    private let shortcutCooldownInterval: TimeInterval = 0.5 // 500ms cooldown
    
    enum PushToTalkKey: String, CaseIterable {
        case rightOption = "rightOption"
        case leftOption = "leftOption"
        case leftControl = "leftControl"
        case fn = "fn"
        case rightCommand = "rightCommand"
        case rightShift = "rightShift"
        
        var displayName: String {
            switch self {
            case .rightOption: return "Right Option (⌥)"
            case .leftOption: return "Left Option (⌥)"
            case .leftControl: return "Left Control (⌃)"
            case .fn: return "Fn"
            case .rightCommand: return "Right Command (⌘)"
            case .rightShift: return "Right Shift (⇧)"
            }
        }
        
        var keyCode: CGKeyCode {
            switch self {
            case .rightOption: return 0x3D
            case .leftOption: return 0x3A
            case .leftControl: return 0x3B
            case .fn: return 0x3F
            case .rightCommand: return 0x36
            case .rightShift: return 0x3C
            }
        }
        
        var flags: CGEventFlags {
            switch self {
            case .rightOption: return .maskAlternate
            case .leftOption: return .maskAlternate
            case .leftControl: return .maskControl
            case .fn: return .maskSecondaryFn
            case .rightCommand: return .maskCommand
            case .rightShift: return .maskShift
            }
        }
    }
    
    init(whisperState: WhisperState) {
        self.isPushToTalkEnabled = UserDefaults.standard.bool(forKey: "isPushToTalkEnabled")
        self.pushToTalkKey = PushToTalkKey(rawValue: UserDefaults.standard.string(forKey: "pushToTalkKey") ?? "") ?? .rightCommand
        self.whisperState = whisperState
        
        updateShortcutStatus()
        setupEnhancementShortcut()
        setupVisibilityObserver()
    }
    
    private func resetKeyStates() {
        currentKeyState = false
        keyPressStartTime = nil
        isHandsFreeMode = false
    }
    
    private func setupVisibilityObserver() {
        visibilityTask = Task { @MainActor in
            for await isVisible in whisperState.$isMiniRecorderVisible.values {
                if isVisible {
                    setupEscapeShortcut()
                    KeyboardShortcuts.setShortcut(.init(.e, modifiers: .command), for: .toggleEnhancement)
                    setupPromptShortcuts()
                } else {
                    removeEscapeShortcut()
                    removeEnhancementShortcut()
                    removePromptShortcuts()
                }
            }
        }
    }
    
    private func setupKeyMonitor() {
        removeKeyMonitor()
        
        guard isPushToTalkEnabled else { return }
        guard AXIsProcessTrusted() else { return }
        
        let eventMask = (1 << CGEventType.flagsChanged.rawValue)
        
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon in
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon!).takeUnretainedValue()
                
                if type == .flagsChanged {
                    Task { @MainActor in
                        await manager.handleKeyEvent(event)
                    }
                }
                
                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        
        self.eventTap = tap
        self.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        
        if let runLoopSource = self.runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
    
    private func removeKeyMonitor() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let runLoopSource = self.runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            }
            self.eventTap = nil
            self.runLoopSource = nil
        }
    }
    
    private func handleKeyEvent(_ event: CGEvent) async {
        guard isPushToTalkEnabled else { return }

        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let targetKeys = pushToTalkKeys

        // Find which PTT key this event corresponds to (if any)
        guard let eventKeyInfo = targetKeys.first(where: { $0.keyCode == keyCode }) else {
            // This event might be for a modifier key not explicitly listed but part of a combo,
            // or an unrelated key. We only care if it's one of *our* PTT keys changing state.
            return
        }

        // Determine if the key went down or up based on its specific flag
        let isKeyDown = flags.contains(eventKeyInfo.flags)
        let previousKeyState = activePttKeyCode == keyCode // Was this key the one we were tracking?

        // --- Key Down Logic ---
        if isKeyDown {
            // If this key is already down (repeat event) or another PTT key is active, ignore.
            guard activePttKeyCode == nil else {
                 print("🖱️ KeyDown ignored: Another PTT key [\(activePttKeyCode ?? 999)] is active.")
                 return
            }

            // --- Start New PTT Action ---
            activePttKeyCode = keyCode
            keyPressStartTime = Date()
            didStartRecordingOnPress = false // Reset flag for this new press

            // Invalidate any pending double-click timer
            doubleClickTimer?.invalidate()
            doubleClickTimer = nil

            // If not already recording (from hands-free or a previous incomplete action)
            if !whisperState.isRecording {
                // Check for double-click: was the *same key* released recently?
                if let lastRelease = lastReleaseTime,
                   lastReleasedPttKeyCode == keyCode, // Must be the same key
                   Date().timeIntervalSince(lastRelease) < doubleClickInterval {
                    // --- Double Click Detected ---
                    isHandsFreeMode = true
                    lastReleaseTime = nil // Consume the release time
                    lastReleasedPttKeyCode = nil
                    print("🖱️ Double Click Detected (\(eventKeyInfo.displayName)) - Entering Hands-Free")
                    await whisperState.toggleRecord() // Start recording
                    didStartRecordingOnPress = true
                } else {
                    // --- Start Hold Recording ---
                    print("🖱️ PTT Hold Started (\(eventKeyInfo.displayName))")
                    await whisperState.toggleRecord() // Start recording for hold
                    didStartRecordingOnPress = true
                }
            } else if isHandsFreeMode {
                // --- Click while in Hands-Free Mode ---
                // This press intends to stop hands-free on release.
                print("🖱️ Click while Hands-Free (\(eventKeyInfo.displayName)) (will stop on release)")
                // State is set (activePttKeyCode, keyPressStartTime), action happens on Key Up.
            }
            // Else: Recording is already active (likely hold from another key), ignore this new press.

        }
        // --- Key Up Logic ---
        else {
            // Key released. Only process if this is the key we were tracking.
            guard activePttKeyCode == keyCode else {
                 print("🖱️ KeyUp ignored: Key [\(keyCode)] was not the active PTT key [\(activePttKeyCode ?? 999)].")
                 return // This release doesn't correspond to the key that initiated the action
            }

            let releaseTime = Date()
            lastReleaseTime = releaseTime
            lastReleasedPttKeyCode = keyCode // Record which key was just released

            if let startTime = keyPressStartTime {
                let pressDuration = releaseTime.timeIntervalSince(startTime)

                if isHandsFreeMode {
                    // --- Stop Hands-Free Recording ---
                    // This release corresponds to the click *after* entering hands-free mode.
                    print("🖱️ Stopping Hands-Free Recording (\(eventKeyInfo.displayName))")
                    if whisperState.isRecording {
                        await whisperState.toggleRecord() // Stop recording
                    }
                    isHandsFreeMode = false // Exit hands-free mode
                } else if didStartRecordingOnPress {
                    // This key release corresponds to a press that *started* a recording (hold or brief click)
                    if pressDuration < briefPressThreshold {
                        // --- Brief Click Action ---
                        print("🖱️ Brief Click Detected (\(eventKeyInfo.displayName)) - Canceling")
                        await whisperState.cancelRecording() // Cancel recording and dismiss UI

                        // Start double-click timer for *this specific key*
                        doubleClickTimer = Timer.scheduledTimer(withTimeInterval: doubleClickInterval, repeats: false) { _ in
                             Task { @MainActor in
                                 // If the timer fires, it means no second click happened for this key
                                 if self.lastReleasedPttKeyCode == keyCode {
                                     self.lastReleasedPttKeyCode = nil // Reset so next click isn't a double-click
                                 }
                                 self.doubleClickTimer = nil
                                 print("🖱️ Double-click window expired for key \(keyCode)")
                             }
                        }
                    } else {
                        // --- Hold Release Action ---
                        print("🖱️ PTT Hold Released (\(eventKeyInfo.displayName)) - Stopping")
                        if whisperState.isRecording {
                            await whisperState.toggleRecord() // Stop recording and process
                        }
                    }
                }
                // Else: didStartRecordingOnPress was false, meaning this key up doesn't correspond
                // to a press that should trigger a stop/cancel (e.g., key released after app lost focus).
                // Simply reset state.
            }

            // Reset state for the next press sequence *for any key*
            activePttKeyCode = nil
            keyPressStartTime = nil
            didStartRecordingOnPress = false
        }
    }
    
    private func setupEscapeShortcut() {
        KeyboardShortcuts.setShortcut(.init(.escape), for: .escapeRecorder)
        KeyboardShortcuts.onKeyDown(for: .escapeRecorder) { [weak self] in
            Task { @MainActor in
                guard let self = self,
                      await self.whisperState.isMiniRecorderVisible else { return }
                
                SoundManager.shared.playEscSound()
                await self.whisperState.dismissMiniRecorder()
            }
        }
    }
    
    private func removeEscapeShortcut() {
        KeyboardShortcuts.setShortcut(nil, for: .escapeRecorder)
    }
    
    private func setupEnhancementShortcut() {
        KeyboardShortcuts.onKeyDown(for: .toggleEnhancement) { [weak self] in
            Task { @MainActor in
                guard let self = self,
                      await self.whisperState.isMiniRecorderVisible,
                      let enhancementService = await self.whisperState.getEnhancementService() else { return }
                enhancementService.isEnhancementEnabled.toggle()
            }
        }
    }
    
    private func setupPromptShortcuts() {
        // Set up Command+1 through Command+9 shortcuts with proper key definitions
        KeyboardShortcuts.setShortcut(.init(.one, modifiers: .command), for: .selectPrompt1)
        KeyboardShortcuts.setShortcut(.init(.two, modifiers: .command), for: .selectPrompt2)
        KeyboardShortcuts.setShortcut(.init(.three, modifiers: .command), for: .selectPrompt3)
        KeyboardShortcuts.setShortcut(.init(.four, modifiers: .command), for: .selectPrompt4)
        KeyboardShortcuts.setShortcut(.init(.five, modifiers: .command), for: .selectPrompt5)
        KeyboardShortcuts.setShortcut(.init(.six, modifiers: .command), for: .selectPrompt6)
        KeyboardShortcuts.setShortcut(.init(.seven, modifiers: .command), for: .selectPrompt7)
        KeyboardShortcuts.setShortcut(.init(.eight, modifiers: .command), for: .selectPrompt8)
        KeyboardShortcuts.setShortcut(.init(.nine, modifiers: .command), for: .selectPrompt9)
        
        // Setup handlers for each shortcut
        setupPromptHandler(for: .selectPrompt1, index: 0)
        setupPromptHandler(for: .selectPrompt2, index: 1)
        setupPromptHandler(for: .selectPrompt3, index: 2)
        setupPromptHandler(for: .selectPrompt4, index: 3)
        setupPromptHandler(for: .selectPrompt5, index: 4)
        setupPromptHandler(for: .selectPrompt6, index: 5)
        setupPromptHandler(for: .selectPrompt7, index: 6)
        setupPromptHandler(for: .selectPrompt8, index: 7)
        setupPromptHandler(for: .selectPrompt9, index: 8)
    }
    
    private func setupPromptHandler(for shortcutName: KeyboardShortcuts.Name, index: Int) {
        KeyboardShortcuts.onKeyDown(for: shortcutName) { [weak self] in
            Task { @MainActor in
                guard let self = self,
                      await self.whisperState.isMiniRecorderVisible,
                      let enhancementService = await self.whisperState.getEnhancementService() else { return }
                
                let prompts = enhancementService.allPrompts
                if index < prompts.count {
                    // Enable AI enhancement if it's not already enabled
                    if !enhancementService.isEnhancementEnabled {
                        enhancementService.isEnhancementEnabled = true
                    }
                    // Switch to the selected prompt
                    enhancementService.setActivePrompt(prompts[index])
                }
            }
        }
    }
    
    private func removePromptShortcuts() {
        // Remove Command+1 through Command+9 shortcuts
        KeyboardShortcuts.setShortcut(nil, for: .selectPrompt1)
        KeyboardShortcuts.setShortcut(nil, for: .selectPrompt2)
        KeyboardShortcuts.setShortcut(nil, for: .selectPrompt3)
        KeyboardShortcuts.setShortcut(nil, for: .selectPrompt4)
        KeyboardShortcuts.setShortcut(nil, for: .selectPrompt5)
        KeyboardShortcuts.setShortcut(nil, for: .selectPrompt6)
        KeyboardShortcuts.setShortcut(nil, for: .selectPrompt7)
        KeyboardShortcuts.setShortcut(nil, for: .selectPrompt8)
        KeyboardShortcuts.setShortcut(nil, for: .selectPrompt9)
    }
    
    private func removeEnhancementShortcut() {
        KeyboardShortcuts.setShortcut(nil, for: .toggleEnhancement)
    }
    
    func updateShortcutStatus() {
        // Update status for the standard shortcut
        isShortcutConfigured = KeyboardShortcuts.getShortcut(for: .toggleMiniRecorder) != nil
        if isShortcutConfigured {
            setupShortcutHandler() // Setup handler for the standard shortcut if it exists
        }
        
        // Setup or remove PTT monitor based *only* on the PTT enabled flag and permissions
        if isPushToTalkEnabled && AXIsProcessTrusted() {
             setupKeyMonitor()
        } else {
             removeKeyMonitor()
        }
    }
    
    
    // Keep the original shortcut handler separate
    private func setupShortcutHandler() {
         KeyboardShortcuts.onKeyUp(for: .toggleMiniRecorder) { [weak self] in
             Task { @MainActor in
                 // Prevent standard shortcut if PTT is active and recorder is visible
                 guard let self = self else { return }
                 if self.isPushToTalkEnabled && self.whisperState.isMiniRecorderVisible {
                     print("⌨️ Standard shortcut ignored while PTT active and recorder visible.")
                     return
                 }
                 await self.handleShortcutTriggered()
             }
         }
    }
    
    private func handleShortcutTriggered() async {
        // Check cooldown
        if let lastTrigger = lastShortcutTriggerTime,
           Date().timeIntervalSince(lastTrigger) < shortcutCooldownInterval {
            return // Still in cooldown period
        }
        
        // Update last trigger time
        lastShortcutTriggerTime = Date()
        
        // Handle the standard shortcut (not PTT)
        // This should likely toggle the recorder visibility *without* starting/stopping recording
        // if PTT is the primary mechanism. Or maybe it should still toggle recording?
        // Let's keep the original toggle behavior for the standard shortcut for now.
        await whisperState.toggleMiniRecorder() // Use the UI toggle method directly
    }

    
    deinit {
        visibilityTask?.cancel()
        Task { @MainActor in
            removeKeyMonitor()
            removeEscapeShortcut()
            removeEnhancementShortcut()
        }
    }
}
