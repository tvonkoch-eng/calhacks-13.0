import SwiftUI

// MARK: - Notes

/// While the mic is on: the conversation as a chat, speakers bouncing left and right, under a
/// serif "Conversation with …" and the faces in it. End conversation (top right) saves it and
/// drops back to the list of past conversations. Mic off: just "Notes" and that list.
struct NotesHome: View {
    @Environment(Assistant.self) private var assistant
    @Environment(CRM.self) private var crm
    @Environment(Store.self) private var store

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Live only once speech is heard: the mic listening to a quiet room is still Notes.
                if assistant.armed, Transcripts.shared.active {
                    live
                } else {
                    header(title: "Notes", trailing: assistant.armed ? AnyView(EmptyView()) : AnyView(listenButton))
                    pastList
                }
            }
            .background(Color(.systemBackground))
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: UUID.self) { id in
                if let kept = Transcripts.shared.saved.first(where: { $0.id == id }) { SavedTranscriptView(conversation: kept) }
            }
        }
    }

    // MARK: Live

    private var live: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(title: liveTitle, trailing: AnyView(endButton))
            faces(livePeople).padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
            Divider()
            ChatTranscript()
        }
    }

    /// Everyone recognised since the conversation began, added as they appear, until it ends.
    private var livePeople: [String] {
        var ids = Transcripts.shared.people
        for id in (crm.live?.faces ?? []) + assistant.members.map(\.id) where !ids.contains(id) { ids.append(id) }
        return ids
    }

    private var liveTitle: String {
        let names = livePeople.map { crm.first($0) }
        return names.isEmpty ? "Conversation" : "Conversation with " + Self.list(names)
    }

    private var endButton: some View {
        Button { Transcripts.shared.end(assistant) } label: {
            Text("End conversation").font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.systemBackground))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color.primary, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var listenButton: some View {
        Button { Task { await assistant.toggle() } } label: {
            Label("Listen", systemImage: "mic").font(.footnote.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color(.secondarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Past

    private var pastList: some View {
        let past = Transcripts.shared.saved
        return List {
                if past.isEmpty {
                    Text("Your conversations will show up here.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }
                ForEach(past) { row in
                    NavigationLink(value: row.id) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.people.isEmpty ? "Conversation"
                                     : "Conversation with " + Self.list(row.people.map { crm.first($0) }))
                                    .font(.system(size: 17, weight: .semibold, design: .serif))
                                    .foregroundStyle(.primary).lineLimit(2)
                                Text(row.started.formatted(date: .abbreviated, time: .shortened))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            faces(row.people, size: 28)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    }
                    // Swipe left to discard.
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) { Transcripts.shared.delete(row.id) }
                    }
                }
        }
        .listStyle(.plain)
        .scrollIndicators(.hidden)
    }

    // MARK: Pieces

    private func header(title: String, trailing: AnyView) -> some View {
        HStack(alignment: .top) {
            // Same title as People: 34 pt serif, 20 pt in, 10 pt down.
            Text(title).font(.system(size: 34, weight: .semibold, design: .serif))
                .lineLimit(2).minimumScaleFactor(0.6)
            Spacer(minLength: 8)
            trailing.padding(.top, 6)
        }
        .padding(.horizontal, 20).padding(.top, 10)
    }

    private func faces(_ ids: [String], size: CGFloat = 36) -> some View {
        HStack(spacing: -size * 0.2) {
            ForEach(ids.prefix(5), id: \.self) { id in
                if let person = person(id) {
                    Avatar(person: person, size: size)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                }
            }
        }
    }

    private func person(_ id: String) -> Person? {
        store.contacts.first { $0.id == id } ?? crm.contacts.first { $0.id == id }.map { crm.person($0) }
    }

    /// "Mirabelle", "Mirabelle & Avi", "Mirabelle, Avi, & Toby".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        case 2: "\(names[0]) & \(names[1])"
        default: names.dropLast().joined(separator: ", ") + ", & " + names.last!
        }
    }
}

/// The live transcript as a text thread: Me on the right, Person A, B, C on the left, the name
/// over the first bubble of each turn. Follows the newest line.
struct ChatTranscript: View {
    @Environment(Assistant.self) private var assistant

    var body: some View {
        let lines = Transcripts.lines(assistant)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        ChatBubble(line: line, named: index == 0 || lines[index - 1].who != line.who).id(line.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            .onChange(of: lines.last?.text) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

// MARK: - Transcripts

/// One line of a kept transcript, already labeled: "Me" or "Person A/B/C".
struct SavedLine: Codable, Identifiable, Equatable {
    var id: String
    var who: String
    var text: String
    var me: Bool
    var speaking = false
}

struct SavedConversation: Codable, Identifiable, Equatable {
    var id: UUID
    var started: Date
    var ended: Date
    /// Everyone face ID put in it, in order of first sighting.
    var people: [String]
    var lines: [SavedLine]
}

/// Every conversation's transcript, kept on the phone (Documents/transcripts.json). A conversation
/// runs from the first line heard until it's ended by hand or goes quiet for 30 s; then it's saved
/// and the next one starts with the next words.
@MainActor @Observable final class Transcripts {
    static let shared = Transcripts()
    static let quiet: TimeInterval = 30

    private(set) var saved: [SavedConversation] = []
    /// The live conversation's people, added as they're recognised, until it ends.
    private(set) var people: [String] = []
    private var started: Date?
    /// A conversation is running. One starts only when someone is in front of the glasses and a
    /// line is loud enough to be the wearer talking; until then what the mic hears is dropped.
    var active: Bool { started != nil }

    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("transcripts.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.url),
           let kept = try? JSONDecoder().decode([SavedConversation].self, from: data) { saved = kept }
    }

    /// Once a second while listening.
    func tick(_ assistant: Assistant, faces: [String]) {
        let lines = assistant.aid.lines.filter { !$0.command }
        guard let first = lines.first else { return }
        if started == nil {
            let here = assistant.glasses?.someoneHere ?? false
            guard here, Date().timeIntervalSince(assistant.lastLoud) < 5 else {
                // Room noise with nobody to talk to: let it go, don't start a conversation.
                if Date().timeIntervalSince(first.at) > 8, assistant.aid.partial.isEmpty { assistant.endConversation() }
                return
            }
            started = first.at
        }
        for id in faces where !people.contains(id) { people.append(id) }
        if assistant.aid.partial.isEmpty, let last = lines.last, Date().timeIntervalSince(last.at) >= Self.quiet {
            end(assistant)
        }
    }

    func delete(_ id: UUID) {
        saved.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: Self.url, options: .atomic) }
    }

    func end(_ assistant: Assistant) {
        let lines = Self.lines(assistant).filter { !$0.speaking }
        if !lines.isEmpty {
            let start = started ?? assistant.aid.lines.first?.at ?? Date()
            saved.insert(SavedConversation(id: UUID(), started: start, ended: Date(), people: people, lines: lines), at: 0)
            if let data = try? JSONEncoder().encode(saved) { try? data.write(to: Self.url, options: .atomic) }
        }
        people = []
        started = nil
        assistant.endConversation()
    }

    /// The wearer is "Me" (their voice is told apart by loudness and the glasses' own mic); every
    /// other voice Muse separates is Person A, B, C in order of first speaking.
    static func lines(_ assistant: Assistant) -> [SavedLine] {
        var letters: [String: String] = [:]
        func person(_ label: String?) -> String {
            let key = label ?? "?"
            if let known = letters[key] { return known }
            let letter = "Person " + String(UnicodeScalar(UInt8(65 + min(letters.count, 25))))
            letters[key] = letter
            return letter
        }
        var out = assistant.aid.lines.filter { !$0.command }.map { line in
            line.speaker == Assistant.me
                ? SavedLine(id: "\(line.id)", who: "Me", text: line.text, me: true)
                : SavedLine(id: "\(line.id)", who: person(assistant.voices[line.id] ?? line.speaker), text: line.text, me: false)
        }
        let partial = assistant.aid.partial
        if !partial.isEmpty {
            let mine = assistant.meSpeaking
            let other = assistant.aid.lines.last { $0.speaker != Assistant.me && !$0.command }.flatMap { assistant.voices[$0.id] ?? $0.speaker }
            out.append(SavedLine(id: "live", who: mine ? "Me" : person(other), text: partial, me: mine, speaking: true))
        }
        // The iPhone mic can't tell the wearer by volume: everyone is Person A, B, …, and the
        // bubbles just switch sides whenever the speaker does.
        if assistant.mic == .phone {
            var right = false
            for index in out.indices {
                if index > 0, out[index - 1].who != out[index].who { right.toggle() }
                out[index].me = right
            }
        }
        return out
    }
}

/// A kept conversation, read back as the same chat it was live.
struct SavedTranscriptView: View {
    let conversation: SavedConversation

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(Array(conversation.lines.enumerated()), id: \.element.id) { index, line in
                    ChatBubble(line: line, named: index == 0 || conversation.lines[index - 1].who != line.who)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .navigationTitle(conversation.started.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Me on the right, everyone else on the left, the name over the first bubble of each turn.
struct ChatBubble: View {
    let line: SavedLine
    let named: Bool

    var body: some View {
        VStack(alignment: line.me ? .trailing : .leading, spacing: 2) {
            if named {
                Text(line.who).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.top, 6)
            }
            Text(line.text)
                .font(.body)
                .foregroundStyle(line.me ? Color(.systemBackground) : Color.primary)
                .opacity(line.speaking ? 0.7 : 1)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(line.me ? Color.primary : Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: line.me ? .trailing : .leading)
        .padding(line.me ? .leading : .trailing, 56)
    }
}
