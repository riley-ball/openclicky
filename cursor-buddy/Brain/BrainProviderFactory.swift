//
//  BrainProviderFactory.swift
//  cursor-buddy
//
//  Phase 1c of the clank-voice → openclicky integration: factory for
//  resolving a `BrainProviderID` (persisted in UserDefaults / read from the
//  Info.plist fallback) to a concrete `BrainProvider` instance. Shape
//  mirrors `BuddyTranscriptionProviderFactory` in the same project so the
//  fork's existing patterns stay consistent.
//
//  Usage (Task 4 wires this into CompanionManager):
//  ```
//  let provider = BrainProviderFactory.makeDefaultProvider(claudeAPI: claudeAPI)
//  ```
//  The factory does NOT own the underlying ClaudeAPI — the caller passes it
//  in so the existing Anthropic init flow (warm-up TLS, key rotation) stays
//  in CompanionManager's control.
//

import Foundation

enum BrainProviderFactory {
    /// UserDefaults key the Brain Provider Settings UI writes to.
    static let userPreferenceKey = "ClankBrainProvider"

    /// Info.plist fallback key — set by the launch env or the bundle's
    /// `Info.plist` to override the default at first launch.
    static let infoPlistFallbackKey = "BrainProvider"

    /// Resolve the user-preferred provider id. Falls back through:
    ///   1. UserDefaults["ClankBrainProvider"]
    ///   2. Info.plist["BrainProvider"]
    ///   3. .remoteClankSession (Phase 1c default)
    static func selectedProviderID() -> BrainProviderID {
        let userDefault = UserDefaults.standard.string(forKey: userPreferenceKey)
        let infoPlist = AppBundleConfiguration.stringValue(forKey: infoPlistFallbackKey)
        let raw = (userDefault ?? infoPlist ?? BrainProviderID.remoteClankSession.rawValue).lowercased()
        return BrainProviderID(rawValue: raw) ?? .remoteClankSession
    }

    /// Build a provider for the user's selected id. Mirrors the
    /// BuddyTranscriptionProviderFactory.makeDefaultProvider() shape.
    static func makeDefaultProvider(claudeAPI: ClaudeAPI) -> any BrainProvider {
        let id = selectedProviderID()
        let provider = makeProvider(id: id, claudeAPI: claudeAPI)
        print("🧠 Brain Provider: using \(provider.displayName)")
        return provider
    }

    /// Build the provider for an explicit id (used by the Settings UI when
    /// the user toggles providers at runtime).
    static func makeProvider(id: BrainProviderID, claudeAPI: ClaudeAPI) -> any BrainProvider {
        switch id {
        case .remoteClankSession:
            return RemoteClankSessionProvider()
        case .localAnthropic:
            return LocalAnthropicProvider(claudeAPI: claudeAPI)
        }
    }
}
