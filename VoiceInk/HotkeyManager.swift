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
            if !isPushToTalkEnabled {
                isRightOptionKeyPressed = false
                isFnKeyPressed = false
                isRightCommandKeyPressed = false
                isRightShiftKeyPressed = false
                keyPressStartTime = nil
            }
            setupKeyMonitors()
        }
    }
    @Published var pushToTalkKeys: Set<PushToTalkKey> {
        didSet {
            // Save the set of raw values
            let rawValues = pushToTalkKeys.map { $0.rawValue }
            UserDefaults.standard.set(rawValues, forKey: "pushToTalkKeys")
            // Reset state when keys change
            pressedKeys.keys.forEach { pressedKeys[$0] = false }
            keyPressStartTime = nil
            isWaitingForDoubleClick = false
            isToggleRecordingActive = false
            lastKeyPressTime = nil
        }
    }
    
    private var whisperState: WhisperState
    // Dictionary to track the state of individual keys
    private var pressedKeys: [PushToTalkKey: Bool] = [
        .rightOption: false,
        .fn: false,
        .rightCommand: false,
        .rightShift: false
    ]
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var visibilityTask: Task<Void, Never>?
    private var keyPressStartTime: Date? // Tracks when the PTT combination was first pressed
    private let shortPressDuration: TimeInterval = 0.3 // Threshold for short press (dismiss) vs long press (hold)
    private var lastKeyPressTime: Date? // Tracks the time of the last key press for double-click detection
    private let doubleClickInterval: TimeInterval = 0.4 // Max time between presses for a double-click
    private var isWaitingForDoubleClick = false // Flag to indicate if we're potentially in a double-click sequence
    private var isToggleRecordingActive = false // Flag for double-click toggle recording mode
    
    // Add cooldown management
    private var lastShortcutTriggerTime: Date?
    private let shortcutCooldownInterval: TimeInterval = 0.5 // 500ms cooldown
    
    enum PushToTalkKey: String, CaseIterable {
        case rightOption = "rightOption"
        case fn = "fn"
        case rightCommand = "rightCommand"
        case rightShift = "rightShift"
        
        var displayName: String {
            switch self {
            case .rightOption: return "Right Option (⌥)"
            case .fn: return "Fn"
            case .rightCommand: return "Right Command (⌘)"
            case .rightShift: return "Right Shift (⇧)"
            }
        }
    }
    
    init(whisperState: WhisperState) {
        // Load push-to-talk enabled state
        self.isPushToTalkEnabled = UserDefaults.standard.bool(forKey: "isPushToTalkEnabled")
        // Load push-to-talk keys (Set of Strings)
        if let savedKeys = UserDefaults.standard.array(forKey: "pushToTalkKeys") as? [String] {
            self.pushToTalkKeys = Set(savedKeys.compactMap { PushToTalkKey(rawValue: $0) })
        } else {
            // Default to Right Command if nothing is saved
            self.pushToTalkKeys = [.rightCommand]
        }
        // Ensure default is set if the loaded set is empty (e.g., first launch or corrupted data)
        if self.pushToTalkKeys.isEmpty {
             self.pushToTalkKeys = [.rightCommand]
             UserDefaults.standard.set([PushToTalkKey.rightCommand.rawValue], forKey: "pushToTalkKeys")
        }
        self.whisperState = whisperState
        
        updateShortcutStatus()
        setupEnhancementShortcut()
        
        // Start observing mini recorder visibility
        setupVisibilityObserver()
    }
    
    private func setupVisibilityObserver() {
        visibilityTask = Task { @MainActor in
            for await isVisible in whisperState.$isMiniRecorderVisible.values {
                if isVisible {
                    setupEscapeShortcut()
                    // Set Command+E shortcut when visible
                    KeyboardShortcuts.setShortcut(.init(.e, modifiers: .command), for: .toggleEnhancement)
                    setupPromptShortcuts()
                } else {
                    removeEscapeShortcut()
                    // Remove Command+E shortcut when not visible
                    KeyboardShortcuts.setShortcut(nil, for: .toggleEnhancement)
                    removePromptShortcuts()
                }
            }
        }
    }
    
    private func setupEscapeShortcut() {
        // Set ESC as the shortcut using KeyboardShortcuts native approach
        KeyboardShortcuts.setShortcut(.init(.escape), for: .escapeRecorder)
        
        // Setup handler
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
        // Only setup the handler, don't set the shortcut here
        // The shortcut will be set/removed based on visibility
        KeyboardShortcuts.onKeyDown(for: .toggleEnhancement) { [weak self] in
            Task { @MainActor in
                guard let self = self,
                      await self.whisperState.isMiniRecorderVisible,
                      let enhancementService = await self.whisperState.getEnhancementService() else { return }
                enhancementService.isEnhancementEnabled.toggle()
            }
        }
    }
    
    private func removeEnhancementShortcut() {
        KeyboardShortcuts.setShortcut(nil, for: .toggleEnhancement)
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
    
    func updateShortcutStatus() {
        isShortcutConfigured = KeyboardShortcuts.getShortcut(for: .toggleMiniRecorder) != nil
        
        if isShortcutConfigured {
            setupShortcutHandler()
            setupKeyMonitors()
        } else {
            removeKeyMonitors()
        }
    }
    
    private func setupShortcutHandler() {
        KeyboardShortcuts.onKeyUp(for: .toggleMiniRecorder) { [weak self] in
            Task { @MainActor in
                await self?.handleShortcutTriggered()
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
        
        // Handle the shortcut
        await whisperState.handleToggleMiniRecorder()
    }
    
    private func removeKeyMonitors() {
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        if let monitor = globalKeyMonitor {
            NSEvent.removeMonitor(monitor)
            globalKeyMonitor = nil
        }
    }
    
    private func setupKeyMonitors() {
        guard isPushToTalkEnabled else {
            removeKeyMonitors()
            return
        }
        
        // Remove existing monitors first
        removeKeyMonitors()
        
        // Local monitor for when app is in foreground
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                await self?.handlePushToTalkKey(event)
            }
            return event
        }
        
        // Global monitor for when app is in background
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                await self?.handlePushToTalkKey(event)
            }
        }
    }
    
     private func handlePushToTalkKey(_ event: NSEvent) async {
         // Only handle push-to-talk if enabled
         guard isPushToTalkEnabled else { return }
         
         // Update the state of the key that triggered the event
         var keyChanged: PushToTalkKey? = nil
         if event.modifierFlags.contains(.option) && event.keyCode == 0x3D {
             pressedKeys[.rightOption] = event.modifierFlags.contains(.option)
             if pressedKeys[.rightOption] != (event.modifierFlags.contains(.option)) { keyChanged = .rightOption }
             pressedKeys[.rightOption] = event.modifierFlags.contains(.option)
         } else if event.modifierFlags.contains(.function) {
             // Note: Detecting Fn key release might be unreliable with flagsChanged.
             // Consider alternative monitoring if Fn key release detection is critical.
             let fnPressed = event.modifierFlags.contains(.function)
             if pressedKeys[.fn] != fnPressed { keyChanged = .fn }
             pressedKeys[.fn] = fnPressed
         } else if event.modifierFlags.contains(.command) && event.keyCode == 0x36 {
             if pressedKeys[.rightCommand] != (event.modifierFlags.contains(.command)) { keyChanged = .rightCommand }
             pressedKeys[.rightCommand] = event.modifierFlags.contains(.command)
         } else if event.modifierFlags.contains(.shift) && event.keyCode == 0x3C {
             if pressedKeys[.rightShift] != (event.modifierFlags.contains(.shift)) { keyChanged = .rightShift }
             pressedKeys[.rightShift] = event.modifierFlags.contains(.shift)
         } else {
             // If the event doesn't match any monitored key, reset potentially stuck states on key up
             if event.type == .flagsChanged {
                 // Check if any monitored modifier key was released
                 if !event.modifierFlags.contains(.option) { pressedKeys[.rightOption] = false }
                 if !event.modifierFlags.contains(.function) { pressedKeys[.fn] = false }
                 if !event.modifierFlags.contains(.command) { pressedKeys[.rightCommand] = false }
                 if !event.modifierFlags.contains(.shift) { pressedKeys[.rightShift] = false }
             }
         }

         // Check if all required push-to-talk keys are currently pressed
         let allKeysPressed = pushToTalkKeys.allSatisfy { pressedKeys[$0] == true }
         let anyKeyPressed = pushToTalkKeys.contains { pressedKeys[$0] == true } // Check if at least one PTT key is still pressed

         let now = Date()

         if allKeysPressed {
             // --- All required keys are pressed down ---
             if keyPressStartTime == nil { // First time all keys are pressed together
                 keyPressStartTime = now

                 // Double-click detection
                 if let lastPress = lastKeyPressTime, now.timeIntervalSince(lastPress) < doubleClickInterval {
                     // Double click detected!
                     isToggleRecordingActive.toggle() // Toggle the recording state
                     if isToggleRecordingActive {
                         // Start recording if not already recording
                         if !whisperState.isMiniRecorderVisible {
                             await whisperState.handleToggleMiniRecorder()
                         }
                     } else {
                         // Stop recording if currently in toggle mode
                         if whisperState.isMiniRecorderVisible {
                             await whisperState.handleToggleMiniRecorder()
                         }
                     }
                     isWaitingForDoubleClick = false // Reset double-click wait
                     lastKeyPressTime = nil // Prevent triple-click actions
                     keyPressStartTime = nil // Reset start time to avoid hold action
                 } else {
                     // Single press - start waiting for potential double click
                     isWaitingForDoubleClick = true
                     lastKeyPressTime = now
                     // Start recording immediately for hold functionality, unless toggle is active
                     if !isToggleRecordingActive && !whisperState.isMiniRecorderVisible {
                         await whisperState.handleToggleMiniRecorder()
                     }
                 }
             }
         } else if !anyKeyPressed {
             // --- All required keys have been released ---
             if let startTime = keyPressStartTime {
                 let pressDuration = now.timeIntervalSince(startTime)

                 if isToggleRecordingActive {
                     // In toggle mode, key release does nothing to the recording state
                 } else if pressDuration < shortPressDuration {
                     // Short press (Click) - Dismiss if visible
                     if whisperState.isMiniRecorderVisible {
                         await whisperState.dismissMiniRecorder()
                     }
                 } else {
                     // Long press (Hold) - Stop recording if it was started by hold
                     if whisperState.isMiniRecorderVisible && !isToggleRecordingActive {
                          await whisperState.handleToggleMiniRecorder()
                     }
                 }
             }
             // Reset state variables now that keys are released
             keyPressStartTime = nil
             isWaitingForDoubleClick = false // Reset double-click wait on release
             // Don't reset lastKeyPressTime here, needed for next press detection
             // Don't reset isToggleRecordingActive on release, only on next press or explicit stop
         }
         // Else: Some keys pressed, some released - intermediate state, do nothing until all are pressed or all are released.
     }
    
    deinit {
        visibilityTask?.cancel()
        Task { @MainActor in
            removeKeyMonitors()
            removeEscapeShortcut()
            removeEnhancementShortcut()
        }
    }
}
