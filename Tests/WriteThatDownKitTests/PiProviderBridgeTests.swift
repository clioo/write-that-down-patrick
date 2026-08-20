import Foundation
import XCTest
@testable import WriteThatDownKit

final class PiProviderBridgeTests: XCTestCase {
    func testCatalogAndGenericAPIKeyLoginComeFromPiRuntime() async throws {
        let fixture = try ProviderBridgeFixture()
        defer { fixture.remove() }
        let store = PiProviderCredentialStore(serviceName: "com.writethatdown.bridge-tests.\(UUID().uuidString)")
        defer { try? store.deleteCredential(for: "example") }
        let bridge = PiProviderBridge(
            piExecutable: fixture.piExecutable,
            nodeExecutable: fixture.nodeExecutable,
            credentialStore: store,
            timeout: 10
        )

        let initial = try await bridge.catalog()
        XCTAssertEqual(initial.map(\.id), ["example", "oauth-example"])
        XCTAssertEqual(initial[0].authMethods.map(\.kind), [.apiKey])
        XCTAssertEqual(initial[1].authMethods.map(\.kind), [.oauth])
        XCTAssertFalse(initial[0].isConfigured)
        XCTAssertEqual(initial[0].models, [.init(id: "model-a", title: "Model A")])

        try await bridge.connect(
            providerID: "example",
            authType: .apiKey,
            interaction: PiProviderAuthInteraction(
                prompt: { prompt in
                    XCTAssertEqual(prompt.kind, .secret)
                    XCTAssertEqual(prompt.message, "Example API key")
                    return "fixture-secret"
                },
                notify: { event in
                    XCTAssertEqual(event, .progress("Checking key"))
                }
            )
        )

        let saved = try XCTUnwrap(store.credentialData(for: "example"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: String])
        XCTAssertEqual(object["type"], "api_key")
        XCTAssertEqual(object["key"], "fixture-secret")
        let refreshed = try await bridge.catalog()
        XCTAssertTrue(try XCTUnwrap(refreshed.first { $0.id == "example" }).isConfigured)
    }
}

private final class ProviderBridgeFixture {
    let root: URL
    let piExecutable: URL
    let nodeExecutable: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wtd-provider-bridge-tests-\(UUID().uuidString)", isDirectory: true)
        let package = root.appendingPathComponent("package", isDirectory: true)
        let dist = package.appendingPathComponent("dist", isDirectory: true)
        try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
        piExecutable = dist.appendingPathComponent("cli.js")
        try "#!/bin/sh\nexit 0\n".write(to: piExecutable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: piExecutable.path)
        try #"{"type":"module"}"#.write(
            to: package.appendingPathComponent("package.json"),
            atomically: true,
            encoding: .utf8
        )
        try Self.module.write(to: dist.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        nodeExecutable = try Self.findNode()
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    private static func findNode() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/node"),
            URL(fileURLWithPath: "/opt/homebrew/bin/node"),
            URL(fileURLWithPath: "/usr/local/bin/node"),
        ]
        return try XCTUnwrap(candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    private static let module = #"""
    import { readFileSync, writeFileSync } from "node:fs";

    const providers = [
      {
        id: "example",
        name: "Example",
        auth: { apiKey: { name: "Example API key", login: true } },
      },
      {
        id: "oauth-example",
        name: "OAuth Example",
        auth: { oauth: { name: "Example subscription", loginLabel: "Sign in", isSubscription: true } },
      },
    ];

    export class ModelRuntime {
      static async create(options) { return new ModelRuntime(options.authPath); }
      constructor(authPath) { this.authPath = authPath; }
      getProviders() { return providers; }
      getModels(id) { return id === "example" ? [{ id: "model-a", name: "Model A" }] : []; }
      async listCredentials() {
        const data = JSON.parse(readFileSync(this.authPath, "utf8"));
        return Object.entries(data).map(([providerId, value]) => ({ providerId, type: value.type }));
      }
      async login(providerID, type, interaction) {
        interaction.notify({ type: "progress", message: "Checking key" });
        const key = await interaction.prompt({ type: "secret", message: "Example API key", placeholder: "secret" });
        const data = JSON.parse(readFileSync(this.authPath, "utf8"));
        data[providerID] = { type, key };
        writeFileSync(this.authPath, JSON.stringify(data), { mode: 0o600 });
      }
    }
    """#
}
