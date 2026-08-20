// swift-tools-version:6.0
import PackageDescription

// MARK: - Info.plist embedding
//
// This package builds a menu-bar (LSUIElement) executable via SwiftPM. SwiftPM
// executables are not .app bundles, so the Info.plist that carries the TCC usage
// strings (microphone / screen-capture) and `LSUIElement` is embedded directly
// into the binary's `__TEXT,__info_plist` section using a linker section-create
// flag. macOS reads the embedded plist for permission usage descriptions.
//
// The path is resolved relative to the package root at link time.
let infoPlistLinkerFlags: [String] = [
    "-Xlinker", "-sectcreate",
    "-Xlinker", "__TEXT",
    "-Xlinker", "__info_plist",
    "-Xlinker", "Info.plist",
]

let package = Package(
    name: "WriteThatDown",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "WriteThatDown", targets: ["WriteThatDown"]),
        .library(name: "WriteThatDownKit", targets: ["WriteThatDownKit"]),
    ],
    dependencies: [
        // Default transcription engine: portable, open source, fully offline,
        // multilingual, Metal/ANE accelerated. Isolated to the executable target.
        // Pinned to the 0.18.x API the WhisperKitEngine is written against.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", .upToNextMinor(from: "0.18.0")),
        // Native macOS ONNX runtime used by downloadable Parakeet models.
        // Exact pin keeps the binary XCFramework checksums reproducible.
        .package(url: "https://github.com/k2-fsa/sherpa-onnx.git", exact: "1.13.6"),
    ],
    targets: [
        // Core library — system frameworks only, no external dependencies.
        // Compiles and is testable without any network access.
        .target(
            name: "WriteThatDownKit",
            dependencies: [],
            path: "Sources/WriteThatDownKit"
        ),
        // Executable — wires everything together and contains concrete engine
        // adapters. This is the only target that links external inference SDKs.
        .executableTarget(
            name: "WriteThatDown",
            dependencies: [
                "WriteThatDownKit",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "sherpa-onnx", package: "sherpa-onnx"),
            ],
            path: "Sources/WriteThatDown",
            linkerSettings: [
                .unsafeFlags(infoPlistLinkerFlags)
            ]
        ),
        // Deterministic core-conformance tests (§15) using mocks — no audio
        // hardware, no network, no WhisperKit.
        .testTarget(
            name: "WriteThatDownKitTests",
            dependencies: ["WriteThatDownKit"],
            path: "Tests/WriteThatDownKitTests"
        ),
    ]
)
