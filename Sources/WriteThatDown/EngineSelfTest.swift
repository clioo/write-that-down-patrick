import Foundation
import WriteThatDownKit

/// Headless self-test for the default (WhisperKit) engine. Loads a model from a
/// local folder, runs inference on a few seconds of synthetic audio, and exits
/// 0/1 — used to verify a model loads and transcribes **fully offline** without
/// launching the menu-bar UI. Invoked via `WriteThatDown --check-model <folder>`.
/// Box so the detached `Task` reports its outcome without mutating a captured
/// local var (which strict concurrency disallows).
private final class ResultBox: @unchecked Sendable {
    var ok = false
}

enum EngineSelfTest {
    /// Self-test a LOCAL model folder (no download).
    static func run(modelFolder: String) -> Never {
        let folder = AppConfiguration.expandTilde(modelFolder)
        run(model: folder.lastPathComponent, modelFolder: folder, label: "loading WhisperKit model from: \(folder.path)")
    }

    /// Download a model variant by name (one-time) into WhisperKit's cache, then
    /// self-test it. Exercises the exact path the app uses when no local folder
    /// is configured. Invoked via `WriteThatDown --download-model <name>`.
    static func runDownload(model: String) -> Never {
        run(model: model, modelFolder: nil, label: "downloading + loading WhisperKit model '\(model)' (one-time)…")
    }

    private static func run(model: String, modelFolder: URL?, label: String) -> Never {
        FileHandle.standardError.write(Data("[self-test] \(label)\n".utf8))

        let engine = WhisperKitEngine()
        let engineConfig = EngineConfig(
            language: "en",
            sampleRate: 16_000,
            windowSeconds: 2,
            model: model,
            modelFolder: modelFolder
        )

        let semaphore = DispatchSemaphore(value: 0)
        let result = ResultBox()

        Task {
            do {
                let t0 = Date()
                try await engine.start(engineConfig)
                let load = Date().timeIntervalSince(t0)
                FileHandle.standardError.write(Data(String(format: "[self-test] model ready in %.1fs\n", load).utf8))

                // ~3 s of audible-level noise to exercise the inference path.
                var samples = [Float](repeating: 0, count: 16_000 * 3)
                for i in samples.indices { samples[i] = Float.random(in: -0.1...0.1) }
                let segments = try await engine.push(AudioBuffer(samples: samples, sampleRate: 16_000))
                _ = try await engine.stop()
                FileHandle.standardError.write(Data("[self-test] inference ran; produced \(segments.count) segment(s)\n".utf8))
                result.ok = true
            } catch {
                FileHandle.standardError.write(Data("[self-test] FAILED: \(error)\n".utf8))
            }
            semaphore.signal()
        }
        semaphore.wait()

        if result.ok {
            print("[self-test] OK — engine loads and transcribes.")
            exit(0)
        } else {
            print("[self-test] FAILED")
            exit(1)
        }
    }
}
