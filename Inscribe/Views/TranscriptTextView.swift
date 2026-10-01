import SwiftUI

#if os(macOS)
import AppKit

/// One speaker's line of a transcript, as the text view needs it.
///
/// A plain value, so the view knows nothing of the store. What it shows can be
/// compared with what it showed last, and it is drawn again only when that differs.
struct TranscriptLine: Equatable, Identifiable {
    let id: AnyHashable
    let speakerId: String
    let speakerName: String
    let color: NSColor
    let timestamp: String
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    /// When each word of `text` was spoken, one per word in order, for a recording
    /// that kept its word timings. Nil for one that did not, where a word's moment is
    /// estimated from its place in the line.
    var wordTimes: [TimeInterval]?
}

/// A speaker a line can be given to.
struct TranscriptSpeaker: Equatable {
    let id: String
    let name: String
}

/// What the transcript asks of whoever owns the meeting.
struct TranscriptActions {
    /// Move the playhead. The view never plays or pauses by itself.
    var seek: (TimeInterval) -> Void = { _ in }
    /// Give a line to another speaker.
    var reassign: (_ line: AnyHashable, _ speakerId: String) -> Void = { _, _ in }
    /// Give a line to a speaker who is not in the meeting yet.
    var reassignToNewSpeaker: (_ line: AnyHashable) -> Void = { _ in }
    /// Cut a line in two at a character of its text. The second half goes to the
    /// speaker named, or to a new one when none is.
    var split: (_ line: AnyHashable, _ characterOffset: Int, _ speakerId: String?) -> Void = { _, _, _ in }
}

/// A meeting's transcript as one continuous text.
///
/// It used to be a stack of SwiftUI `Text` views, one per line, and a click on a line
/// played it. That made the words inert: SwiftUI's text can be selected or clicked,
/// not both, it cannot say which word a click landed on, and a selection could never
/// run from one speaker's line into the next. Copying a sentence meant copying the
/// whole transcript.
///
/// This is AppKit's text view, not editable. It selects across speakers, it brings
/// the system's find bar, and it knows the character under a click, which is what
/// moves the playhead to a word. Whatever is passed as `header` scrolls with the
/// text, as the top of the same page.
struct TranscriptView<Header: View>: NSViewRepresentable {
    let lines: [TranscriptLine]
    let speakers: [TranscriptSpeaker]
    /// The line the playhead is in, marked whether playing or paused.
    let playingID: AnyHashable?
    /// Whether audio is running, which is when the view follows the playhead.
    let isPlaying: Bool
    /// Whether there is a recording to seek in.
    let canPlay: Bool
    /// Where the playhead is this instant. Asked many times a second while audio
    /// runs, to mark the word being said, so it is a function and not a value: a value
    /// would have SwiftUI redraw the page for every word.
    let playhead: () -> TimeInterval
    let actions: TranscriptActions
    @ViewBuilder let header: () -> Header

    func makeCoordinator() -> TranscriptCoordinator {
        TranscriptCoordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let headerController = NSHostingController(rootView: AnyView(header()))
        let document = TranscriptDocumentView(headerController: headerController, coordinator: coordinator)
        scrollView.documentView = document

        // As wide as the scroll view, and as tall as its own contents say.
        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor)
        ])

        coordinator.document = document
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.actions = actions
        coordinator.speakers = speakers
        coordinator.canPlay = canPlay
        coordinator.playhead = playhead
        coordinator.document?.headerController.rootView = AnyView(header())
        coordinator.show(lines)
        coordinator.mark(playing: playingID, following: isPlaying)
        coordinator.followWords(isPlaying)
        coordinator.document?.needsLayout = true
    }
}

// MARK: - Attributes

private extension NSAttributedString.Key {
    /// On a line's words: the index of the line in the transcript.
    static let transcriptLine = NSAttributedString.Key("InscribeTranscriptLine")
    /// On a speaker's name: the index of the line it heads.
    static let transcriptSpeaker = NSAttributedString.Key("InscribeTranscriptSpeaker")
}

// MARK: - Coordinator

/// Builds the text, and turns clicks in it into seeks and corrections.
@MainActor
final class TranscriptCoordinator: NSObject {
    fileprivate weak var document: TranscriptDocumentView?

    var actions = TranscriptActions()
    var speakers: [TranscriptSpeaker] = []
    var canPlay = false
    var playhead: () -> TimeInterval = { 0 }

    private(set) var lines: [TranscriptLine] = []
    /// Where each line's words sit in the text, in the order of `lines`.
    private var wordRanges: [NSRange] = []
    /// The whole of each line, name and words, for marking the one being played.
    private var lineRanges: [NSRange] = []
    /// Where each word sits inside its line's words, for the lines that have word
    /// timings; empty for the others.
    private var wordsInLine: [[NSRange]] = []
    private var playingIndex: Int?
    /// The word marked as being said, in the playing line.
    private var playingWord: Int?
    /// Moves the word mark along while audio runs.
    private var wordFollower: Task<Void, Never>?

    private static let lineTint = NSColor.controlAccentColor.withAlphaComponent(0.14)
    private static let wordTint = NSColor.controlAccentColor.withAlphaComponent(0.42)

    // MARK: Text

    /// Show these lines, doing nothing when they are the ones already shown.
    ///
    /// SwiftUI calls this on every redraw of the page, four times a second while audio
    /// plays. Setting the text each time would throw away the selection and the place
    /// scrolled to.
    func show(_ newLines: [TranscriptLine]) {
        guard newLines != lines, let textView = document?.textView else { return }
        lines = newLines
        playingIndex = nil
        playingWord = nil

        let text = NSMutableAttributedString()
        wordRanges = []
        lineRanges = []
        // Kept only where they agree with the timings in number. Timings for some
        // other wording of the line would mark the wrong words.
        wordsInLine = lines.map { line in
            guard let times = line.wordTimes else { return [] }
            let ranges = WordAlignment.wordRanges(in: line.text)
            return ranges.count == times.count ? ranges : []
        }

        for (index, line) in lines.enumerated() {
            let lineStart = text.length

            text.append(NSAttributedString(string: "● ", attributes: [
                .font: TranscriptStyle.dotFont,
                .foregroundColor: line.color,
                .baselineOffset: 1,
                .paragraphStyle: TranscriptStyle.nameParagraph,
                .transcriptSpeaker: index,
                .cursor: NSCursor.pointingHand
            ]))
            text.append(NSAttributedString(string: line.speakerName, attributes: [
                .font: TranscriptStyle.nameFont,
                .foregroundColor: line.color,
                .paragraphStyle: TranscriptStyle.nameParagraph,
                .transcriptSpeaker: index,
                .cursor: NSCursor.pointingHand,
                .toolTip: "Change who said this"
            ]))
            text.append(NSAttributedString(string: "   \(line.timestamp)\n", attributes: [
                .font: TranscriptStyle.timeFont,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: TranscriptStyle.nameParagraph
            ]))

            let wordsStart = text.length
            text.append(NSAttributedString(string: line.text, attributes: [
                .font: TranscriptStyle.wordsFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: TranscriptStyle.wordsParagraph,
                .transcriptLine: index
            ]))
            wordRanges.append(NSRange(location: wordsStart, length: text.length - wordsStart))

            text.append(NSAttributedString(string: "\n", attributes: [
                .font: TranscriptStyle.wordsFont,
                .paragraphStyle: TranscriptStyle.wordsParagraph
            ]))
            lineRanges.append(NSRange(location: lineStart, length: text.length - lineStart))
        }

        textView.textStorage?.setAttributedString(text)
        document?.needsLayout = true
    }

    // MARK: Playback

    /// Mark the line the playhead is in, and keep it on screen while audio runs.
    func mark(playing id: AnyHashable?, following: Bool) {
        let index = id.flatMap { id in lines.firstIndex { $0.id == id } }
        guard index != playingIndex, let textView = document?.textView,
              let layoutManager = textView.layoutManager else { return }

        if let old = playingIndex, old < lineRanges.count {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: lineRanges[old])
        }
        playingIndex = index
        playingWord = nil
        guard let index, index < lineRanges.count else { return }

        // A temporary attribute: drawn, and no part of the text, so a copy of the
        // line does not carry a background with it.
        layoutManager.addTemporaryAttribute(.backgroundColor, value: Self.lineTint, forCharacterRange: lineRanges[index])
        markWord()

        // Only while audio runs. A click that moves the playhead is already looking at
        // the line, and scrolling under the pointer would move the words it clicked.
        if following {
            let glyphs = layoutManager.glyphRange(forCharacterRange: lineRanges[index], actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textView.textContainer!)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            if !textView.visibleRect.contains(rect) {
                textView.scrollToVisible(rect.insetBy(dx: 0, dy: -40))
            }
        }
    }

    /// Keep the word mark moving while audio runs, and place it once when it stops.
    ///
    /// Fifteen times a second, inside AppKit. Speech runs at about three words a
    /// second, and the player's own tick, four a second, would mark every word late.
    func followWords(_ isPlaying: Bool) {
        markWord()
        guard isPlaying else {
            wordFollower?.cancel()
            wordFollower = nil
            return
        }
        guard wordFollower == nil else { return }
        wordFollower = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(66))
                guard let self, !Task.isCancelled else { return }
                self.markWord()
            }
        }
    }

    /// Mark the word under the playhead in the playing line, when the line has word
    /// timings. A line without them keeps the line's own mark and no more: a guess
    /// at the word would be wrong more often than right.
    func markWord() {
        guard let index = playingIndex, index < wordsInLine.count,
              let times = lines[index].wordTimes, !wordsInLine[index].isEmpty,
              let layoutManager = document?.textView.layoutManager else { return }

        // The last word that has begun by now.
        let now = playhead()
        var low = 0
        var high = times.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if times[middle] <= now { low = middle } else { high = middle - 1 }
        }
        guard low != playingWord else { return }

        let base = wordRanges[index].location
        func absolute(_ word: Int) -> NSRange {
            NSRange(location: base + wordsInLine[index][word].location, length: wordsInLine[index][word].length)
        }
        if let old = playingWord, old < wordsInLine[index].count {
            layoutManager.addTemporaryAttribute(.backgroundColor, value: Self.lineTint, forCharacterRange: absolute(old))
        }
        layoutManager.addTemporaryAttribute(.backgroundColor, value: Self.wordTint, forCharacterRange: absolute(low))
        playingWord = low
    }

    /// The moment a character of the text was spoken.
    ///
    /// The start of the word it is in, where the recording kept its word timings.
    /// Otherwise estimated from the character's place in its line: a line knows only
    /// when it began and ended, so a word halfway along it is taken to fall halfway
    /// through.
    func time(forCharacterAt characterIndex: Int) -> TimeInterval? {
        guard let (index, offset) = line(forCharacterAt: characterIndex) else { return nil }
        let line = lines[index]

        if let times = line.wordTimes, !wordsInLine[index].isEmpty {
            // The word the character is in, or the one before a space that was clicked.
            let word = wordsInLine[index].lastIndex { $0.location <= offset } ?? 0
            return times[word]
        }

        let length = max(wordRanges[index].length, 1)
        return line.start + (line.end - line.start) * Double(offset) / Double(length)
    }

    /// The line a character of the text belongs to, and how far into the line's words
    /// it is. Nil for a name, a time, or the space between lines.
    func line(forCharacterAt characterIndex: Int) -> (index: Int, offset: Int)? {
        guard let index = wordRanges.firstIndex(where: {
            characterIndex >= $0.location && characterIndex <= $0.location + $0.length
        }) else { return nil }
        return (index, characterIndex - wordRanges[index].location)
    }

    // MARK: Menus

    /// The menu under a speaker's name: who else the line could belong to.
    func speakerMenu(forLineAt index: Int) -> NSMenu {
        let menu = NSMenu()
        let line = lines[index]

        let heading = NSMenuItem(title: "Attribute to", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)

        for speaker in speakers {
            let item = TranscriptMenuItem(title: speaker.name) { [weak self] in
                self?.actions.reassign(line.id, speaker.id)
            }
            item.state = speaker.id == line.speakerId ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(TranscriptMenuItem(title: "A New Speaker") { [weak self] in
            self?.actions.reassignToNewSpeaker(line.id)
        })
        return menu
    }

    /// What a right-click on a word offers, above the text view's own Copy and Look Up.
    func wordItems(forCharacterAt characterIndex: Int, in textView: NSTextView) -> [NSMenuItem] {
        guard let (index, _) = line(forCharacterAt: characterIndex) else { return [] }
        let line = lines[index]
        var items: [NSMenuItem] = []

        if canPlay, let time = time(forCharacterAt: characterIndex) {
            items.append(TranscriptMenuItem(title: "Move Playhead Here") { [weak self] in
                self?.actions.seek(time)
            })
        }

        // Cut at the start of the word that was clicked, since a speaker starts on a
        // word. Nothing to cut at the line's first word.
        let word = textView.selectionRange(
            forProposedRange: NSRange(location: characterIndex, length: 0),
            granularity: .selectByWord
        )
        let offset = word.location - wordRanges[index].location
        if offset > 0 {
            let split = NSMenuItem(title: "Split Line Here, Rest to", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for speaker in speakers where speaker.id != line.speakerId {
                submenu.addItem(TranscriptMenuItem(title: speaker.name) { [weak self] in
                    self?.actions.split(line.id, offset, speaker.id)
                })
            }
            if !submenu.items.isEmpty { submenu.addItem(.separator()) }
            submenu.addItem(TranscriptMenuItem(title: "A New Speaker") { [weak self] in
                self?.actions.split(line.id, offset, nil)
            })
            split.submenu = submenu
            items.append(split)
        }

        return items
    }
}

/// A menu item that runs a closure, so a menu can be built where its meaning is known.
private final class TranscriptMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("Built in code only")
    }

    @objc private func fire() {
        run()
    }
}

// MARK: - Style

/// The transcript's type: the system font throughout. The words were tried in New
/// York, the system's serif, and Jonathan found it ugly on the page.
@MainActor
private enum TranscriptStyle {
    static let wordsFont = NSFont.preferredFont(forTextStyle: .body)

    static let nameFont: NSFont = {
        let size = NSFont.preferredFont(forTextStyle: .subheadline).pointSize
        return NSFont.systemFont(ofSize: size, weight: .semibold)
    }()

    static let dotFont = NSFont.systemFont(ofSize: 7)

    static let timeFont: NSFont = {
        let size = NSFont.preferredFont(forTextStyle: .caption1).pointSize
        return NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }()

    static let nameParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 3
        return style
    }()

    static let wordsParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        style.paragraphSpacing = 18
        return style
    }()

    /// The widest the text runs, and the least room kept beside it.
    static let measure: CGFloat = 760
    static let margin: CGFloat = 32
}

// MARK: - Document

/// The scrolling page: the header on top, the text under it.
///
/// The header is SwiftUI and the text is AppKit, and they scroll as one page because
/// they are two subviews of one document. Each is as tall as its contents at the
/// width the window gives, worked out again whenever that width changes.
final class TranscriptDocumentView: NSView {
    let headerController: NSHostingController<AnyView>
    let textView: TranscriptNSTextView

    private let headerHeight: NSLayoutConstraint
    private let textHeight: NSLayoutConstraint

    override var isFlipped: Bool { true }

    init(headerController: NSHostingController<AnyView>, coordinator: TranscriptCoordinator) {
        self.headerController = headerController
        self.textView = TranscriptNSTextView.make(coordinator: coordinator)

        let header = headerController.view
        headerHeight = header.heightAnchor.constraint(equalToConstant: 0)
        textHeight = textView.heightAnchor.constraint(equalToConstant: 0)

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // The hosting view would otherwise bring constraints of its own, sized for
        // the header at its widest, and fight the width the page gives it.
        headerController.sizingOptions = []
        header.translatesAutoresizingMaskIntoConstraints = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        addSubview(textView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerHeight,
            textView.topAnchor.constraint(equalTo: header.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
            textHeight
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Built in code only")
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 0 else { return }

        // The text keeps to a readable measure and sits in the middle of a wide window.
        let side = max(TranscriptStyle.margin, (width - TranscriptStyle.measure) / 2)
        if textView.textContainerInset.width != side {
            textView.textContainerInset = NSSize(width: side, height: 4)
        }

        let header = ceil(headerController.sizeThatFits(in: NSSize(width: width, height: .greatestFiniteMagnitude)).height)
        let text = textView.heightOfText()

        // Changing a height asks for another pass, which finds nothing left to change.
        if abs(headerHeight.constant - header) > 0.5 { headerHeight.constant = header }
        if abs(textHeight.constant - text) > 0.5 { textHeight.constant = text }
    }
}

// MARK: - Text View

/// The text view itself: read-only, selectable, and aware of names and words.
final class TranscriptNSTextView: NSTextView {
    private weak var coordinator: TranscriptCoordinator?

    /// Built on the older text system on purpose. Marking the line being played is a
    /// temporary attribute on the layout manager, and asking a new-system text view
    /// for its layout manager converts it mid-flight.
    static func make(coordinator: TranscriptCoordinator) -> TranscriptNSTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        let textView = TranscriptNSTextView(frame: .zero, textContainer: container)
        textView.coordinator = coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.displaysLinkToolTips = true
        return textView
    }

    /// How tall the text is at the view's present width.
    func heightOfText() -> CGFloat {
        guard let layoutManager, let textContainer else { return 0 }
        layoutManager.ensureLayout(for: textContainer)
        return ceil(layoutManager.usedRect(for: textContainer).height) + 2 * textContainerInset.height
    }

    /// The character under a point of the view, or nil when the point is past the
    /// text: in a margin, or under the last line.
    private func characterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard glyphRect.insetBy(dx: -2, dy: -2).contains(inContainer) else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyph)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // A click on a speaker's name opens the menu of who else the line could be.
        if let index = characterIndex(at: point),
           let line = textStorage?.attribute(.transcriptSpeaker, at: index, effectiveRange: nil) as? Int,
           let coordinator {
            let menu = coordinator.speakerMenu(forLineAt: line)
            menu.popUp(positioning: nil, at: NSPoint(x: point.x, y: point.y + 6), in: self)
            return
        }

        // Runs the whole click or drag before returning.
        super.mouseDown(with: event)

        // A click that selected nothing moves the playhead to the word clicked. A drag
        // or a double-click selected something, and is left as a selection. A click in
        // a margin or under the last line is on no word, and moves nothing.
        guard event.clickCount == 1, selectedRange().length == 0, characterIndex(at: point) != nil,
              let coordinator, coordinator.canPlay,
              let time = coordinator.time(forCharacterAt: selectedRange().location) else { return }
        coordinator.actions.seek(time)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let point = convert(event.locationInWindow, from: nil)
        guard let index = characterIndex(at: point), let coordinator else { return menu }

        let items = coordinator.wordItems(forCharacterAt: index, in: self)
        guard !items.isEmpty else { return menu }
        for item in items.reversed() {
            menu.insertItem(item, at: 0)
        }
        menu.insertItem(.separator(), at: items.count)
        return menu
    }

    /// ⌘F, ⌘G and ⇧⌘G, answered here because a menu bar app's Edit menu is not
    /// always in the chain when its window has the keys.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let action: NSTextFinder.Action? = switch (event.charactersIgnoringModifiers?.lowercased(), modifiers) {
        case ("f", [.command]): .showFindInterface
        case ("g", [.command]): .nextMatch
        case ("g", [.command, .shift]): .previousMatch
        default: nil
        }
        guard let action, window?.isKeyWindow == true else {
            return super.performKeyEquivalent(with: event)
        }
        // The find bar searches the first responder's text, so the transcript takes
        // that role: ⌘F means "find in this meeting" wherever the last click was.
        window?.makeFirstResponder(self)
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        performTextFinderAction(sender)
        return true
    }
}

#endif
