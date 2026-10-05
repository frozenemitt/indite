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

    /// The same line saying something else, after a correction. Its word timings go:
    /// they were worked out for the words it had.
    func saying(_ words: String) -> TranscriptLine {
        TranscriptLine(id: id, speakerId: speakerId, speakerName: speakerName, color: color,
                       timestamp: timestamp, text: words, start: start, end: end, wordTimes: nil)
    }
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
    /// Keep a line's words as the user has corrected them.
    var correct: (_ line: AnyHashable, _ words: String) -> Void = { _, _ in }
}

/// A meeting's transcript as one continuous text.
///
/// It used to be a stack of SwiftUI `Text` views, one per line, and a click on a line
/// played it. That made the words inert: SwiftUI's text can be selected or clicked,
/// not both, it cannot say which word a click landed on, and a selection could never
/// run from one speaker's line into the next. Copying a sentence meant copying the
/// whole transcript.
///
/// This is AppKit's text view. It selects across speakers, it brings the system's
/// find bar, and it knows the character under a click, which is what moves the
/// playhead to a word. The words can be typed over to correct them; the names and
/// times between them cannot. Whatever is passed as `header` scrolls with the
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
    /// What the list is searching for. The page opens on the first place it is said.
    var find = ""
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

        let headerController = NSHostingController(rootView: hosted(header(), in: coordinator))
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
        coordinator.watchPlayhead()
        coordinator.document?.headerController.rootView = hosted(header(), in: coordinator)
        coordinator.show(lines)
        coordinator.land(on: find)
        coordinator.mark(playing: playingID, following: isPlaying)
        coordinator.followWords(isPlaying)
        coordinator.document?.needsLayout = true
    }

    /// The header as the page hosts it: at its own height, and asking for a layout
    /// pass whenever that height changes.
    ///
    /// The hosting view keeps whatever frame the page's constraints give it and says
    /// nothing when its content grows. Show all under the summary unfolded ten points
    /// into the height of three, and every point was cut to one line.
    private func hosted(_ header: Header, in coordinator: TranscriptCoordinator) -> AnyView {
        AnyView(
            header
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in
                    coordinator.document?.needsLayout = true
                }
        )
    }
}

// MARK: - Attributes

private extension NSAttributedString.Key {
    /// On a line's words: the index of the line in the transcript.
    static let transcriptLine = NSAttributedString.Key("NscribeTranscriptLine")
    /// On a speaker's name: the index of the line it heads.
    static let transcriptSpeaker = NSAttributedString.Key("NscribeTranscriptSpeaker")
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

    // MARK: Text

    /// Show these lines, doing nothing when they are the ones already shown.
    ///
    /// SwiftUI calls this on every redraw of the page, four times a second while audio
    /// plays. Setting the text each time would throw away the selection and the place
    /// scrolled to.
    func show(_ newLines: [TranscriptLine]) {
        guard newLines != lines, let textView = document?.textView else { return }

        // After a correction the page hands back the lines the text already shows,
        // with word timings worked out for the new words. Take the timings and leave
        // the text alone: setting it again would move the caret out from under the
        // user's hands and empty the undo stack.
        if newLines.count == lines.count,
           zip(newLines, lines).allSatisfy({ $0.saying("") == $1.saying("") && $0.text == $1.text }) {
            lines = newLines
            wordsInLine = lines.map(Self.words)
            playingWord = nil
            markWord()
            return
        }

        lines = newLines
        playingIndex = nil
        playingWord = nil
        textView.undoManager?.removeAllActions()

        let text = NSMutableAttributedString()
        wordRanges = []
        lineRanges = []
        wordsInLine = lines.map(Self.words)

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
            text.append(NSAttributedString(string: line.text, attributes: Self.wordAttributes(forLineAt: index)))
            wordRanges.append(NSRange(location: wordsStart, length: text.length - wordsStart))

            text.append(NSAttributedString(string: "\n", attributes: [
                .font: TranscriptStyle.wordsFont,
                .paragraphStyle: TranscriptStyle.wordsParagraph
            ]))
            lineRanges.append(NSRange(location: lineStart, length: text.length - lineStart))
        }

        textView.textStorage?.setAttributedString(text)
        textView.playingLine = nil
        textView.playingWord = nil
        document?.needsLayout = true
    }

    /// Where each word of a line sits in its text, for a line that has word timings.
    /// Kept only where the two agree in number: timings for some other wording of the
    /// line would mark the wrong words.
    private static func words(of line: TranscriptLine) -> [NSRange] {
        guard let times = line.wordTimes else { return [] }
        let ranges = WordAlignment.wordRanges(in: line.text)
        return ranges.count == times.count ? ranges : []
    }

    /// How a line's words are set, and the mark that says which line they belong to.
    fileprivate static func wordAttributes(forLineAt index: Int) -> [NSAttributedString.Key: Any] {
        [
            .font: TranscriptStyle.wordsFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: TranscriptStyle.wordsParagraph,
            .transcriptLine: index
        ]
    }

    // MARK: Corrections

    /// Whether a piece of typing may go ahead: only inside one line's words, never
    /// across a name or a time, never a line break, and never the whole of a line.
    ///
    /// The transcript is a document of lines that each belong to someone. Typing may
    /// change what a line says and nothing about whose it is or how many there are.
    func allowsChange(in range: NSRange, to replacement: String, in textView: NSTextView) -> Bool {
        guard let index = wordRanges.firstIndex(where: {
            range.location >= $0.location && NSMaxRange(range) <= NSMaxRange($0)
        }) else { return false }
        guard !replacement.contains(where: \.isNewline) else { return false }
        guard wordRanges[index].length - range.length + replacement.utf16.count > 0 else { return false }

        // Typed text takes its look from the character before it, which at the start
        // of a line is the time above. Say what it is instead.
        textView.typingAttributes = Self.wordAttributes(forLineAt: index)
        return true
    }

    /// Take in what was typed: find where every line now sits, and hand each line
    /// whose words changed to whoever owns the meeting.
    ///
    /// Read back from the shape of the text, which typing cannot change: a name
    /// begins each line, its words begin after the line break that follows, and they
    /// end at the break before the next name. So it holds for one keystroke and for a
    /// Replace All alike. The mark on the words themselves is not trusted for this:
    /// text typed at the very start of a line takes its look, and so its mark, from
    /// the time above it.
    func textChanged(in textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let text = storage.string as NSString

        var starts = [Int?](repeating: nil, count: lines.count)
        storage.enumerateAttribute(.transcriptSpeaker, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let index = value as? Int, index < starts.count, starts[index] == nil else { return }
            starts[index] = range.location
        }
        guard starts.allSatisfy({ $0 != nil }) else { return }

        var words: [NSRange] = []
        for index in lines.indices {
            let nameEnd = text.range(of: "\n", range: NSRange(location: starts[index]!, length: text.length - starts[index]!))
            guard nameEnd.location != NSNotFound else { return }
            let wordsStart = NSMaxRange(nameEnd)
            let wordsEnd = (index + 1 < lines.count ? starts[index + 1]! : text.length) - 1
            guard wordsEnd >= wordsStart else { return }
            words.append(NSRange(location: wordsStart, length: wordsEnd - wordsStart))
        }

        wordRanges = words
        lineRanges = lines.indices.map { index in
            NSRange(location: starts[index]!, length: NSMaxRange(words[index]) + 1 - starts[index]!)
        }

        for index in lines.indices {
            let said = text.substring(with: wordRanges[index])
            guard said != lines[index].text else { continue }
            // Typed at the start of a line, or pasted, text can bring another look.
            storage.setAttributes(Self.wordAttributes(forLineAt: index), range: wordRanges[index])
            lines[index] = lines[index].saying(said)
            wordsInLine[index] = []
            actions.correct(lines[index].id, said)
        }
        playingWord = nil
        document?.needsLayout = true

        // The line being played has moved or grown with the typing, and the word mark
        // is where the old words were. The line's follows now; the word's comes back
        // with the new timings.
        if let index = playingIndex {
            document?.textView.playingLine = lineRanges[index]
            document?.textView.playingWord = nil
        }
    }

    // MARK: Search

    /// The search the page last landed on, so it lands once for each.
    private var landedOn = ""

    /// Go to the first place the meeting says what the list is searching for.
    ///
    /// The list's search used to find the meeting and leave the reader at the top of
    /// it. The words are also handed to the system's find, so ⌘G steps to the next
    /// place they are said.
    func land(on query: String) {
        guard query != landedOn else { return }
        landedOn = query
        guard !query.isEmpty, let textView = document?.textView else { return }

        // In the words only. A search for a speaker's name should land on what was
        // said, not on the name above every line of theirs.
        let text = textView.string as NSString
        let match = wordRanges.lazy
            .map { text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: $0) }
            .first { $0.location != NSNotFound }
        guard let match else { return }

        let pasteboard = NSPasteboard(name: .find)
        pasteboard.clearContents()
        pasteboard.setString(query, forType: .string)

        // Once the text has been laid out, which a page opened this instant has not.
        DispatchQueue.main.async {
            textView.setSelectedRange(match)
            textView.scrollRangeToVisible(match)
            textView.showFindIndicator(for: match)
        }
    }

    // MARK: Playback

    /// Mark the line the playhead is in, and keep it on screen while audio runs.
    func mark(playing id: AnyHashable?, following: Bool) {
        let index = id.flatMap { id in lines.firstIndex { $0.id == id } }
        guard index != playingIndex, let textView = document?.textView else { return }

        playingIndex = index
        playingWord = nil
        textView.playingWord = nil
        guard let index, index < lineRanges.count else {
            textView.playingLine = nil
            return
        }

        // Drawn by the view behind the text, and no part of the text, so a copy of the
        // line does not carry a background with it.
        textView.playingLine = lineRanges[index]
        isFollowing = following
        markWord()

        // Only while audio runs. A click that moves the playhead is already looking at
        // the line, and scrolling under the pointer would move the words it clicked.
        // A line with word timings is followed word by word instead, in `markWord`,
        // which keeps the word in view through a line taller than the window.
        if following, wordsInLine[index].isEmpty {
            show(lineRanges[index], keeping: 40)
        }
    }

    /// Whether audio runs, which is when the page follows the mark.
    private var isFollowing = false

    /// Bring a stretch of the text into view, when it is not already.
    private func show(_ characters: NSRange, keeping margin: CGFloat) {
        guard let textView = document?.textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        guard !textView.visibleRect.contains(rect) else { return }
        document?.scroll(toShow: textView.convert(rect, to: document), keeping: margin)
    }

    /// Keep the word mark moving while audio runs, and place it once when it stops.
    ///
    /// Fifteen times a second, inside AppKit. Speech runs at about three words a
    /// second, and the player's own tick, four a second, would mark every word late.
    func followWords(_ isPlaying: Bool) {
        isFollowing = isPlaying
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

    /// Whether the playhead is being watched for moves made by hand.
    private var watchesPlayhead = false

    /// Mark the word again each time the playhead is moved by hand: a click on a
    /// word, a drag of the strip, a skip.
    ///
    /// While audio runs the follower catches up within a tick. While paused, nothing
    /// else would: SwiftUI redraws the page when the playing line changes, and a click
    /// on another word of the same line changed nothing it watches, so the mark stayed
    /// on the old word. The playhead says when it has been moved, through observation,
    /// and this listens once for the life of the page.
    func watchPlayhead() {
        guard !watchesPlayhead else { return }
        watchesPlayhead = true
        trackPlayhead()
    }

    private func trackPlayhead() {
        withObservationTracking {
            _ = playhead()
        } onChange: { [weak self] in
            // Told before the move is made, so the word is marked on the next turn.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.markWord()
                self.trackPlayhead()
            }
        }
    }

    /// Mark the word under the playhead in the playing line, when the line has word
    /// timings. A line without them keeps the line's own mark and no more: a guess
    /// at the word would be wrong more often than right.
    func markWord() {
        guard let index = playingIndex, index < wordsInLine.count,
              let times = lines[index].wordTimes, !wordsInLine[index].isEmpty,
              let textView = document?.textView else { return }

        // The last word that has begun by now.
        let now = playhead()
        var low = 0
        var high = times.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if times[middle] <= now { low = middle } else { high = middle - 1 }
        }
        guard low != playingWord else { return }

        let word = wordsInLine[index][low]
        textView.playingWord = NSRange(location: wordRanges[index].location + word.location, length: word.length)
        playingWord = low

        // The page follows the word while audio runs, a few rows at a time.
        if isFollowing, let range = textView.playingWord {
            show(range, keeping: 60)
        }
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

    /// The word being said: the words' font in bold.
    static let saidFont = NSFont.systemFont(ofSize: wordsFont.pointSize, weight: .bold)

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

    /// Bring a part of the page into view, smoothly, as Voice Memos scrolls its
    /// transcript along with the audio. The page used to jump to each new line, and
    /// the reader lost their place at every jump. With Reduce Motion it still jumps.
    ///
    /// - Parameter margin: Room kept between the part and the edge it comes in at. A
    ///   part too tall to fit with that room is shown from its top.
    func scroll(toShow rect: NSRect, keeping margin: CGFloat) {
        guard let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        let visible = clip.bounds
        var origin = visible.origin
        if rect.height + 2 * margin > visible.height || rect.minY - margin < visible.minY {
            origin.y = rect.minY - margin
        } else if rect.maxY + margin > visible.maxY {
            origin.y = rect.maxY + margin - visible.height
        }
        origin.y = max(0, min(origin.y, max(0, bounds.height - visible.height)))
        guard origin != visible.origin else { return }

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clip.animator().setBoundsOrigin(origin)
        }, completionHandler: {
            scrollView.reflectScrolledClipView(clip)
        })
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

// MARK: - Layout

/// Lays the transcript out, and draws the word being said in bold.
///
/// The bold word is drawn in the place of its regular glyphs, the few points it is
/// wider split between its two sides. Set as the font of the word, bold would widen
/// it in the layout and move every word after it, and the rows below, with each word
/// said. Drawn, nothing moves: the extra width is taken from the spaces beside it.
final class TranscriptLayoutManager: NSLayoutManager {
    /// The characters of the word being said.
    var saidWord: NSRange?
    /// The words' font in bold. Handed in by the text view, whose style this is.
    var saidFont = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let saidWord, let storage = textStorage, NSMaxRange(saidWord) <= storage.length else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        let word = glyphRange(forCharacterRange: saidWord, actualCharacterRange: nil)
        guard NSIntersectionRange(glyphsToShow, word).length > 0 else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }

        let before = NSRange(location: glyphsToShow.location, length: max(0, word.location - glyphsToShow.location))
        if before.length > 0 { super.drawGlyphs(forGlyphRange: before, at: origin) }

        drawSaidWord(saidWord, glyphs: word, at: origin)

        let after = NSRange(location: NSMaxRange(word), length: max(0, NSMaxRange(glyphsToShow) - NSMaxRange(word)))
        if after.length > 0 { super.drawGlyphs(forGlyphRange: after, at: origin) }
    }

    /// Draw the word in bold, centered on the slot its regular glyphs have in the row,
    /// on the row's own baseline.
    private func drawSaidWord(_ characters: NSRange, glyphs: NSRange, at origin: NSPoint) {
        guard let storage = textStorage,
              let container = textContainer(forGlyphAt: glyphs.location, effectiveRange: nil) else { return }
        let slot = boundingRect(forGlyphRange: glyphs, in: container)
        let row = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let baseline = location(forGlyphAt: glyphs.location).y

        let word = NSAttributedString(string: (storage.string as NSString).substring(with: characters), attributes: [
            .font: saidFont,
            .foregroundColor: NSColor.labelColor
        ])
        let x = origin.x + slot.minX - (word.size().width - slot.width) / 2
        let y = origin.y + row.minY + baseline
        // With no line-fragment option, the point is the baseline's start.
        word.draw(with: NSRect(x: x, y: y, width: 0, height: 0), options: [])
    }
}

// MARK: - Text View

/// The text view itself: aware of names and words, and editable only in the words.
final class TranscriptNSTextView: NSTextView, NSTextViewDelegate {
    private weak var coordinator: TranscriptCoordinator?

    /// The line the playhead is in, name and words, as a range of the text.
    var playingLine: NSRange? {
        didSet { if playingLine != oldValue { needsDisplay = true } }
    }

    /// The word being said, for a recording that kept its word timings. Set in bold
    /// by the layout manager, as Voice Memos sets it.
    var playingWord: NSRange? {
        didSet {
            guard playingWord != oldValue else { return }
            (layoutManager as? TranscriptLayoutManager)?.saidWord = playingWord
            needsDisplay = true
        }
    }

    /// Draw the playing line as one soft block.
    ///
    /// Drawn here, behind the text, as a rounded shape. As a background color on the
    /// characters it came out as hard-edged bands the width of the page, one for the
    /// name and one for each row of words, with the page showing between them.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer,
              let playingLine, NSMaxRange(playingLine) <= (textStorage?.length ?? 0) else { return }
        let origin = textContainerOrigin

        let glyphs = layoutManager.glyphRange(forCharacterRange: playingLine, actualCharacterRange: nil)
        var block = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        // The full measure, whatever the last row's length.
        block.origin.x = 0
        block.size.width = textContainer.size.width
        block = block.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -12, dy: -6)

        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: block, xRadius: 9, yRadius: 9).fill()
    }

    /// Built on the older text system on purpose. The word being said is drawn by the
    /// layout manager, and asking a new-system text view for its layout manager
    /// converts it mid-flight.
    static func make(coordinator: TranscriptCoordinator) -> TranscriptNSTextView {
        let storage = NSTextStorage()
        let layoutManager = TranscriptLayoutManager()
        layoutManager.saidFont = TranscriptStyle.saidFont
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        let textView = TranscriptNSTextView(frame: .zero, textContainer: container)
        textView.coordinator = coordinator
        textView.delegate = textView
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        // The words are the meeting's, and a correction is the user's. Nothing here
        // rewrites either on its own.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.importsGraphics = false
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

    // MARK: Corrections

    func textView(
        _ textView: NSTextView,
        shouldChangeTextInRanges affectedRanges: [NSValue],
        replacementStrings: [String]?
    ) -> Bool {
        // No strings means only attributes are changing, which is this view's own doing.
        guard let replacementStrings, let coordinator else { return true }
        let allowed = zip(affectedRanges, replacementStrings).allSatisfy { range, string in
            coordinator.allowsChange(in: range.rangeValue, to: string, in: textView)
        }
        if !allowed { NSSound.beep() }
        return allowed
    }

    func textDidChange(_ notification: Notification) {
        coordinator?.textChanged(in: self)
    }

    /// Words only. A paste from a web page would otherwise bring its fonts and colors
    /// into the transcript.
    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
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
