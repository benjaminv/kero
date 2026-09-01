//
//  AIProfileStore.swift
//  kero
//

import Combine
import Foundation

/// A shared CLI persona selected by a Kero window. The built-in system profile
/// deliberately adds no environment variables, preserving the user's existing
/// Codex and Claude login exactly. Named profiles isolate the CLIs' own mutable
/// state; Kero never reads or copies the credentials stored there.
struct AIProfile: Codable, Identifiable, Equatable {
    static let systemID = "system"

    let id: String
    var name: String

    var isSystem: Bool { id == Self.systemID }
    var displayName: String { isSystem ? String(localized: "System") : name }
}

@MainActor
final class AIProfileStore: nonisolated ObservableObject {
    static let shared = AIProfileStore()

    @Published private(set) var profiles: [AIProfile]

    private struct State: Codable {
        var profiles: [AIProfile]
    }

    private static let systemProfile = AIProfile(id: AIProfile.systemID, name: "System")
    private static let stateURL = AppSettings.configURL
        .deletingLastPathComponent()
        .appendingPathComponent("ai-profiles.json")
    private static let profilesURL = AppSettings.configURL
        .deletingLastPathComponent()
        .appendingPathComponent("ai-profiles", isDirectory: true)

    private init() {
        let saved = (try? Data(contentsOf: Self.stateURL))
            .flatMap { try? JSONDecoder().decode(State.self, from: $0) }
            .map(\.profiles) ?? []
        var seen = Set<String>()
        let valid = saved.filter {
            UUID(uuidString: $0.id) != nil
                && $0.id != AIProfile.systemID
                && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.name.count <= 80
                && $0.name.unicodeScalars.allSatisfy {
                    !CharacterSet.controlCharacters.contains($0)
                }
                && seen.insert($0.id).inserted
        }
        profiles = [Self.systemProfile] + valid.filter { profile in
            do {
                try Self.prepareDirectories(for: profile)
                return true
            } catch {
                NSLog("kero: failed to prepare AI profile \(profile.id): \(error)")
                return false
            }
        }
    }

    func profile(id: String) -> AIProfile {
        profiles.first { $0.id == id } ?? Self.systemProfile
    }

    @discardableResult
    func create(named proposedName: String) throws -> AIProfile {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AIProfileError.emptyName }
        guard name.count <= 80, name.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0)
        }) else {
            throw AIProfileError.invalidName
        }
        guard !profiles.contains(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else {
            throw AIProfileError.duplicateName
        }

        let profile = AIProfile(id: UUID().uuidString.lowercased(), name: name)
        try Self.prepareDirectories(for: profile)
        profiles.append(profile)
        do {
            try save()
            return profile
        } catch {
            profiles.removeAll { $0.id == profile.id }
            throw error
        }
    }

    /// Moves an unused named profile and its provider-owned data to Trash.
    func delete(id: String) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }),
              !profiles[index].isSystem else {
            throw AIProfileError.systemProfile
        }
        let profile = profiles[index]
        let root = Self.profilesURL.appendingPathComponent(profile.id, isDirectory: true)
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.trashItem(at: root, resultingItemURL: nil)
        }
        profiles.remove(at: index)
        do {
            try save()
        } catch {
            profiles.insert(profile, at: index)
            throw error
        }
    }

    /// Environment shared by every terminal associated with `profileID`.
    /// Existing shells keep these stable paths; native CLI login commands
    /// mutate the stores behind them, so subsequent invocations in every tab
    /// naturally see the new account.
    func environment(for profileID: String) -> [String: String] {
        let profile = profile(id: profileID)
        guard !profile.isSystem else { return [:] }
        let root = Self.profilesURL.appendingPathComponent(profile.id, isDirectory: true)
        return [
            "CODEX_HOME": root.appendingPathComponent("codex", isDirectory: true).path,
            "CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude", isDirectory: true).path,
            "KERO_AI_PROFILE": profile.name,
        ]
    }

    private static func prepareDirectories(for profile: AIProfile) throws {
        let fileManager = FileManager.default
        let root = Self.profilesURL.appendingPathComponent(profile.id, isDirectory: true)
        let codex = root.appendingPathComponent("codex", isDirectory: true)
        let claude = root.appendingPathComponent("claude", isDirectory: true)
        for directory in [Self.profilesURL, root, codex, claude] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }

        // Codex may otherwise choose the global macOS Keychain entry, which
        // would collapse named profiles back into one account. The CLI owns
        // auth.json; Kero only selects its documented storage mode.
        let config = codex.appendingPathComponent("config.toml")
        if !fileManager.fileExists(atPath: config.path) {
            try "cli_auth_credentials_store = \"file\"\n".write(
                to: config,
                atomically: true,
                encoding: .utf8
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: config.path
            )
        }
    }

    private func save() throws {
        let directory = Self.stateURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(State(
            profiles: profiles.filter { !$0.isSystem }
        ))
        try data.write(to: Self.stateURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: Self.stateURL.path
        )
    }
}

enum AIProfileError: LocalizedError {
    case emptyName
    case duplicateName
    case invalidName
    case systemProfile

    var errorDescription: String? {
        switch self {
        case .emptyName: String(localized: "Enter a profile name.")
        case .duplicateName: String(localized: "An AI profile with that name already exists.")
        case .invalidName:
            String(localized: "Profile names must be 80 characters or fewer and cannot contain control characters.")
        case .systemProfile: String(localized: "The System AI profile cannot be deleted.")
        }
    }
}
