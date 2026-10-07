import Foundation

/// The app's own folder in Application Support: the meeting store, meeting audio, the
/// sounds a person adds and the downloaded vocabulary model all live under it.
enum AppFolder {
    /// `~/Library/Application Support/Indite`, created if it is missing.
    ///
    /// Every path into the folder starts here, so the move from the app's first name
    /// happens on the first look, before any file in it is opened.
    static var url: URL { location.folder }

    /// The meeting store, named for the app.
    static var store: URL { location.store }

    private static let location: (folder: URL, store: URL) = {
        let support = URL.applicationSupportDirectory
        let first = support.appending(path: "Nscribe", directoryHint: .isDirectory)
        let folder = support.appending(path: "Indite", directoryHint: .isDirectory)
        guard moveFromFirstName(first, to: folder) else {
            // Everything is still under the first name. Use it there, and try the move
            // again on the next launch.
            return (first, first.appending(path: "Nscribe.store"))
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (folder, folder.appending(path: "Indite.store"))
    }()

    /// Until the rename the app was Nscribe, and so were its folder and its store. The
    /// first launch as Indite moves the folder across and renames the store with the
    /// two files SQLite keeps beside it, which have to keep matching it or the latest
    /// saves are lost. A step that fails undoes the ones before it, so the data is
    /// always whole under one name or the other. A folder already called Indite is
    /// left alone.
    ///
    /// False only when there was a folder to move and it could not be moved.
    private static func moveFromFirstName(_ first: URL, to folder: URL) -> Bool {
        let files = FileManager.default
        guard files.fileExists(atPath: first.path), !files.fileExists(atPath: folder.path) else { return true }

        var done: [(from: URL, to: URL)] = []
        do {
            try files.moveItem(at: first, to: folder)
            done.append((first, folder))
            for suffix in ["", "-wal", "-shm"] {
                let from = folder.appending(path: "Nscribe.store" + suffix)
                guard files.fileExists(atPath: from.path) else { continue }
                let to = folder.appending(path: "Indite.store" + suffix)
                try files.moveItem(at: from, to: to)
                done.append((from, to))
            }
            Log.store.notice("Moved the Nscribe folder to Indite")
            return true
        } catch {
            for step in done.reversed() {
                try? files.moveItem(at: step.to, to: step.from)
            }
            Log.store.error("Could not move the Nscribe folder to Indite: \(error, privacy: .public)")
            return false
        }
    }
}
