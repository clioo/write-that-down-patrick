import CryptoKit
import Foundation

public enum SpeechModelStoreError: Error, LocalizedError {
    case invalidModelID(String)
    case insecureDownloadURL
    case invalidHTTPStatus(Int)
    case sizeMismatch(file: String, expected: Int64, actual: Int64)
    case integrityCheckFailed(file: String)
    case incompleteModel(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidModelID(id):
            return "Invalid speech model identifier: \(id)"
        case .insecureDownloadURL:
            return "Speech models must be downloaded over HTTPS."
        case let .invalidHTTPStatus(status):
            return "The model server returned HTTP \(status)."
        case let .sizeMismatch(file, expected, actual):
            return "Downloaded \(file) has the wrong size (expected \(expected), got \(actual))."
        case let .integrityCheckFailed(file):
            return "Downloaded \(file) failed its integrity check."
        case let .incompleteModel(id):
            return "Speech model \(id) is incomplete."
        }
    }
}

/// Owns the local speech-model cache and installs downloads transactionally:
/// files land in a staging directory, are checked for exact size + SHA-256,
/// then the complete directory is moved into place in one filesystem operation.
public final class SpeechModelStore: @unchecked Sendable {
    public let rootDirectory: URL

    public init(rootDirectory: URL = SpeechModelStore.defaultRootDirectory) throws {
        self.rootDirectory = rootDirectory
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    public static var defaultRootDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? AppConfiguration.expandTilde("~/Library/Application Support")
        return base.appendingPathComponent("WriteThatDown/SpeechModels", isDirectory: true)
    }

    public func modelDirectory(for manifest: SpeechModelManifest) -> URL {
        modelDirectory(forID: manifest.id)
    }

    public func installState(for manifest: SpeechModelManifest) -> ModelInstallState {
        let directory = modelDirectory(for: manifest)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return .notDownloaded
        }
        return hasExpectedFiles(manifest, in: directory)
            ? .ready
            : .failed("Downloaded files are incomplete. Download the model again.")
    }

    /// Downloads a manifest's files and returns the final model directory.
    /// Completed, verified staging files are reused after a retry.
    public func download(
        _ manifest: SpeechModelManifest,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let finalDirectory = modelDirectory(for: manifest)
        if hasExpectedFiles(manifest, in: finalDirectory) {
            progress(1)
            return finalDirectory
        }

        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let stagingDirectory = rootDirectory.appendingPathComponent("\(manifest.id).partial", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        let totalBytes = max(Int64(1), manifest.sizeBytes)
        var completedBytes: Int64 = 0

        for file in manifest.files {
            try Task.checkCancellation()
            let stagedFile = stagingDirectory.appendingPathComponent(file.name, isDirectory: false)

            if isVerified(file, at: stagedFile) {
                completedBytes += file.sizeBytes
                progress(min(1, Double(completedBytes) / Double(totalBytes)))
                continue
            }

            try? FileManager.default.removeItem(at: stagedFile)
            let completedBeforeFile = completedBytes
            var lastError: Error?

            for attempt in 1...3 {
                try Task.checkCancellation()
                do {
                    let transfer = SpeechModelDownloadTransfer(
                        sourceURL: file.remoteURL,
                        destinationURL: stagedFile,
                        expectedBytes: file.sizeBytes,
                        progress: { bytesWritten in
                            let installed = completedBeforeFile + min(file.sizeBytes, max(0, bytesWritten))
                            progress(min(0.99, Double(installed) / Double(totalBytes)))
                        }
                    )
                    try await transfer.start()
                    try verify(file, at: stagedFile)
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    try? FileManager.default.removeItem(at: stagedFile)
                    if attempt < 3 {
                        try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                    }
                }
            }

            if let lastError { throw lastError }
            completedBytes += file.sizeBytes
            progress(min(1, Double(completedBytes) / Double(totalBytes)))
        }

        guard hasExpectedFiles(manifest, in: stagingDirectory) else {
            throw SpeechModelStoreError.incompleteModel(manifest.id)
        }

        if FileManager.default.fileExists(atPath: finalDirectory.path) {
            try FileManager.default.removeItem(at: finalDirectory)
        }
        try FileManager.default.moveItem(at: stagingDirectory, to: finalDirectory)
        progress(1)
        return finalDirectory
    }

    public func delete(_ manifest: SpeechModelManifest) throws {
        let finalDirectory = modelDirectory(for: manifest)
        let stagingDirectory = rootDirectory.appendingPathComponent("\(manifest.id).partial", isDirectory: true)
        if FileManager.default.fileExists(atPath: finalDirectory.path) {
            try FileManager.default.removeItem(at: finalDirectory)
        }
        if FileManager.default.fileExists(atPath: stagingDirectory.path) {
            try FileManager.default.removeItem(at: stagingDirectory)
        }
    }

    private func modelDirectory(forID id: String) -> URL {
        precondition(
            !id.isEmpty && id != "." && id != ".." && !id.contains("/") && !id.contains("\\"),
            SpeechModelStoreError.invalidModelID(id).localizedDescription
        )
        return rootDirectory.appendingPathComponent(id, isDirectory: true)
    }

    private func hasExpectedFiles(_ manifest: SpeechModelManifest, in directory: URL) -> Bool {
        guard !manifest.files.isEmpty else { return false }
        return manifest.files.allSatisfy { file in
            let url = directory.appendingPathComponent(file.name, isDirectory: false)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize
            else { return false }
            return Int64(size) == file.sizeBytes
        }
    }

    private func isVerified(_ file: SpeechModelFile, at url: URL) -> Bool {
        (try? verify(file, at: url)) != nil
    }

    private func verify(_ file: SpeechModelFile, at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let actualSize = Int64(values.fileSize ?? -1)
        guard actualSize == file.sizeBytes else {
            throw SpeechModelStoreError.sizeMismatch(
                file: file.name,
                expected: file.sizeBytes,
                actual: actualSize
            )
        }
        guard try sha256(of: url) == file.sha256.lowercased() else {
            throw SpeechModelStoreError.integrityCheckFailed(file: file.name)
        }
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// A single URLSession-backed file transfer. The delegate writes the temporary
/// download into the caller's staging path before Foundation removes it.
private final class SpeechModelDownloadTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let sourceURL: URL
    private let destinationURL: URL
    private let expectedBytes: Int64
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()

    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var didFinish = false

    init(
        sourceURL: URL,
        destinationURL: URL,
        expectedBytes: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.expectedBytes = expectedBytes
        self.progress = progress
    }

    func start() async throws {
        guard sourceURL.scheme?.lowercased() == "https" else {
            throw SpeechModelStoreError.insecureDownloadURL
        }

        try await withCheckedThrowingContinuation { continuation in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 3_600
            configuration.waitsForConnectivity = true

            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)

            lock.lock()
            self.continuation = continuation
            self.session = session
            lock.unlock()

            var request = URLRequest(url: sourceURL)
            request.setValue("WriteThatDown/1.0", forHTTPHeaderField: "User-Agent")
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progress(min(expectedBytes, totalBytesWritten))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            if let response = downloadTask.response as? HTTPURLResponse,
               !(200...299).contains(response.statusCode) {
                throw SpeechModelStoreError.invalidHTTPStatus(response.statusCode)
            }
            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.moveItem(at: location, to: destinationURL)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
        } else {
            lock.lock()
            let finished = didFinish
            lock.unlock()
            if !finished {
                finish(.failure(SpeechModelStoreError.incompleteModel(destinationURL.lastPathComponent)))
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let continuation = self.continuation
        let session = self.session
        self.continuation = nil
        self.session = nil
        lock.unlock()

        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}
