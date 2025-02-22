import Foundation
import AppKit

class ActiveWindowService: ObservableObject {
    static let shared = ActiveWindowService()
    @Published var currentApplication: NSRunningApplication?
    private var enhancementService: AIEnhancementService?
    private let browserURLService = BrowserURLService.shared
    
    private init() {}
    
    func configure(with enhancementService: AIEnhancementService) {
        self.enhancementService = enhancementService
    }
    
    func applyConfigurationForCurrentApp() async {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = frontmostApp.bundleIdentifier else { return }
        
        print("🎯 Active Application: \(frontmostApp.localizedName ?? "Unknown") (\(bundleIdentifier))")
        await MainActor.run {
            currentApplication = frontmostApp
        }
        
        // Check if the current app is a supported browser
        if let browserType = BrowserType.allCases.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            print("🌐 Detected Browser: \(browserType.displayName)")
            
            do {
                // Try to get the current URL
                let currentURL = try await browserURLService.getCurrentURL(from: browserType)
                print("📍 Current URL: \(currentURL)")
                
                // Check for URL-specific configuration
                if let (config, urlConfig) = PowerModeManager.shared.getConfigurationForURL(currentURL) {
                    print("⚙️ Found URL Configuration: \(config.appName) - URL: \(urlConfig.url)")
                    // Apply URL-specific configuration
                    var updatedConfig = config
                    updatedConfig.selectedPrompt = urlConfig.promptId
                    await applyConfiguration(updatedConfig)
                    return
                } else {
                    print("📝 No URL configuration found for: \(currentURL)")
                }
            } catch {
                print("❌ Failed to get URL from \(browserType.displayName): \(error)")
            }
        }
        
        // Get configuration for the current app or use default if none exists
        let config = PowerModeManager.shared.getConfiguration(for: bundleIdentifier) ?? PowerModeManager.shared.defaultConfig
        print("⚡️ Using Configuration: \(config.appName) (AI Enhancement: \(config.isAIEnhancementEnabled ? "Enabled" : "Disabled"))")
        await applyConfiguration(config)
    }
    
    private func applyConfiguration(_ config: PowerModeConfig) async {
        guard let enhancementService = enhancementService else { return }
        
        await MainActor.run {
            // Apply AI enhancement settings
            enhancementService.isEnhancementEnabled = config.isAIEnhancementEnabled
            
            // Handle prompt selection
            if config.isAIEnhancementEnabled {
                if let promptId = config.selectedPrompt,
                   let uuid = UUID(uuidString: promptId) {
                    print("🎯 Applied Prompt: \(enhancementService.allPrompts.first(where: { $0.id == uuid })?.title ?? "Unknown")")
                    enhancementService.selectedPromptId = uuid
                } else {
                    // Auto-select first prompt if none is selected and AI is enabled
                    if let firstPrompt = enhancementService.allPrompts.first {
                        print("🎯 Auto-selected Prompt: \(firstPrompt.title)")
                        enhancementService.selectedPromptId = firstPrompt.id
                    }
                }
            }
        }
    }
} 
