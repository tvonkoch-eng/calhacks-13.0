import SwiftUI

// MARK: - Notes

/// While the mic is on: the conversation as a chat, speakers bouncing left and right, under a
/// serif "Conversation with …" and the faces in it. End conversation (top right) saves it and
/// drops back to the list of past conversations. Mic off: just "Notes" and that list.
struct NotesHome: View {
    @Environment(Assistant.self) private var assistant
    @Environment(CRM.self) private var crm
    @Environment(Store.self) private var store
    @State private var query = ""

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
        let names = livePeople.map { crm.first($0) }
        let count = Transcripts.lines(assistant).count
        return VStack(alignment: .leading, spacing: 0) {
            header(title: liveTitle, trailing: AnyView(endButton))
            faces(livePeople).padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
            Divider()
            // Top half: the transcript as it's heard. Bottom half: an AI summary of it so far.
            GeometryReader { geo in
                VStack(spacing: 0) {
                    ChatTranscript().frame(height: geo.size.height / 2)
                    Divider()
                    liveSummary.frame(maxHeight: .infinity)
                }
            }
        }
        .task(id: count) {
            await Transcripts.shared.refreshSummary(assistant, crm: crm, with: names.isEmpty ? nil : Self.list(names))
        }
    }

    private var liveSummary: some View {
        let text = Transcripts.shared.liveSummary
        return VStack(alignment: .leading, spacing: 8) {
            Text("Summary").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                Text(text.isEmpty ? "Summarizes as the conversation goes on." : text)
                    .font(.system(size: 17, design: .serif))
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
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
        let q = query.lowercased()
        let past = Transcripts.shared.saved.filter { row in
            q.isEmpty || row.people.contains { crm.name($0).lowercased().contains(q) }
                || row.lines.contains { $0.text.lowercased().contains(q) }
        }
        // Same look as People: search, a "+ New" row, then 46 pt rows with a hairline under each.
        return List {
            SearchField(text: $query, prompt: "Search notes, people, what was said")
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 6, trailing: 16))
                .listRowSeparator(.hidden)
            Button { Transcripts.shared.start(assistant) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(Color(.secondarySystemBackground), in: Circle())
                    Text("New recording").font(.body.weight(.medium))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
            .listRowSeparator(.hidden)
            if past.isEmpty {
                Text(query.isEmpty ? "Your conversations will show up here." : "Nothing matches \u{201C}\(query)\u{201D}.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
            ForEach(past) { row in
                NavigationLink(value: row.id) {
                    // The notes card: serif title, when, and the faces on the right.
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
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                // Swipe left to discard.
                .swipeActions(edge: .trailing) {
                    Button("Delete", systemImage: "trash", role: .destructive) { Transcripts.shared.delete(row.id) }
                }
            }
        }
        .listStyle(.plain)
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
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

/// The live transcript as a text thread: Person A and C on the right, B and D on the left, the name
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

/// One line of a kept transcript, already labeled "Person A/B/C/D"; `me` means drawn on the right.
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
    private var lastHere = Date()
    /// When nobody was last in front of the glasses; nil while someone is.
    @ObservationIgnored private var absentSince: Date?
    /// How long nobody may be in front of the glasses before the conversation is over (a few
    /// seconds away is not the end of it, and clearing the lens on a flicker is worse than waiting).
    private static let absentReset: TimeInterval = 20
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
            // Nobody in front of the glasses for a while, not just a glance away, ends it.
            if here { absentSince = nil } else if absentSince == nil { absentSince = Date() }
            guard here, Date().timeIntervalSince(assistant.lastLoud) < 5 else {
                // Room noise with nobody to talk to: let it go, don't start a conversation.
                if let gone = absentSince, Date().timeIntervalSince(gone) > Self.absentReset,
                   Date().timeIntervalSince(first.at) > 8, assistant.aid.partial.isEmpty {
                    assistant.endConversation(trigger: "nobody in front of the glasses for \(Int(Date().timeIntervalSince(gone))) s")
                }
                return
            }
            started = first.at
            lastHere = Date()
        }
        // Once going, every line counts. It ends after 30 s of quiet, or 30 s with nobody in front.
        if assistant.glasses?.someoneHere ?? false { lastHere = Date() }
        if Date().timeIntervalSince(lastHere) >= Self.quiet {
            end(assistant)
            return
        }
        for id in faces where !people.contains(id) { people.append(id) }
        if assistant.aid.partial.isEmpty, let last = lines.last, Date().timeIntervalSince(last.at) >= Self.quiet {
            end(assistant)
        }
    }

    /// "+ New recording": start a conversation now, mic on, without waiting for a face.
    func start(_ assistant: Assistant) {
        if !assistant.armed { Task { await assistant.toggle() } }
        if started == nil { started = Date(); liveSummary = ""; summarizedLines = 0 }
        lastHere = Date()
    }

    /// The live summary of the conversation so far, refreshed at most every `summaryEvery` seconds
    /// and only when it has grown. Uses the recap model; a failed call keeps the last summary.
    private(set) var liveSummary = ""
    @ObservationIgnored private var summaryAt = Date.distantPast
    @ObservationIgnored private var summarizedLines = 0
    static let summaryEvery: TimeInterval = 45

    func refreshSummary(_ assistant: Assistant, crm: CRM, with: String?) async {
        guard active, let model = crm.models.first else { return }
        let lines = Self.lines(assistant)
        guard lines.count >= 3, lines.count > summarizedLines + 2 else { return }
        let wait = Self.summaryEvery - Date().timeIntervalSince(summaryAt)
        if wait > 0 {
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
        }
        summaryAt = Date()
        summarizedLines = lines.count
        let input = Recap.Input(wearer: crm.wearer, when: started ?? Date(), with: with, name: nil,
                                known: [], owed: [], transcript: lines.map { "\($0.who): \($0.text)" })
        do {
            let result = try await Recap.ask(input, model: model)
            if let text = result.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { liveSummary = text }
        } catch {
            // Keep the last summary; the next growth retries.
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
        liveSummary = ""
        summarizedLines = 0
        assistant.endConversation(trigger: "ended from Notes")
    }

    /// Every voice is Person A, B, C, D in order of first speaking: A and C on the right, B and D
    /// on the left. On the glasses mic the wearer (the loud voice) is held as Person A. A line's
    /// label is decided once, when it's final, and never redrawn, so nobody changes side or name
    /// mid-conversation; words still being heard aren't shown until they're final.
    private static var letters: [String: Int] = [:]
    private static var frozen: [Int: (String, Bool)] = [:]

    static func lines(_ assistant: Assistant) -> [SavedLine] {
        let spoken = assistant.aid.lines.filter { !$0.command }
        if spoken.isEmpty { letters = [:]; frozen = [:] }
        if letters.isEmpty, assistant.mic != .phone { letters["me"] = 0 }
        return spoken.map { line in
            if frozen[line.id] == nil {
                let key = line.speaker == Assistant.me ? "me" : (assistant.voices[line.id] ?? line.speaker ?? "?")
                let index = letters[key] ?? letters.count
                letters[key] = index
                frozen[line.id] = ("Person " + String(UnicodeScalar(UInt8(65 + min(index, 25)))), index % 2 == 0)
            }
            let (who, right) = frozen[line.id]!
            return SavedLine(id: "\(line.id)", who: who, text: line.text, me: right)
        }
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

/// A and C on the right, B and D on the left, the name over the first bubble of each turn.
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
