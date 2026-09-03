import Foundation
import GTProtocol

struct CodexRuntimeSelection: Sendable, Hashable {
    var modelId: String?
    var reasoningEffort: String?
    var fastMode: Bool
}

enum CodexRuntimeCatalog {
    static func defaultSelection() -> CodexRuntimeSelection {
        let config = readConfig()
        return CodexRuntimeSelection(
            modelId: config["model"],
            reasoningEffort: config["model_reasoning_effort"],
            fastMode: config["service_tier"] == "fast"
        )
    }

    static func controls(
        selection: CodexRuntimeSelection,
        editable: Bool,
        appliesOn: AgentRuntimeControls.ApplyTiming,
        note: String? = nil
    ) -> AgentRuntimeControls {
        let catalog = readModelCatalog()
        let modelOptions = catalog.models.map {
            AgentRuntimeOption(id: $0.slug, label: $0.displayName, description: $0.description)
        }
        // A selection names a model, or nothing; a model the catalog does not
        // list keeps its slug rather than borrowing the first entry's name.
        let selectedModel: Model?
        if let modelId = selection.modelId, !modelId.isEmpty {
            selectedModel = catalog.models.first { $0.slug == modelId }
        } else {
            selectedModel = catalog.models.first
        }
        let effortOptions = selectedModel?.supportedReasoningLevels.map {
            AgentRuntimeOption(id: $0.effort, label: effortLabel($0.effort), description: $0.description)
        } ?? fallbackEffortOptions
        let effort = selection.reasoningEffort ?? selectedModel?.defaultReasoningLevel
        let supportsFast = selectedModel?.additionalSpeedTiers.contains("fast") == true || selection.fastMode

        return AgentRuntimeControls(
            modelId: selection.modelId ?? selectedModel?.slug,
            modelLabel: selectedModel?.displayName ?? selection.modelId,
            modelOptions: modelOptions.isEmpty ? fallbackModelOptions(selection: selection) : modelOptions,
            reasoningEffort: effort,
            reasoningEffortLabel: effort.map(effortLabel),
            reasoningEffortOptions: effortOptions,
            fastMode: supportsFast ? selection.fastMode : nil,
            supportsModelSelection: true,
            supportsReasoningEffort: !effortOptions.isEmpty,
            supportsFastMode: supportsFast,
            editable: editable,
            appliesOn: appliesOn,
            note: note
        )
    }

    static func launchArguments(selection: CodexRuntimeSelection) -> [String] {
        var args: [String] = [
            "--no-alt-screen",
            "--disable", "plugins",
            "--disable", "apps",
            "-c", "mcp_servers.node_repl.enabled=false",
        ]
        if let model = selection.modelId, !model.isEmpty {
            args += ["--model", model]
        }
        if let effort = selection.reasoningEffort, !effort.isEmpty {
            args += ["-c", "model_reasoning_effort=\"\(effort)\""]
        }
        args += ["-c", "check_for_update_on_startup=false"]
        args += ["-c", "service_tier=\"\(selection.fastMode ? "fast" : "default")\""]
        return args
    }

    private static let fallbackEffortOptions = [
        AgentRuntimeOption(id: "low", label: "Low"),
        AgentRuntimeOption(id: "medium", label: "Medium"),
        AgentRuntimeOption(id: "high", label: "High"),
        AgentRuntimeOption(id: "xhigh", label: "Extra high"),
    ]

    private static func fallbackModelOptions(selection: CodexRuntimeSelection) -> [AgentRuntimeOption] {
        if let modelId = selection.modelId, !modelId.isEmpty {
            return [AgentRuntimeOption(id: modelId, label: modelId)]
        }
        return [AgentRuntimeOption(id: "gpt-5.5", label: "GPT-5.5")]
    }

    private static func effortLabel(_ effort: String) -> String {
        switch effort {
        case "xhigh": return "Extra high"
        case "high": return "High"
        case "medium": return "Medium"
        case "low": return "Low"
        default: return effort
        }
    }

    private static func readConfig() -> [String: String] {
        let url = codexHome()
            .appendingPathComponent("config.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }

        var values: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), trimmed.contains("=") else { continue }
            let pieces = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { continue }
            let key = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard ["model", "model_reasoning_effort", "service_tier"].contains(key) else { continue }
            values[key] = stripTomlString(pieces[1])
        }
        return values
    }

    private static func stripTomlString(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let commentStart = value.firstIndex(of: "#") {
            value = String(value[..<commentStart]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }
        return value
    }

    private static func readModelCatalog() -> ModelCatalog {
        let url = codexHome()
            .appendingPathComponent("models_cache.json")
        guard let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(ModelCatalog.self, from: data)
        else {
            return ModelCatalog(models: [])
        }
        let visible = catalog.models.filter { $0.visibility != "hidden" }
        return ModelCatalog(models: visible)
    }

    private static func codexHome() -> URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".codex", isDirectory: true)
    }
}

private struct ModelCatalog: Decodable {
    var models: [Model]
}

private struct Model: Decodable {
    var slug: String
    var displayName: String
    var description: String?
    var defaultReasoningLevel: String?
    var supportedReasoningLevels: [ReasoningLevel]
    var additionalSpeedTiers: [String]
    var visibility: String?

    enum CodingKeys: String, CodingKey {
        case slug
        case displayName = "display_name"
        case description
        case defaultReasoningLevel = "default_reasoning_level"
        case supportedReasoningLevels = "supported_reasoning_levels"
        case additionalSpeedTiers = "additional_speed_tiers"
        case visibility
    }
}

private struct ReasoningLevel: Decodable {
    var effort: String
    var description: String?
}
