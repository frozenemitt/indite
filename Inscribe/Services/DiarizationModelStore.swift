import Foundation
import FluidAudio
import CryptoKit

#if os(macOS)

/// What the HuggingFace repository currently holds.
struct RemoteModelRevision: Sendable, Equatable {
    let lastModified: Date?

    /// Every file the repository publishes, keyed by its path.
    var files: [String: RemoteFile] = [:]
}

/// One published file, with whatever HuggingFace states about its contents.
struct RemoteFile: Sendable, Equatable {
    let path: String
    let size: Int

    /// Git blob hash: `sha1("blob <size>\0" + contents)`. Published for every file.
    let blobId: String?

    /// Plain SHA-256 of the contents. Published for LFS files — the model weights.
    let sha256: String?
}

/// What checking the installed files actually established.
struct VerificationReport: Sendable, Equatable {
    /// Files whose hash matched the published one.
    var verified: Int = 0

    /// Files missing from disk, or whose contents disagree with the published copy.
    var mismatched: [String] = []

    var isClean: Bool { mismatched.isEmpty && verified > 0 }
}

/// The verdict of comparing what is installed against what is published.
enum ModelComparison: Sendable, Equatable {
    case upToDate(lastModified: Date?)
    case updateAvailable(lastModified: Date?, changedFiles: Int)
}

/// Manages the CoreML speaker models on disk: what is installed, whether anything
/// newer exists, and replacing them.
///
/// FluidAudio downloads these once and then keeps them forever — its only check is
/// whether the file exists, with no checksum, revision, or update path. That means an
/// install silently keeps whatever the repository held on the day it first ran. This
/// adds the missing half: hash the installed files against the content hashes the
/// repository publishes, on request.
enum DiarizationModelStore {

    /// The HuggingFace repository FluidAudio pulls speaker models from.
    static let repositoryID = "FluidInference/speaker-diarization-coreml"

    // MARK: - Locations

    static var modelsRoot: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
    }

    static var modelsDirectory: URL {
        modelsRoot.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
    }

    // MARK: - Local State

    /// Whether every file FluidAudio loads is on disk whole, ready to load.
    ///
    /// Checking that the model folders exist was not enough. An install interrupted part
    /// way can leave a bundle without its `coremldata.bin`, a weight file still named
    /// `.partial`, or no `plda-parameters.json` at all. Settings then said Installed while
    /// every meeting start failed to load the models. This repeats FluidAudio's own
    /// completeness test, `ModelCache.incompleteFiles`, which is internal to the library
    /// and cannot be called from here.
    static var isInstalled: Bool {
        ModelNames.OfflineDiarizer.requiredModels.allSatisfy { name in
            let url = modelsDirectory.appendingPathComponent(name)
            guard name.hasSuffix(".mlmodelc") else {
                return FileManager.default.fileExists(atPath: url.path)
            }
            return FileManager.default.fileExists(atPath: url.appendingPathComponent("coremldata.bin").path)
                && !containsPartialDownload(url)
        }
    }

    /// Whether a download into `folder` was cut off and left a `.partial` file behind.
    private static func containsPartialDownload(_ folder: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: nil
        ) else { return false }

        for case let file as URL in enumerator where file.pathExtension == "partial" {
            return true
        }
        return false
    }

    /// Keep FluidAudio off the network.
    ///
    /// Left to itself, FluidAudio deletes and re-downloads any model it finds incomplete
    /// or cannot load, wherever it is called from. Set once at launch; `install()` lifts
    /// it for its own download and puts it back.
    static func stayOffline() {
        ModelHub.offlineMode = true
    }

    /// When the models landed on disk.
    static var installedAt: Date? {
        try? FileManager.default
            .attributesOfItem(atPath: modelsDirectory.path)[.modificationDate] as? Date
    }

    static var sizeOnDisk: Int64 { directorySize(modelsDirectory) }

    // MARK: - Install

    /// Download the models.
    ///
    /// Deliberately not called from the recording path: starting a meeting must not
    /// reach the network. Settings is the only caller, behind a button.
    ///
    /// The one place FluidAudio is let online. An incomplete install is repaired here
    /// too: FluidAudio finds the broken model, deletes it and downloads it again.
    static func install() async throws {
        ModelHub.offlineMode = false
        defer { ModelHub.offlineMode = true }

        _ = try await OfflineDiarizerModels.load(from: modelsRoot)
    }

    // MARK: - Remote

    /// Ask HuggingFace what the repository head publishes now.
    ///
    /// Reached only from Settings, when the user presses Check for Updates. Nothing on
    /// the recording path calls it. No audio, transcript, or user data goes with it —
    /// it is a public metadata read.
    static func fetchLatestRevision() async throws -> RemoteModelRevision {
        // blobs=true adds each file's size and content hashes, which is what lets the
        // installed copies be checked without downloading them again.
        let url = URL(string: "https://huggingface.co/api/models/\(repositoryID)?blobs=true")!

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ModelStoreError.badResponse(code)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let siblings = json["siblings"] as? [[String: Any]] else {
            throw ModelStoreError.malformedResponse
        }

        var lastModified: Date?
        if let raw = json["lastModified"] as? String {
            lastModified = ISO8601DateFormatter().date(from: raw)
                ?? ISO8601DateFormatter.fractionalSeconds().date(from: raw)
        }

        var files: [String: RemoteFile] = [:]
        for entry in siblings {
            guard let path = entry["rfilename"] as? String,
                  let size = entry["size"] as? Int else { continue }

            let lfs = entry["lfs"] as? [String: Any]
            files[path] = RemoteFile(
                path: path,
                size: size,
                blobId: entry["blobId"] as? String,
                sha256: lfs?["sha256"] as? String
            )
        }

        return RemoteModelRevision(lastModified: lastModified, files: files)
    }

    /// Compare what is on disk against what the repository publishes.
    ///
    /// Every check hashes the installed files. A recorded revision used to stand in for
    /// them once it matched the head, so a damaged weight file still checked out as
    /// Verified.
    static func compareWithRemote() async throws -> ModelComparison {
        let remote = try await fetchLatestRevision()

        // Hashing 21 MB is quick but not instant, and this is called from the UI.
        let report = await Task.detached { verifyLocalFiles(against: remote.files) }.value

        if report.isClean {
            return .upToDate(lastModified: remote.lastModified)
        }

        return .updateAvailable(
            lastModified: remote.lastModified,
            changedFiles: report.mismatched.count
        )
    }

    /// Check every published file FluidAudio loads against the repository's content hash;
    /// a file missing from disk counts as a mismatch.
    ///
    /// File size was the first thing I reached for and it is not good enough: two
    /// different files can share a size, and a model can be retrained without changing
    /// its byte count at all. HuggingFace publishes real content hashes, so these are
    /// checked instead.
    ///
    /// The walk follows the published list rather than the folder on disk, so a file
    /// the install lacks counts against it. The folder walk this replaced never met a
    /// missing weight file, so it called that install clean.
    ///
    /// Two hash schemes, because the repository uses two. Model weights are stored in
    /// Git LFS and carry a plain SHA-256 of their contents. Everything else is an
    /// ordinary git object identified by its blob hash, `sha1("blob <size>\0" + bytes)`
    /// — the size and null byte are part of what git hashes, not decoration.
    nonisolated static func verifyLocalFiles(against published: [String: RemoteFile]) -> VerificationReport {
        var report = VerificationReport()

        // The repository publishes more than FluidAudio downloads, so only the files
        // it loads are checked.
        let required = ModelNames.OfflineDiarizer.requiredModels
        let loaded = published.values.filter { remote in
            required.contains { remote.path == $0 || remote.path.hasPrefix($0 + "/") }
        }

        for remote in loaded {
            let file = modelsDirectory.appendingPathComponent(remote.path)
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])

            // Size is a free pre-filter. It cannot prove a match, but it does prove a
            // mismatch, and it saves hashing a file that has already failed. A missing
            // file fails here too.
            guard values?.isRegularFile == true,
                  let localSize = values?.fileSize,
                  localSize == remote.size else {
                report.mismatched.append(remote.path)
                continue
            }

            do {
                if let expected = remote.sha256 {
                    let actual = try sha256Hex(of: file)
                    if actual == expected { report.verified += 1 }
                    else { report.mismatched.append(remote.path) }
                } else if let expected = remote.blobId {
                    let actual = try gitBlobHex(of: file, size: localSize)
                    if actual == expected { report.verified += 1 }
                    else { report.mismatched.append(remote.path) }
                }
            } catch {
                report.mismatched.append(remote.path)
            }
        }

        return report
    }

    // MARK: - Hashing

    /// Files are streamed rather than read whole: model weights run to hundreds of
    /// megabytes for other FluidAudio models, and loading one to hash it is wasteful.
    private static let hashChunkSize = 1 << 20

    private nonisolated static func sha256Hex(of url: URL) throws -> String {
        var hasher = SHA256()
        try stream(url) { hasher.update(data: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Git's object hash: the literal bytes `blob <size>\0` followed by the contents.
    private nonisolated static func gitBlobHex(of url: URL, size: Int) throws -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(size)\0".utf8))
        try stream(url) { hasher.update(data: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func stream(_ url: URL, _ consume: (Data) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        while let chunk = try handle.read(upToCount: hashChunkSize), !chunk.isEmpty {
            consume(chunk)
        }
    }

    // MARK: - Mutation

    /// Replace the local copies with fresh ones from HuggingFace.
    ///
    /// Removal rather than in-place replacement: FluidAudio skips any file already on
    /// disk, so a stale copy would survive a re-download.
    ///
    /// This used to stop at the removal and leave the download to the next meeting.
    /// A meeting is not allowed to download, so that meeting recorded without speakers
    /// and Settings offered only Install. The download now follows at once. The old
    /// copies are moved aside rather than deleted until the new ones are in, so a
    /// failed download puts them back instead of leaving no models at all.
    static func reinstall() async throws {
        let fileManager = FileManager.default
        let previous = modelsRoot.appendingPathComponent("\(Repo.diarizer.folderName).previous", isDirectory: true)

        try? fileManager.removeItem(at: previous)
        if fileManager.fileExists(atPath: modelsDirectory.path) {
            try fileManager.moveItem(at: modelsDirectory, to: previous)
        }

        do {
            try await install()
            try? fileManager.removeItem(at: previous)
        } catch {
            try? fileManager.removeItem(at: modelsDirectory)
            if fileManager.fileExists(atPath: previous.path) {
                try? fileManager.moveItem(at: previous, to: modelsDirectory)
            }
            throw error
        }
    }

    // MARK: - Helpers

    private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        var total: Int64 = 0
        for case let file as URL in enumerator {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    enum ModelStoreError: LocalizedError {
        case badResponse(Int)
        case malformedResponse
        case notInstalled

        var errorDescription: String? {
            switch self {
            case .badResponse(let code): "HuggingFace returned status \(code)."
            case .malformedResponse: "Could not read the repository details."
            case .notInstalled: "The speaker separation models are not installed. Install them in Settings."
            }
        }
    }
}

private extension ISO8601DateFormatter {
    /// Built per call rather than shared: `ISO8601DateFormatter` is not `Sendable`,
    /// and this runs once per update check.
    static func fractionalSeconds() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
#endif
