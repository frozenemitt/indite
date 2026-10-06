import AppIntents
import CoreSpotlight
import CryptoKit
import os

/// A help article as Siri, Spotlight and Shortcuts see it.
///
/// Indexed into the system's semantic index, so Siri can find an article by what it
/// means rather than by its exact words, and answer questions from it.
struct HelpArticleEntity: IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Nscribe Help Article"
    static let defaultQuery = HelpArticleQuery()

    let id: String

    @Property(title: "Title")
    var title: String

    @Property(title: "Text")
    var text: String

    init(_ article: HelpArticle) {
        id = article.id
        title = article.title
        text = article.body
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "Nscribe Help")
    }

    /// The whole article goes into the index, not only its title, so a question
    /// worded nothing like the title still reaches it.
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = title
        attributes.contentDescription = text
        attributes.textContent = text
        attributes.keywords = ["Nscribe", "help", "dictation"]
        return attributes
    }
}

/// Spotlight asks this to index the articles again, for instance after it rebuilds its
/// index. Without it Spotlight logged "No IndexedEntityQuery found" and kept whatever it
/// had.
struct HelpArticleQuery: IndexedEntityQuery {
    func entities(for identifiers: [HelpArticleEntity.ID]) async throws -> [HelpArticleEntity] {
        identifiers.compactMap(HelpArticle.article(id:)).map(HelpArticleEntity.init)
    }

    func suggestedEntities() async throws -> [HelpArticleEntity] {
        HelpArticle.all.map(HelpArticleEntity.init)
    }

    func reindexEntities(for identifiers: [HelpArticleEntity.ID],
                         indexDescription: CSSearchableIndexDescription) async throws {
        let entities = identifiers.compactMap(HelpArticle.article(id:)).map(HelpArticleEntity.init)
        try await CSSearchableIndex.default().indexAppEntities(entities)
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        try await CSSearchableIndex.default().indexAppEntities(HelpArticle.all.map(HelpArticleEntity.init))
    }
}

/// "Search Nscribe for the dictation key." Siri hands the words to the Help window,
/// which shows the articles that match. This is the system's own search schema, which
/// Siri understands in any wording, unlike a custom phrase.
@AppIntent(schema: .system.searchInApp)
struct SearchHelpIntent: ShowInAppSearchResultsIntent {
    static let searchScopes: [StringSearchScope] = [.general]

    var criteria: StringSearchCriteria

    @MainActor
    func perform() async throws -> some IntentResult {
        #if os(macOS)
        HelpNavigator.shared.search(criteria.term)
        #endif
        return .result()
    }
}

/// Opens an article in the Help window. Spotlight runs this when a person picks an
/// article from its results, and Siri when asked to show one.
struct OpenHelpArticleIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Help Article"
    static let description = IntentDescription("Opens an article in Nscribe's Help window.")

    @Parameter(title: "Article")
    var target: HelpArticleEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        #if os(macOS)
        HelpNavigator.shared.show(target.id)
        #endif
        return .result()
    }
}

/// Opens the Help window at its first article.
struct ShowHelpIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Nscribe Help"
    static let description = IntentDescription("Opens Nscribe's Help window.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        #if os(macOS)
        HelpNavigator.shared.show(nil)
        #endif
        return .result()
    }
}

enum HelpIndex {
    private static let versionKey = "helpIndexVersion"

    /// A fingerprint of every article's words, so the index is rebuilt only when an
    /// article changed. Rebuilding at every launch threw away whatever Spotlight had
    /// done with the articles since, and Siri's semantic index may need longer than
    /// the time between two installs.
    private static var contentVersion: String {
        let text = HelpArticle.all.map { $0.id + "\u{1F}" + $0.title + "\u{1F}" + $0.body }
            .joined(separator: "\u{1E}")
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Indexes the articles if they changed since the last time, replacing the old
    /// ones so a removed or renamed article does not linger in Spotlight or Siri.
    static func refresh() async {
        let version = contentVersion
        guard UserDefaults.standard.string(forKey: versionKey) != version else {
            Log.app.notice("Help: articles unchanged, index left as it is")
            return
        }
        let index = CSSearchableIndex.default()
        do {
            try await index.deleteAppEntities(ofType: HelpArticleEntity.self)
            try await index.indexAppEntities(HelpArticle.all.map(HelpArticleEntity.init))
            UserDefaults.standard.set(version, forKey: versionKey)
            Log.app.notice("Help: indexed \(HelpArticle.all.count, privacy: .public) articles")
        } catch {
            Log.app.error("Help: indexing failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Probe

    // Diagnostic, for slice 1 only: whether the articles are in Spotlight's index, and
    // whether a question worded unlike any article finds the right one by meaning.
    // Remove once the question is settled. See Docs/help-and-siri.md.

    /// Each question, and the article that should answer it. None shares the article's
    /// key words, so only a semantic match finds it.
    private static let probes: [(question: String, expected: String)] = [
        // A control that shares the article's words: if this misses too, the query
        // is at fault, not the index.
        ("emoji picker", "globe-key-emoji"),
        ("why does pressing the world key show smileys", "globe-key-emoji"),
        ("use a different shortcut to start talking", "dictation-key"),
        ("capture what the other people say on a video call", "call-audio")
    ]

    /// Runs the probe at launch and every ten minutes for an hour.
    static func probeRepeatedly() async {
        // Loads what semantic search needs; Apple asks for it before the first query.
        CSUserQuery.prepare()
        for round in 0..<7 {
            if round > 0 { try? await Task.sleep(for: .seconds(600)) }
            await probe(round: round)
        }
    }

    private static func probe(round: Int) async {
        let lexical = await search(nil, semantic: false)
        Log.app.notice("Help probe \(round, privacy: .public): \(lexical.count, privacy: .public) articles in the index: \(lexical.joined(separator: ", "), privacy: .public)")
        for probe in probes {
            let found = await search(probe.question, semantic: true)
            // Spotlight prefixes each identifier with the entity's type name.
            let ids = found.map { $0.split(separator: "/").last.map(String.init) ?? $0 }
            let hit = ids.first == probe.expected ? "HIT" : (ids.contains(probe.expected) ? "found, not first" : "MISS")
            Log.app.notice("Help probe \(round, privacy: .public): \(hit, privacy: .public) for \"\(probe.question, privacy: .public)\" -> \(found.joined(separator: ", "), privacy: .public)")
        }
    }

    /// The identifiers of the articles a query finds, best first. With no words, every
    /// article in the index.
    private static func search(_ words: String?, semantic: Bool) async -> [String] {
        await withCheckedContinuation { continuation in
            var identifiers: [String] = []
            let query: CSSearchQuery
            if let words {
                let context = CSUserQueryContext()
                context.fetchAttributes = ["title"]
                context.disableSemanticSearch = !semantic
                context.enableRankedResults = true
                context.maxResultCount = 10
                query = CSUserQuery(userQueryString: words, userQueryContext: context)
            } else {
                let context = CSSearchQueryContext()
                context.fetchAttributes = ["title"]
                query = CSSearchQuery(queryString: "title == \"*\"", queryContext: context)
            }
            query.foundItemsHandler = { items in
                identifiers += items.map { $0.uniqueIdentifier }
            }
            query.completionHandler = { error in
                if let error {
                    Log.app.error("Help probe: query failed: \(error.localizedDescription, privacy: .public)")
                }
                continuation.resume(returning: identifiers)
            }
            query.start()
        }
    }
}
