import XCTest
@testable import GTAdapters

final class ClaudeCodeHookInstallerTests: XCTestCase {
    func testInstallPreservesExistingClaudeHooks() throws {
        let settingsURL = try temporarySettingsURL()
        let existingSettings = """
        {
          "theme": "dark",
          "hooks": {
            "Stop": [
              {
                "matcher": "user-*",
                "hooks": [
                  {
                    "type": "command",
                    "command": "echo user stop"
                  }
                ]
              }
            ],
            "Notification": [
              {
                "matcher": "notify-*",
                "hooks": [
                  {
                    "type": "command",
                    "command": "echo user notification"
                  }
                ]
              }
            ],
            "CustomEvent": [
              {
                "matcher": "custom-*",
                "hooks": [
                  {
                    "type": "command",
                    "command": "echo custom event"
                  }
                ]
              }
            ]
          }
        }
        """
        try existingSettings.write(to: settingsURL, atomically: true, encoding: .utf8)

        try ClaudeCodeHookInstaller(settingsFileURL: settingsURL).installIfNeeded()

        let settings = try readSettings(settingsURL)
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        XCTAssertEqual(settings["theme"] as? String, "dark")
        XCTAssertEqual(hookCommands(in: hooks["Stop"]), ["echo user stop", glasstunnelCommandMarker()])
        XCTAssertEqual(hookCommands(in: hooks["Notification"]), ["echo user notification", glasstunnelCommandMarker()])
        XCTAssertEqual(hookCommands(in: hooks["SubagentStop"]), [glasstunnelCommandMarker()])
        XCTAssertEqual(hookCommands(in: hooks["CustomEvent"]), ["echo custom event"])
    }

    func testInstallIsIdempotentAndReplacesOnlyPreviousGlasstunnelHook() throws {
        let settingsURL = try temporarySettingsURL()
        let installer = ClaudeCodeHookInstaller(settingsFileURL: settingsURL)

        try installer.installIfNeeded()
        try installer.installIfNeeded()

        let hooks = try XCTUnwrap(readSettings(settingsURL)["hooks"] as? [String: Any])
        XCTAssertEqual(hookCommands(in: hooks["Stop"]), [glasstunnelCommandMarker()])
        XCTAssertEqual(hookCommands(in: hooks["Notification"]), [glasstunnelCommandMarker()])
        XCTAssertEqual(hookCommands(in: hooks["SubagentStop"]), [glasstunnelCommandMarker()])
    }

    func testInstallUpdatesOldGlasstunnelHookWithoutRemovingUserHooks() throws {
        let settingsURL = try temporarySettingsURL()
        let existingSettings = """
        {
          "hooks": {
            "Stop": [
              {
                "matcher": ".*",
                "hooks": [
                  {
                    "type": "command",
                    "command": "old command to ~/Library/Application Support/Glasstunnel/cc.sock"
                  }
                ]
              },
              {
                "matcher": "user-*",
                "hooks": [
                  {
                    "type": "command",
                    "command": "echo keep me"
                  }
                ]
              }
            ]
          }
        }
        """
        try existingSettings.write(to: settingsURL, atomically: true, encoding: .utf8)

        try ClaudeCodeHookInstaller(settingsFileURL: settingsURL).installIfNeeded()

        let hooks = try XCTUnwrap(readSettings(settingsURL)["hooks"] as? [String: Any])
        XCTAssertEqual(hookCommands(in: hooks["Stop"]), ["echo keep me", glasstunnelCommandMarker()])
    }

    private func temporarySettingsURL() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }
        return root.appendingPathComponent("settings.json")
    }

    private func readSettings(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func hookCommands(in hooksValue: Any?) -> [String] {
        guard let hookEntries = hooksValue as? [[String: Any]] else { return [] }
        return hookEntries.flatMap { entry -> [String] in
            guard let commands = entry["hooks"] as? [[String: Any]] else { return [] }
            return commands.compactMap { command in
                guard let value = command["command"] as? String else { return nil }
                return value.contains("Glasstunnel/cc.sock") ? glasstunnelCommandMarker() : value
            }
        }
    }

    private func glasstunnelCommandMarker() -> String {
        "<glasstunnel-hook>"
    }
}
