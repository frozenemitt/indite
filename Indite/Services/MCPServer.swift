#if os(macOS)
import Foundation
import SwiftData

/// Indite's meetings and dictations, read by an agent through the Model Context
/// Protocol.
///
/// The agent starts `Indite mcp` itself and talks to it over standard input and output,
/// one JSON-RPC message per line. Nothing listens on the network, and nothing is
/// written: the store is opened read-only, so the app can go on recording while an
/// agent reads.
///
/// The protocol is three requests — the handshake, the list of tools, a tool call — so
/// it is written out here rather than pulled in as a package.
@MainActor
struct MCPServer {
    private let context: ModelContext

    /// The protocol versions this server can answer in, newest first.
    private static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    init() throws {
        let schema = Schema(versionedSchema: MeetingSchemaV3.self)
        let config = ModelConfiguration(schema: schema, url: AppFolder.store, allowsSave: false)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: MeetingMigrationPlan.self,
            configurations: [config]
        )
        context = ModelContext(container)
    }

    /// Answer requests until the agent closes standard input.
    func run() {
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Not JSON"]])
                continue
            }
            // A notification has no id and gets no answer.
            guard let id = message["id"] else { continue }
            let method = message["method"] as? String ?? ""
            let params = message["params"] as? [String: Any] ?? [:]

            switch method {
            case "initialize":
                let asked = params["protocolVersion"] as? String ?? ""
                send(result(id, [
                    "protocolVersion": Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0],
                    "capabilities": ["tools": [:] as [String: Any]],
                    "serverInfo": ["name": "indite", "version": Bundle.main.shortVersion],
                    "instructions": "Read-only access to the meetings Indite recorded and the dictations it kept on this Mac."
                ]))
            case "ping":
                send(result(id, [:]))
            case "tools/list":
                send(result(id, ["tools": Self.tools]))
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                send(result(id, call(name, arguments)))
            default:
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "No method \(method)"]])
            }
        }
    }

    private func result(_ id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    // MARK: - Tools

    private static let tools: [[String: Any]] = [
        [
            "name": "list_meetings",
            "description": "Meetings recorded in Indite, newest first: id, title, start time, length, speakers, and whether a summary exists.",
            "inputSchema": schema([
                "limit": ["type": "integer", "description": "How many to return. Default 20."],
                "since": ["type": "string", "description": "Only meetings that started on or after this ISO 8601 date or time."]
            ])
        ],
        [
            "name": "get_meeting",
            "description": "One meeting in full: title, time, summary, and the transcript with speaker names and timestamps.",
            "inputSchema": schema([
                "id": ["type": "string", "description": "The meeting's id from list_meetings or search."]
            ], required: ["id"])
        ],
        [
            "name": "search",
            "description": "Find transcript lines and dictations containing every word of the query, ignoring case and accents. Newest first.",
            "inputSchema": schema([
                "query": ["type": "string", "description": "Words to look for."],
                "limit": ["type": "integer", "description": "How many matches to return. Default 30."]
            ], required: ["query"])
        ],
        [
            "name": "list_dictations",
            "description": "Recent dictations kept in Indite's history, newest first, with the app each one went to.",
            "inputSchema": schema([
                "limit": ["type": "integer", "description": "How many to return. Default 20."],
                "since": ["type": "string", "description": "Only dictations made on or after this ISO 8601 date or time."]
            ])
        ]
    ]

    private static func schema(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required]
    }

    private func call(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        let limit = max(1, arguments["limit"] as? Int ?? (name == "search" ? 30 : 20))
        let since = (arguments["since"] as? String).flatMap(Self.date(from:))
        let text: String
        switch name {
        case "list_meetings":
            text = listMeetings(limit: limit, since: since)
        case "get_meeting":
            guard let id = arguments["id"] as? String, let meeting = meeting(id: id) else {
                return failure("No meeting has that id. list_meetings gives the ids.")
            }
            text = transcript(of: meeting)
        case "search":
            let words = (arguments["query"] as? String ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
            guard !words.isEmpty else { return failure("The query is empty.") }
            text = search(words, limit: limit)
        case "list_dictations":
            text = listDictations(limit: limit, since: since)
        default:
            return failure("No tool named \(name).")
        }
        return ["content": [["type": "text", "text": text]]]
    }

    private func failure(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": true]
    }

    // MARK: - Reading

    /// Meetings not in Recently Deleted, newest first.
    private func meetings() -> [Meeting] {
        let descriptor = FetchDescriptor<Meeting>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func dictations() -> [Dictation] {
        let descriptor = FetchDescriptor<Dictation>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// A meeting is known by its start time, which no two meetings share and which
    /// survives as long as the meeting does.
    private func meeting(id: String) -> Meeting? {
        guard let start = Self.date(from: id) else { return nil }
        return meetings().first { abs($0.startedAt.timeIntervalSince(start)) < 1 }
    }

    private func listMeetings(limit: Int, since: Date?) -> String {
        let found = meetings().filter { since == nil || $0.startedAt >= since! }.prefix(limit)
        guard !found.isEmpty else { return "No meetings." }
        return found.map { meeting in
            var line = "\(Self.id(meeting.startedAt)) · \(meeting.title) · \(MeetingExporter.durationLabel(meeting.duration))"
            let speakers = meeting.sortedSpeakers.map(\.resolvedName)
            if !speakers.isEmpty { line += " · speakers: " + speakers.joined(separator: ", ") }
            if meeting.summary?.isEmpty == false { line += " · has summary" }
            return line
        }.joined(separator: "\n")
    }

    private func transcript(of meeting: Meeting) -> String {
        var text = "# \(meeting.title)\n"
        text += "Started \(Self.id(meeting.startedAt)), \(MeetingExporter.durationLabel(meeting.duration)) long.\n"
        if let summary = meeting.summary, !summary.isEmpty {
            text += "\n## Summary\n\(summary)\n"
        }
        text += "\n## Transcript\n"
        let lines = meeting.orderedUtterances
        if lines.isEmpty {
            text += meeting.rawTranscript
        } else {
            text += lines.map { "[\($0.timestampLabel)] \(meeting.displayName(forSpeakerId: $0.speakerId)): \($0.text)" }
                .joined(separator: "\n")
        }
        return text
    }

    private func search(_ words: [String], limit: Int) -> String {
        func matches(_ text: String) -> Bool {
            words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }

        // Meetings and dictations interleaved by time, so the newest match leads
        // whichever kind it is.
        var found: [(Date, String)] = []
        for meeting in meetings() {
            let heading = "meeting \(Self.id(meeting.startedAt)) «\(meeting.title)»"
            let lines = meeting.orderedUtterances
            if lines.isEmpty {
                if matches(meeting.rawTranscript) {
                    found.append((meeting.startedAt, "\(heading): \(meeting.rawTranscript.prefix(300))"))
                }
            } else {
                for line in lines where matches(line.text) {
                    let name = meeting.displayName(forSpeakerId: line.speakerId)
                    found.append((meeting.startedAt.addingTimeInterval(line.start),
                                  "\(heading) [\(line.timestampLabel)] \(name): \(line.text)"))
                }
            }
        }
        for dictation in dictations() where matches(dictation.text) {
            found.append((dictation.createdAt, "dictation \(Self.id(dictation.createdAt))\(Self.into(dictation)): \(dictation.text)"))
        }

        guard !found.isEmpty else { return "Nothing contains all of: \(words.joined(separator: " "))" }
        return found.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1).joined(separator: "\n")
    }

    private func listDictations(limit: Int, since: Date?) -> String {
        let found = dictations().filter { since == nil || $0.createdAt >= since! }.prefix(limit)
        guard !found.isEmpty else { return "No dictations kept. History may be switched off in Indite's settings." }
        return found.map { "\(Self.id($0.createdAt))\(Self.into($0)): \($0.text)" }.joined(separator: "\n")
    }

    private static func into(_ dictation: Dictation) -> String {
        dictation.destination.map { " into \($0)" } ?? ""
    }

    // MARK: - Dates

    /// Times in the Mac's own time zone with the offset spelled out, so an agent reads
    /// "14:02" as the user lived it.
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter
    }()

    private static func id(_ date: Date) -> String { formatter.string(from: date) }

    /// A full timestamp, or a bare date taken as its start in the Mac's time zone.
    private static func date(from string: String) -> Date? {
        if let date = formatter.date(from: string) { return date }
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        day.timeZone = .current
        return day.date(from: string)
    }
}

private extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}
#endif
