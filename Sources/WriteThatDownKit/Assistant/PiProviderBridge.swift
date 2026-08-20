import Foundation

/// Thin JSON-lines bridge to Pi's public `ModelRuntime`. Provider names,
/// models, auth methods, prompts, and OAuth URLs all come from the installed Pi
/// version instead of a second catalog maintained by Write That Down.
public actor PiProviderBridge {
    private let piExecutable: URL?
    private let nodeExecutable: URL?
    private let credentialStore: PiProviderCredentialStore
    private let timeout: TimeInterval

    public init(
        piExecutable: URL? = nil,
        nodeExecutable: URL? = nil,
        credentialStore: PiProviderCredentialStore = PiProviderCredentialStore(),
        timeout: TimeInterval = 300
    ) {
        self.piExecutable = piExecutable ?? PiConversationAssistant.resolvePiExecutable()
        self.nodeExecutable = nodeExecutable ?? Self.resolveNodeExecutable()
        self.credentialStore = credentialStore
        self.timeout = max(10, timeout)
    }

    public func catalog() async throws -> [PiProviderOption] {
        let session = try makeSession()
        defer { try? FileManager.default.removeItem(at: session.directory) }
        let result = try await runBridge(
            session: session,
            arguments: ["catalog"],
            interaction: nil
        )
        guard case let .catalog(providers) = result else {
            throw ConversationAssistantError.invalidResponse
        }
        return providers
    }

    public func connect(
        providerID: String,
        authType: PiProviderAuthMethod.Kind,
        interaction: PiProviderAuthInteraction
    ) async throws {
        try PiProviderCredentialStore.validateProviderID(providerID)
        let session = try makeSession()
        defer { try? FileManager.default.removeItem(at: session.directory) }
        let result = try await runBridge(
            session: session,
            arguments: ["login", providerID, authType.rawValue],
            interaction: interaction
        )
        guard case .connected = result else { throw ConversationAssistantError.invalidResponse }
        try credentialStore.importCredential(from: session.authFile, providerID: providerID)
    }

    public func disconnect(providerID: String) throws {
        try credentialStore.deleteCredential(for: providerID)
    }

    private struct SessionFiles {
        let directory: URL
        let authFile: URL
        let script: URL
        let stderr: URL
    }

    private enum BridgeResult {
        case catalog([PiProviderOption])
        case connected
    }

    private func makeSession() throws -> SessionFiles {
        guard piExecutable != nil, nodeExecutable != nil else {
            throw ConversationAssistantError.piNotInstalled
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wtd-pi-bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let authFile = directory.appendingPathComponent("auth.json")
        try credentialStore.exportAuthFile(to: authFile)
        let script = directory.appendingPathComponent("bridge.mjs")
        try Self.script.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: script.path)
        return SessionFiles(
            directory: directory,
            authFile: authFile,
            script: script,
            stderr: directory.appendingPathComponent("stderr")
        )
    }

    private func runBridge(
        session: SessionFiles,
        arguments: [String],
        interaction: PiProviderAuthInteraction?
    ) async throws -> BridgeResult {
        guard let nodeExecutable, let piExecutable else {
            throw ConversationAssistantError.piNotInstalled
        }
        let packageRoot = piExecutable.resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let output = Pipe()
        let input = Pipe()
        FileManager.default.createFile(atPath: session.stderr.path, contents: nil)
        let stderrHandle = try FileHandle(forWritingTo: session.stderr)
        defer { try? stderrHandle.close() }

        let process = Process()
        process.executableURL = nodeExecutable
        process.arguments = [
            session.script.path,
            packageRoot.path,
            session.authFile.path,
        ] + arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = stderrHandle
        var environment: [String: String] = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8",
            "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        environment["PI_OFFLINE"] = "1"
        environment["PI_TELEMETRY"] = "0"
        environment["PI_SKIP_VERSION_CHECK"] = "1"
        process.environment = environment

        do { try process.run() }
        catch { throw ConversationAssistantError.launchFailed(error.localizedDescription) }

        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if process.isRunning { process.terminate() }
        }
        defer { timeoutTask.cancel() }

        var finalResult: BridgeResult?
        var promptTasks: [Task<Void, Never>] = []
        defer { promptTasks.forEach { $0.cancel() } }
        do {
            for try await line in output.fileHandleForReading.bytes.lines {
                guard let data = line.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let kind = object["kind"] as? String
                else { continue }
                switch kind {
                case "catalog":
                    finalResult = .catalog(try Self.decodeCatalog(object))
                case "prompt":
                    guard let interaction else { throw ConversationAssistantError.invalidResponse }
                    let prompt = try Self.decodePrompt(object)
                    // Pi's browser OAuth can finish through its localhost
                    // callback while the manual-code fallback prompt is still
                    // visible. Keep draining stdout so the later `complete`
                    // message is not blocked behind that optional prompt.
                    promptTasks.append(Task {
                        do {
                            let response = try await interaction.prompt(prompt)
                            try Task.checkCancellation()
                            let payload = try JSONSerialization.data(
                                withJSONObject: ["id": prompt.id, "value": response]
                            )
                            try input.fileHandleForWriting.write(contentsOf: payload)
                            try input.fileHandleForWriting.write(contentsOf: Data([0x0A]))
                        } catch is CancellationError {
                            // Expected when an OAuth callback completes first.
                        } catch {
                            if process.isRunning { process.terminate() }
                        }
                    })
                case "event":
                    if let event = Self.decodeEvent(object), let interaction {
                        await interaction.notify(event)
                    }
                case "complete":
                    finalResult = .connected
                    promptTasks.forEach { $0.cancel() }
                case "error":
                    throw ConversationAssistantError.requestFailed(
                        String((object["message"] as? String ?? "Pi authentication failed.").prefix(800))
                    )
                default:
                    continue
                }
            }
        } catch is CancellationError {
            if process.isRunning { process.terminate() }
            throw ConversationAssistantError.cancelled
        }
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        try? stderrHandle.synchronize()
        guard process.terminationStatus == 0 else {
            let message = (try? String(contentsOf: session.stderr, encoding: .utf8)) ?? "Pi bridge failed."
            throw ConversationAssistantError.requestFailed(String(message.split(separator: "\n").last ?? "Pi bridge failed."))
        }
        guard let finalResult else { throw ConversationAssistantError.invalidResponse }
        return finalResult
    }

    private static func decodeCatalog(_ object: [String: Any]) throws -> [PiProviderOption] {
        guard let rawProviders = object["providers"] as? [[String: Any]] else {
            throw ConversationAssistantError.invalidResponse
        }
        return try rawProviders.map { raw in
            guard let id = raw["id"] as? String, let name = raw["name"] as? String else {
                throw ConversationAssistantError.invalidResponse
            }
            let methods: [PiProviderAuthMethod] = (raw["authMethods"] as? [[String: Any]] ?? []).compactMap { method in
                guard let rawKind = method["kind"] as? String,
                      let kind = PiProviderAuthMethod.Kind(rawValue: rawKind),
                      let methodName = method["name"] as? String
                else { return nil }
                return PiProviderAuthMethod(
                    kind: kind,
                    name: methodName,
                    loginLabel: method["loginLabel"] as? String,
                    isSubscription: method["isSubscription"] as? Bool ?? false,
                    isInteractive: method["isInteractive"] as? Bool ?? true
                )
            }
            let models: [PiAssistantModelOption] = (raw["models"] as? [[String: Any]] ?? []).compactMap { model in
                guard let modelID = model["id"] as? String, let title = model["title"] as? String else { return nil }
                return PiAssistantModelOption(id: modelID, title: title)
            }
            let configuredType = (raw["configuredAuthType"] as? String).flatMap(PiProviderAuthMethod.Kind.init(rawValue:))
            return PiProviderOption(
                id: id,
                name: name,
                authMethods: methods,
                models: models,
                isConfigured: raw["isConfigured"] as? Bool ?? false,
                configuredAuthType: configuredType
            )
        }
    }

    private static func decodePrompt(_ object: [String: Any]) throws -> PiAuthPrompt {
        guard let id = object["id"] as? String,
              let raw = object["prompt"] as? [String: Any],
              let rawKind = raw["type"] as? String,
              let kind = PiAuthPrompt.Kind(rawValue: rawKind),
              let message = raw["message"] as? String
        else { throw ConversationAssistantError.invalidResponse }
        let options = (raw["options"] as? [[String: Any]] ?? []).compactMap { option -> PiAuthPrompt.Option? in
            guard let optionID = option["id"] as? String, let label = option["label"] as? String else { return nil }
            return .init(id: optionID, label: label, detail: option["description"] as? String)
        }
        return PiAuthPrompt(
            id: id,
            kind: kind,
            message: message,
            placeholder: raw["placeholder"] as? String,
            options: options
        )
    }

    private static func decodeEvent(_ object: [String: Any]) -> PiAuthEvent? {
        guard let raw = object["event"] as? [String: Any], let type = raw["type"] as? String else { return nil }
        switch type {
        case "info":
            let links = (raw["links"] as? [[String: Any]] ?? []).compactMap { link -> PiAuthLink? in
                guard let value = link["url"] as? String, let url = URL(string: value) else { return nil }
                return PiAuthLink(label: link["label"] as? String, url: url)
            }
            return .info(message: raw["message"] as? String ?? "", links: links)
        case "auth_url":
            guard let value = raw["url"] as? String, let url = URL(string: value) else { return nil }
            return .authURL(url, instructions: raw["instructions"] as? String)
        case "device_code":
            guard let code = raw["userCode"] as? String,
                  let value = raw["verificationUri"] as? String,
                  let url = URL(string: value)
            else { return nil }
            return .deviceCode(code: code, verificationURL: url, expiresInSeconds: raw["expiresInSeconds"] as? Int)
        case "progress":
            return .progress(raw["message"] as? String ?? "")
        default:
            return nil
        }
    }

    private static func resolveNodeExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/node"),
            URL(fileURLWithPath: "/opt/homebrew/bin/node"),
            URL(fileURLWithPath: "/usr/local/bin/node"),
            URL(fileURLWithPath: "/usr/bin/node"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static let script = #"""
    import { pathToFileURL } from "node:url";
    import { createInterface } from "node:readline";

    const [packageRoot, authPath, command, providerID, authType] = process.argv.slice(2);
    const send = (value) => process.stdout.write(JSON.stringify(value) + "\n");

    try {
      const module = await import(pathToFileURL(`${packageRoot}/dist/index.js`).href);
      const runtime = await module.ModelRuntime.create({
        authPath,
        modelsPath: null,
        refreshOnCreate: false,
        allowModelNetwork: false,
      });

      if (command === "catalog") {
        const credentials = new Map((await runtime.listCredentials()).map((entry) => [entry.providerId, entry.type]));
        const providers = runtime.getProviders().map((provider) => {
          const authMethods = [];
          if (provider.auth.apiKey) authMethods.push({
            kind: "api_key",
            name: provider.auth.apiKey.name,
            isInteractive: Boolean(provider.auth.apiKey.login),
            isSubscription: false,
          });
          if (provider.auth.oauth) authMethods.push({
            kind: "oauth",
            name: provider.auth.oauth.name,
            loginLabel: provider.auth.oauth.loginLabel,
            isInteractive: true,
            isSubscription: provider.auth.oauth.isSubscription === true,
          });
          return {
            id: provider.id,
            name: provider.name,
            authMethods,
            models: runtime.getModels(provider.id).map((model) => ({ id: model.id, title: model.name || model.id })),
            isConfigured: credentials.has(provider.id),
            configuredAuthType: credentials.get(provider.id),
          };
        }).sort((a, b) => a.name.localeCompare(b.name));
        send({ kind: "catalog", providers });
      } else if (command === "login") {
        const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
        const lines = input[Symbol.asyncIterator]();
        let sequence = 0;
        const interaction = {
          async prompt(prompt) {
            const id = String(++sequence);
            send({ kind: "prompt", id, prompt });
            while (true) {
              const next = await lines.next();
              if (next.done) throw new Error("Sign-in was cancelled.");
              const response = JSON.parse(next.value);
              if (response.id === id) return String(response.value ?? "");
            }
          },
          notify(event) { send({ kind: "event", event }); },
        };
        await runtime.login(providerID, authType, interaction);
        send({ kind: "complete" });
        input.close();
      } else {
        throw new Error("Unknown bridge command.");
      }
    } catch (error) {
      send({ kind: "error", message: error instanceof Error ? error.message : String(error) });
      process.exitCode = 1;
    }
    """#
}
