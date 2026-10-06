import AppIntents
import CoreSpotlight
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

struct HelpArticleQuery: EntityQuery {
    func entities(for identifiers: [HelpArticleEntity.ID]) async throws -> [HelpArticleEntity] {
        identifiers.compactMap(HelpArticle.article(id:)).map(HelpArticleEntity.init)
    }

    func suggestedEntities() async throws -> [HelpArticleEntity] {
        HelpArticle.all.map(HelpArticleEntity.init)
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
    /// Replaces whatever an earlier version indexed, so an article that was removed or
    /// renamed does not linger in Spotlight or in Siri's answers.
    static func refresh() async {
        let index = CSSearchableIndex.default()
        do {
            try await index.deleteAppEntities(ofType: HelpArticleEntity.self)
            try await index.indexAppEntities(HelpArticle.all.map(HelpArticleEntity.init))
            Log.app.notice("Help: indexed \(HelpArticle.all.count, privacy: .public) articles")
        } catch {
            Log.app.error("Help: indexing failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
