import AppIntents
import CoreSpotlight
import CryptoKit
import os

/// A help article as Siri, Spotlight and Shortcuts see it.
///
/// Indexed into the system's semantic index, so Siri can find an article by what it
/// means rather than by its exact words, and answer questions from it.
struct HelpArticleEntity: IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Indite Help Article"
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
        DisplayRepresentation(title: "\(title)", subtitle: "Indite Help")
    }

    /// The whole article goes into the index, not only its title, so a question
    /// worded nothing like the title still reaches it.
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = title
        attributes.contentDescription = text
        attributes.textContent = text
        // The first name as well, for anyone who still searches for it.
        attributes.keywords = ["Indite", "Nscribe", "help", "dictation"]
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

/// "Search Indite for the dictation key." Siri hands the words to the Help window,
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
    static let description = IntentDescription("Opens an article in Indite's Help window.")

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
    static let title: LocalizedStringResource = "Show Indite Help"
    static let description = IntentDescription("Opens Indite's Help window.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        #if os(macOS)
        HelpNavigator.shared.ask()
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
}
