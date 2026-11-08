import Foundation
import os

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Cross-platform clipboard service for copying transcribed text
enum ClipboardService {

    /// Copy plain text to the system clipboard.
    ///
    /// Written for this Mac only, so a dictation is never offered to the user's other
    /// devices through Universal Clipboard.
    ///
    /// - Parameter transient: Mark the copy as momentary, for a paste that puts the
    ///   user's own clipboard back straight afterwards. Clipboard managers that follow
    ///   the nspasteboard.org conventions then leave it out of their history.
    /// - Returns: The clipboard's change count after the write, so a caller can tell
    ///   whether anything has replaced it since. Always 0 on iOS.
    @discardableResult
    static func copy(_ text: String, transient: Bool = false) -> Int {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        let change = pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
        if transient {
            pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        }
        #else
        UIPasteboard.general.string = text
        let change = 0
        #endif

        Log.clipboard.notice("Copied \(text.count, privacy: .public) characters to clipboard")
        return change
    }

    #if os(macOS)
    /// Put text on the clipboard as a promise: it is handed over only when an app asks
    /// for it, and `promise.wasCollected` then says one did.
    ///
    /// For a paste into a field that shows nothing when the paste lands. The app
    /// collecting the words is then the only sign that it arrived.
    ///
    /// - Returns: The clipboard's change count after the write, as `copy` returns it.
    @MainActor
    @discardableResult
    static func offer(_ promise: PromisedText, transient: Bool = false, on pasteboard: NSPasteboard = .general) -> Int {
        let change = pasteboard.prepareForNewContents(with: .currentHostOnly)
        let item = NSPasteboardItem()
        item.setDataProvider(promise, forTypes: [.string])
        if transient {
            item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        }
        pasteboard.writeObjects([item])
        // Held for as long as it is on the clipboard: an app that pastes it later
        // still has to be able to collect it.
        offered = promise
        Log.clipboard.notice("Offered \(promise.text.count, privacy: .public) characters on the clipboard")
        return change
    }

    @MainActor private static var offered: PromisedText?

    /// Everything on the clipboard: every item, in every type it offers.
    ///
    /// Plain text alone used to be kept, so a copied screenshot was lost to the
    /// dictation, a copied file came back as its name, and rich text lost its styling.
    static func snapshot() -> [NSPasteboardItem] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    /// Put back what `snapshot()` took.
    static func restore(_ items: [NSPasteboardItem]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    /// The clipboard's current change count.
    static var changeCount: Int { NSPasteboard.general.changeCount }
    #endif
}

#if os(macOS)
/// Text on the clipboard that an app has to ask for, so Indite learns when one does.
///
/// The app that pastes asks for the text the moment it handles ⌘V. Clipboard managers
/// that follow the nspasteboard.org conventions read the types first and leave a
/// transient copy alone, so they do not collect it.
final class PromisedText: NSObject, NSPasteboardItemDataProvider, Sendable {
    let text: String
    private let collected = OSAllocatedUnfairLock(initialState: false)

    init(_ text: String) {
        self.text = text
    }

    /// Whether an app has asked for the text.
    var wasCollected: Bool { collected.withLock { $0 } }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        item.setString(text, forType: type)
        collected.withLock { $0 = true }
    }
}
#endif
