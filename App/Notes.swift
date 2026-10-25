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
                if assistant.armed, !LiveNotes.entries(assistant).isEmpty {
                    live
                } else {
                    header(title: "Notes", trailing: assistant.armed ? AnyView(LiveDot()) : AnyView(listenButton))
                    pastList
                }
            }
            .background(Color(.systemBackground))
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: UUID.self) { ConversationDetail(id: $0) }
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

    /// Who's in it: the faces looked at while it runs, else the conversation's members.
    private var livePeople: [String] {
        let faces = crm.live?.faces ?? []
        return faces.isEmpty ? assistant.members.map(\.id) : faces
    }

    private var liveTitle: String {
        let names = livePeople.map { crm.first($0) }
        return names.isEmpty ? "Conversation" : "Conversation with " + Self.list(names)
    }

    private var endButton: some View {
        Button { Task { await assistant.toggle() } } label: {
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

    /// One row per conversation. The CRM keeps one record per person, so records that started
    /// within two minutes of each other are the same conversation.
    struct Past: Identifiable {
        var id: UUID
        var people: [String]
        var started: Date
        var ended: Date?
    }

    private var past: [Past] {
        var rows: [Past] = []
        for conversation in crm.conversations.sorted(by: { $0.started > $1.started }) {
            if let last = rows.last, abs(last.started.timeIntervalSince(conversation.started)) < 120 {
                if !rows[rows.count - 1].people.contains(conversation.person) {
                    rows[rows.count - 1].people.append(conversation.person)
                }
            } else {
                rows.append(Past(id: conversation.id, people: [conversation.person],
                                 started: conversation.started, ended: conversation.ended))
            }
        }
        return rows
    }

    private var pastList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if past.isEmpty {
                    Text("Your conversations will show up here.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .padding(.horizontal, 20).padding(.top, 16)
                }
                ForEach(past) { row in
                    NavigationLink(value: row.id) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Conversation with " + Self.list(row.people.map { crm.first($0) }))
                                    .font(.system(size: 17, weight: .semibold, design: .serif))
                                    .foregroundStyle(.primary).lineLimit(2)
                                Text(row.started.formatted(date: .abbreviated, time: .shortened))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            faces(row.people, size: 28)
                        }
                        .padding(.horizontal, 20).padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 20)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Pieces

    private func header(title: String, trailing: AnyView) -> some View {
        HStack(alignment: .top) {
            Text(title).font(.system(size: 30, weight: .semibold, design: .serif))
                .lineLimit(2).minimumScaleFactor(0.7)
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

/// The live transcript as a text thread: each change of speaker flips the bubble to the other
/// side, with their name over the first bubble of their turn. Follows the newest line.
struct ChatTranscript: View {
    @Environment(Assistant.self) private var assistant

    var body: some View {
        let entries = LiveNotes.entries(assistant)
        let sides = Self.sides(entries)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    if entries.isEmpty {
                        Text("Listening for conversation").font(.callout).foregroundStyle(.tertiary)
                            .padding(.top, 24)
                    }
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        let right = sides[index]
                        let named = index == 0 || entries[index - 1].who != entry.who
                        VStack(alignment: right ? .trailing : .leading, spacing: 2) {
                            if named, !entry.who.isEmpty {
                                Text(entry.who).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.top, 6)
                            }
                            Text(entry.text)
                                .font(.body)
                                .foregroundStyle(right ? Color(.systemBackground) : Color.primary)
                                .opacity(entry.speaking ? 0.7 : 1)
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(right ? Color.primary : Color(.secondarySystemBackground),
                                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .frame(maxWidth: .infinity, alignment: right ? .trailing : .leading)
                        .padding(right ? .leading : .trailing, 56)
                        .id(entry.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            .onChange(of: entries.last?.text) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    /// Left for the first speaker, then the other side every time the speaker changes.
    static func sides(_ entries: [LiveNotes.Entry]) -> [Bool] {
        var right = false
        return entries.enumerated().map { index, entry in
            if index > 0, entries[index - 1].who != entry.who { right.toggle() }
            return right
        }
    }
}
