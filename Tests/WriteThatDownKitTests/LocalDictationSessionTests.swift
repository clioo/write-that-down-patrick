import XCTest
@testable import WriteThatDownKit

final class LocalDictationSessionTests: XCTestCase {
    func testDictationAssemblesFinalSegmentsAndReplacesPartialHypotheses() async throws {
        let engine = MockTranscriptionEngine(
            pushResponses: [
                [Segment(index: -1, timestamp: 0, text: "hello", isFinal: false)],
                [
                    Segment(index: 0, timestamp: 0, text: "Hello", isFinal: true),
                    Segment(index: -1, timestamp: 1, text: "next", isFinal: false),
                ],
            ],
            stopResponse: [Segment(index: 1, timestamp: 1, text: "next sentence.", isFinal: true)]
        )
        let session = LocalDictationSession(engine: engine, configuration: configuration)

        try await session.start()
        try await session.ingest(AudioBuffer(samples: [0.2, 0.1], sampleRate: 16_000))
        try await session.ingest(AudioBuffer(samples: [0.3, 0.2], sampleRate: 16_000))

        let result = try await session.finish()
        let startCount = await engine.startCount
        let pushCount = await engine.pushCount
        let stopCount = await engine.stopCount
        XCTAssertEqual(result, "Hello next sentence.")
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(pushCount, 2)
        XCTAssertEqual(stopCount, 1)
    }

    func testFinishIsIdempotentAndDoesNotStopEngineTwice() async throws {
        let engine = MockTranscriptionEngine(
            stopResponse: [Segment(index: 0, timestamp: 0, text: "Write this down.", isFinal: true)]
        )
        let session = LocalDictationSession(engine: engine, configuration: configuration)
        try await session.start()

        let first = try await session.finish()
        let second = try await session.finish()
        let stopCount = await engine.stopCount
        XCTAssertEqual(first, "Write this down.")
        XCTAssertEqual(second, "Write this down.")
        XCTAssertEqual(stopCount, 1)
    }

    func testSilenceProducesNoText() async throws {
        let engine = MockTranscriptionEngine()
        let session = LocalDictationSession(engine: engine, configuration: configuration)
        try await session.start()
        try await session.ingest(.silent)
        let result = try await session.finish()
        XCTAssertEqual(result, "")
    }

    private var configuration: EngineConfig {
        EngineConfig(
            language: "en",
            sampleRate: 16_000,
            windowSeconds: 2,
            model: "fixture",
            modelFolder: nil
        )
    }
}
