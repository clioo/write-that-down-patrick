import Foundation
import XCTest
@testable import WriteThatDownKit

final class SpeechModelCatalogTests: XCTestCase {
    func testParakeetManifestIsPinnedAndComplete() {
        let manifest = SpeechModelCatalog.parakeetTDTv3

        XCTAssertEqual(manifest.id, "parakeet-tdt-0.6b-v3-int8")
        XCTAssertEqual(manifest.engine, .sherpa)
        XCTAssertEqual(manifest.sampleRate, 16_000)
        XCTAssertEqual(manifest.sizeBytes, 670_478_772)
        XCTAssertTrue(manifest.isRecommended)
        XCTAssertFalse(manifest.isStreaming)
        XCTAssertEqual(Set(manifest.files.map(\.name)).count, manifest.files.count)
        XCTAssertTrue(manifest.files.allSatisfy { $0.remoteURL.scheme == "https" })
        XCTAssertTrue(manifest.files.allSatisfy { $0.remoteURL.path.contains("2bda32ec70b097a55adaa07d9a7173915b43cc78") })
        XCTAssertTrue(manifest.files.allSatisfy { $0.sha256.count == 64 })
    }

    func testStoreRecognizesOnlyCompleteExpectedFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriteThatDownModelStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = SpeechModelManifest(
            id: "tiny-test-model",
            title: "Tiny Test Model",
            summary: "Fixture",
            engine: .sherpa,
            sampleRate: 16_000,
            isStreaming: false,
            isRecommended: false,
            files: [
                SpeechModelFile(
                    name: "weights.bin",
                    remoteURL: URL(string: "https://example.com/weights.bin")!,
                    sizeBytes: 3,
                    sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
                )
            ]
        )
        let store = try SpeechModelStore(rootDirectory: root)
        XCTAssertEqual(store.installState(for: manifest), .notDownloaded)

        let directory = store.modelDirectory(for: manifest)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("ab".utf8).write(to: directory.appendingPathComponent("weights.bin"))
        guard case .failed = store.installState(for: manifest) else {
            return XCTFail("An undersized model must not be reported as ready")
        }

        try Data("abc".utf8).write(to: directory.appendingPathComponent("weights.bin"))
        XCTAssertEqual(store.installState(for: manifest), .ready)

        try store.delete(manifest)
        XCTAssertEqual(store.installState(for: manifest), .notDownloaded)
    }
}
