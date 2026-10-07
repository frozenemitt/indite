import Foundation
import SwiftData

/// The versions of the meeting store.
///
/// Schema versions exist so that changing a model is a deliberate act with a stated
/// migration, rather than a silent gamble on whether SwiftData can infer one. Adding
/// `recordedDuration` without this cost a recorded meeting.
///
/// The newest version lists the live model classes, so it describes whatever shape
/// those classes have today. Every older version holds its own copies of the classes
/// as they were, nested inside it. That is why changing a model takes these steps, in
/// this order:
///
/// 1. Copy each model class as it stands into the newest version as a nested type,
///    and list those copies in its `models` instead of the live classes. That version
///    then keeps describing the shape already on disk.
/// 2. Add the next version with a new `versionIdentifier`, listing the live classes,
///    and change the live classes to the new shape.
/// 3. List the new version in `MeetingMigrationPlan.schemas`, point the container's
///    `Schema(versionedSchema:)` at it, and add a `MigrationStage` from the one before.
///    A lightweight stage covers added properties with defaults, added models and
///    renames; anything that reinterprets existing data needs a custom one.
///
/// Skipping the first step leaves two versions describing the same classes. SwiftData
/// then rejects the plan for holding two versions with the same checksum, and the
/// store does not open.
///
/// Before a build with a new version first opens a real store, try the migration on a
/// copy of that store, and keep a backup of the original.

// MARK: - Version 1

/// The store as it was until 2026-10-01: meetings, their lines and speakers, and the
/// dictation history.
///
/// The classes below are the models as they stood then, stored properties only.
/// Nothing uses them but the migration, which reads the old shape through them.
enum MeetingSchemaV1: VersionedSchema {
    /// The version recorded in the stores already on disk. It stays as it is.
    ///
    /// 1.1.0 added `Meeting.audioFileName` and 1.2.0 added the `Dictation` model, both
    /// by editing this version in place, before versions were kept apart.
    static var versionIdentifier: Schema.Version { Schema.Version(1, 2, 0) }

    static var models: [any PersistentModel.Type] {
        [Meeting.self, Utterance.self, MeetingSpeaker.self, Dictation.self]
    }

    @Model
    final class Meeting {
        var title: String
        var startedAt: Date
        var endedAt: Date?
        var rawTranscript: String
        var summary: String?
        var recordedDuration: TimeInterval = 0
        var audioFileName: String?

        @Relationship(deleteRule: .cascade, inverse: \Utterance.meeting)
        var utterances: [Utterance]

        @Relationship(deleteRule: .cascade, inverse: \MeetingSpeaker.meeting)
        var speakers: [MeetingSpeaker]

        init(title: String, startedAt: Date) {
            self.title = title
            self.startedAt = startedAt
            self.endedAt = nil
            self.rawTranscript = ""
            self.summary = nil
            self.utterances = []
            self.speakers = []
        }
    }

    @Model
    final class Utterance {
        var speakerId: String
        var text: String
        var start: TimeInterval
        var end: TimeInterval
        var meeting: Meeting?

        init(speakerId: String, text: String, start: TimeInterval, end: TimeInterval) {
            self.speakerId = speakerId
            self.text = text
            self.start = start
            self.end = end
        }
    }

    @Model
    final class MeetingSpeaker {
        var speakerId: String
        var name: String
        var generatedLabel: String
        var meeting: Meeting?

        init(speakerId: String, generatedLabel: String, name: String) {
            self.speakerId = speakerId
            self.generatedLabel = generatedLabel
            self.name = name
        }
    }

    @Model
    final class Dictation {
        var text: String
        var rawText: String?
        var createdAt: Date
        var destination: String?
        var promptName: String?

        init(text: String, createdAt: Date) {
            self.text = text
            self.createdAt = createdAt
        }
    }
}

// MARK: - Version 2

/// Adds `Meeting.deletedAt`, the date a meeting was moved to Recently Deleted.
enum MeetingSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [Meeting.self, Utterance.self, MeetingSpeaker.self, Dictation.self]
    }
}

// MARK: - Migration

/// How the meeting store moves between schema versions.
enum MeetingMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [MeetingSchemaV1.self, MeetingSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [
            // One optional property added, nil for every meeting already there.
            .lightweight(fromVersion: MeetingSchemaV1.self, toVersion: MeetingSchemaV2.self)
        ]
    }
}
