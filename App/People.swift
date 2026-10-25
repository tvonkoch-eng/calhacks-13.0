import PhotosUI
import SwiftUI

/// Two apps in one: People, the consumer side (a personal CRM with live notes), and Dev, the
/// phone screen as it was (lens mirror, stream controls, every knob).
struct RootView: View {
    @State private var tab = Tab.notes
    enum Tab { case notes, people, dev }

    var body: some View {
        TabView(selection: $tab) {
            NotesHome()
                .tabItem { Label("Notes", systemImage: "text.bubble") }
                .tag(Tab.notes)
            PeopleHome()
                .tabItem { Label("People", systemImage: "person.2") }
                .tag(Tab.people)
            HomeView()
                .tabItem { Label("Dev", systemImage: "wrench.and.screwdriver") }
                .tag(Tab.dev)
        }
        .tint(.primary)
        #if DEBUG
        .onAppear { if ProcessInfo.processInfo.environment["PREVIEW_TAB"] == "dev" { tab = .dev } }
        #endif
    }
}

// MARK: - Home

/// The consumer home: the conversation you're in (live, at the top), who you talked to lately,
/// what's due, and everyone you know.
struct PeopleHome: View {
    @Environment(Store.self) private var store
    @Environment(CRM.self) private var crm
    @Environment(Assistant.self) private var assistant
    @Environment(Glasses.self) private var glasses

    @State private var query = ""
    @State private var path = NavigationPath()
    @State private var adding = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("People").font(.system(size: 34, weight: .semibold, design: .serif))
                        .padding(.horizontal, 20).padding(.top, 10)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        contacts(now: context.date)
                    }
                }
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .background(Color(.systemBackground))
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Person.self) { ContactView(id: $0.id) }
            .sheet(isPresented: $adding) {
                NewPersonSheet { path.append($0) }
            }
            #if DEBUG
            .onAppear {
                if let id = ProcessInfo.processInfo.environment["PREVIEW_CONTACT"],
                   let person = store.contacts.first(where: { $0.id == id || $0.name.lowercased().hasPrefix(id) }) {
                    path.append(person)
                }
            }
            #endif
        }
    }

    private var topBar: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("People").font(.system(size: 34, weight: .semibold, design: .serif))
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(glasses.connected ? Color.green : Color(.tertiaryLabel)).frame(width: 7, height: 7)
                Text(glasses.connected ? "Glasses" : "No glasses").font(.footnote.weight(.medium))
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Color(.secondarySystemBackground), in: Capsule())
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    private var subtitle: String {
        let today = Set(everyone.filter { lastTalked($0).map(Calendar.current.isDateInToday) == true }.map(\.id)).count
        return today == 0 ? "\(everyone.count) people" : "\(today) talked to today · \(everyone.count) people"
    }

    // MARK: Contacts

    private func contacts(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SearchField(text: $query)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 6)
            // New person: tap, type the name, done.
            Button { adding = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(Color(.secondarySystemBackground), in: Circle())
                    Text("New person").font(.body.weight(.medium))
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            let shown = filtered
            if shown.isEmpty {
                Text(query.isEmpty ? "Nobody yet. Add someone, or talk with the mic on."
                                   : "Nobody matches \u{201C}\(query)\u{201D}.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.top, 14)
            }
            ForEach(shown) { person in
                ContactRow(person: person, seen: lastTalked(person), now: now)
            }
        }
    }

    /// Everyone you know: the roster and the people you kept, not yourself.
    private var everyone: [Person] { store.contacts.filter { $0.isMe != true && !store.removed.contains($0.id) } }

    /// Newest first: the last person added at the top.
    private var filtered: [Person] {
        let sorted = Array(everyone.reversed())
        guard !query.isEmpty else { return sorted }
        let q = query.lowercased()
        return sorted.filter { person in
            ([person.name, person.role, person.work, person.school, person.from, person.interests, crm.label(person.id),
              person.email, person.phone, person.linkedin, person.instagram]
                .compactMap { $0 } + (person.tags ?? [])).contains { $0.lowercased().contains(q) }
        }
    }

    /// The last conversation, or the last time the glasses saw them, whichever is later.
    private func lastTalked(_ person: Person) -> Date? {
        let spoke = crm.conversations(with: person.id).first.map { $0.ended ?? $0.started }
        return [spoke, store.lastSeen[person.id]].compactMap { $0 }.max()
    }
}

// MARK: - Live notes

/// The conversation as it's heard, like a teleprompter: the last few lines, the newest one still
/// being spoken at the bottom, older ones fading out above it. Tap for the whole transcript.
/// Nothing here is saved; the CRM keeps only the notes once the conversation ends.
struct LiveNotes: View {
    @Environment(Assistant.self) private var assistant
    @Environment(CRM.self) private var crm
    @State private var expanded = false

    struct Entry: Equatable, Identifiable {
        var id: String
        var who: String
        var text: String
        var speaking = false
    }

    var body: some View {
        Group {
            if assistant.armed || preview != nil {
                Button { expanded = true } label: { card }
                    .buttonStyle(.plain)
            } else {
                off
            }
        }
        .sheet(isPresented: $expanded) { TranscriptSheet() }
    }

    /// A window onto the conversation: a quiet header, then the lines bottom-aligned in a fixed
    /// height, so new speech scrolls up from below instead of the card growing. The top edge
    /// fades older lines out; a name shows only when the speaker changes.
    private var card: some View {
        let entries = Array(lines.suffix(5))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                LiveDot()
                Text(header).font(.footnote.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            ZStack(alignment: .bottomLeading) {
                if entries.isEmpty {
                    Text("Listening for conversation")
                        .font(.callout).foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            let named = index == 0 || entries[index - 1].who != entry.who
                            VStack(alignment: .leading, spacing: 1) {
                                if named, !entry.who.isEmpty {
                                    Text(entry.who).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                }
                                Text(entry.text)
                                    .font(.callout)
                                    .foregroundStyle(entry.speaking ? .secondary : .primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(.easeOut(duration: 0.25), value: entries.map(\.id))
                    .animation(.easeOut(duration: 0.15), value: entries.last?.text)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 108, maxHeight: 108, alignment: .bottomLeading)
            .clipped()
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.3)],
                                 startPoint: .top, endPoint: .bottom))
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var off: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.slash").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Not listening").font(.subheadline.weight(.medium))
                Text("Turn the mic on to take notes on your next conversation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { Task { await assistant.toggle() } } label: {
                Text("Turn on").font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.systemBackground))
                    .padding(.horizontal, 13).padding(.vertical, 7)
                    .background(Color.primary, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// "Taking notes · with Dana", or just "Listening" before anyone is known.
    private var header: String {
        let faces = crm.live?.faces.map { crm.first($0) } ?? []
        let names = faces.isEmpty ? assistant.members.map(\.name) : faces
        return names.isEmpty ? "Live" : "Live with " + names.prefix(3).joined(separator: ", ")
    }

    var lines: [Entry] { preview ?? Self.entries(assistant) }

    /// Finished lines, then the turn still being spoken.
    static func entries(_ assistant: Assistant) -> [Entry] {
        var entries = assistant.aid.lines.filter { !$0.command }.map {
            Entry(id: "\($0.id)", who: who(assistant.name(for: $0.speaker)), text: $0.text)
        }
        let partial = assistant.aid.partial
        if !partial.isEmpty {
            let speaker = assistant.meSpeaking ? "You" : assistant.members.first(where: \.speaking)?.name ?? ""
            entries.append(Entry(id: "live", who: speaker, text: partial, speaking: true))
        }
        return entries
    }

    /// YOU → You, AVI → Avi, THEM stays a quiet "Them".
    static func who(_ tag: String) -> String { tag == "?" ? "" : tag.capitalized }

    /// DEBUG: PREVIEW_LIVE="Dana:I just got back from Lisbon|You:Oh amazing|Dana:The wedding was…"
    private var preview: [Entry]? {
        #if DEBUG
        guard let spec = ProcessInfo.processInfo.environment["PREVIEW_LIVE"] else { return nil }
        return spec.components(separatedBy: "|").enumerated().map { i, part in
            let bits = part.split(separator: ":", maxSplits: 1).map(String.init)
            return Entry(id: "\(i)", who: bits.count > 1 ? bits[0] : "", text: bits.last ?? "")
        }
        #else
        return nil
        #endif
    }
}

/// A red dot that breathes while the mic is on.
struct LiveDot: View {
    @State private var on = false

    var body: some View {
        Circle().fill(Color.red).frame(width: 7, height: 7)
            .opacity(on ? 1 : 0.35)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// The whole conversation so far, newest at the bottom, following along as it's spoken.
struct TranscriptSheet: View {
    @Environment(Assistant.self) private var assistant
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    let entries = LiveNotes.entries(assistant)
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Only the notes are kept when the conversation ends: a summary, what you learned, what you owe each other. Never this transcript.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .padding(.bottom, 4)
                        if entries.isEmpty {
                            Text("Nothing yet.").font(.callout).foregroundStyle(.tertiary)
                        }
                        ForEach(entries) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                if !entry.who.isEmpty {
                                    Text(entry.who.uppercased()).font(.caption2.weight(.bold)).tracking(0.6)
                                        .foregroundStyle(.secondary)
                                }
                                Text(entry.text).font(.body).foregroundStyle(entry.speaking ? .secondary : .primary)
                            }
                            .id(entry.id)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: entries.last?.text) { _, _ in
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
                    }
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            .navigationTitle("Live transcript")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - A contact

/// Everything about one person: who they are (editable), your notes, what's open between you,
/// what you've learned, and every time you've talked or crossed paths.
struct ContactView: View {
    @Environment(Store.self) private var store
    @Environment(CRM.self) private var crm
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var editing = false
    @State private var addingToContacts = false
    @State private var name = ""
    @FocusState private var typingName: Bool
    @State private var note = ""
    @State private var learned = ""
    @State private var allHistory = false
    @FocusState private var typingFact: Bool

    /// The roster or a kept contact (with the wearer's edits), else someone met but not kept.
    private var person: Person? {
        store.contacts.first { $0.id == id }
            ?? crm.contacts.first { $0.id == id }.map { store.edits[$0.id] ?? crm.person($0) }
    }

    var body: some View {
        if let person {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(person)
                    ReachActions(person: person)
                    section("Notes") {
                        TextField("Anything worth remembering about \(first(person))", text: $note, axis: .vertical)
                            .font(.subheadline)
                            .lineLimit(3...10)
                            .padding(12)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    PersonCRM(person: person, conversations: false, learned: false)
                    section("What you know") { knowledge(person) }
                    section("Contact") { ContactRows(person: person) { editing = true } }
                    section("History") { history(person) }.id("history")
                    if crm.consent(id) != .pending {
                        section("Recognition") {
                            NavigationLink { FaceGallery(person: person) } label: {
                                HStack {
                                    Text("Face photos").font(.subheadline)
                                    Spacer()
                                    Text("\(store.samples(id))").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 11)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    // Filled in by the backend's enrichment; read-only.
                    section("Enriched data") { about(person) }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            #if DEBUG
            .onAppear {
                if ProcessInfo.processInfo.environment["PREVIEW_SCROLL"] == "history" { proxy.scrollTo("history", anchor: .top) }
            }
            #endif
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Add to iPhone Contacts", systemImage: "person.crop.circle.badge.plus") { addingToContacts = true }
                        ShareLink(item: VCard(person: person), preview: SharePreview(person.name)) {
                            Label("Share contact", systemImage: "square.and.arrow.up")
                        }
                        // Roster people come back from New person's quick add; anyone else is forgotten.
                        Button("Remove", systemImage: "person.badge.minus", role: .destructive) {
                            if store.people.contains(where: { $0.id == id }) { store.remove(id) } else { crm.forgetPerson(id) }
                            dismiss()
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $editing) { ContactEditor(person: person) { _ in } }
            .sheet(isPresented: $addingToContacts) { NewContactSheet(person: person).ignoresSafeArea() }
            .onAppear { note = store.notes[id] ?? ""; name = person.name }
            .onChange(of: note) { _, text in store.setNote(id, text) }
        } else {
            Text("Forgotten.").foregroundStyle(.secondary)
        }
    }

    private func header(_ person: Person) -> some View {
        HStack(alignment: .center, spacing: 16) {
            // The photo opens their face photos, to pick one or upload a new one.
            NavigationLink { FaceGallery(person: person) } label: {
                Avatar(person: person, size: 76, corner: 22)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color(.systemBackground))
                            .frame(width: 22, height: 22).background(Color.primary, in: Circle())
                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                            .offset(x: 5, y: 5)
                    }
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                // The name is edited in place: tap it (or its pencil) and type.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField("Name", text: $name, axis: .horizontal)
                        .font(.system(size: 28, weight: .semibold, design: .serif)).lineLimit(1)
                        .focused($typingName)
                        .submitLabel(.done)
                        .onChange(of: name) { _, text in
                            // Return ends editing rather than adding a line.
                            if text.contains("\n") { name = text.replacingOccurrences(of: "\n", with: ""); typingName = false }
                        }
                    if !typingName {
                        Button { typingName = true } label: {
                            Image(systemName: "pencil").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text(summary).font(.caption).foregroundStyle(.tertiary).padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .onChange(of: typingName) { _, typing in if !typing { rename(person) } }
    }

    private func rename(_ person: Person) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { name = person.name; return }
        guard clean != person.name else { return }
        var updated = person
        updated.name = clean
        store.update(updated)
        crm.rename(id, to: clean)
    }

    /// "Talked 3 times · last on Oct 22" or "Haven't talked yet".
    private var summary: String {
        let talks = crm.conversations(with: id)
        guard let last = talks.first else {
            return store.lastSeen[id].map { "Seen " + relative($0) } ?? "Haven't talked yet"
        }
        let times = talks.count == 1 ? "once" : "\(talks.count) times"
        return "Talked \(times) · last \(relative(last.ended ?? last.started))"
    }

    // MARK: What you know

    @ViewBuilder private func knowledge(_ person: Person) -> some View {
        let facts = crm.facts(about: id)
        VStack(spacing: 0) {
            ForEach(facts) { fact in
                VStack(spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(fact.text).font(.subheadline)
                        Spacer(minLength: 8)
                        Text(fact.learned.formatted(.dateTime.month(.abbreviated).day()))
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("Forget", systemImage: "trash", role: .destructive) { crm.forget(fact.id) }
                    }
                    Divider()
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                TextField(facts.isEmpty ? "Something you know about \(first(person))" : "Add another", text: $learned)
                    .font(.subheadline)
                    .focused($typingFact)
                    .submitLabel(.done)
                    .onSubmit {
                        crm.learn(id, learned)
                        learned = ""
                    }
            }
            .padding(.vertical, 10)
        }
    }

    // MARK: About

    @ViewBuilder private func about(_ person: Person) -> some View {
        let rows = [("Work", person.work), ("School", person.school), ("From", person.from),
                    ("Into", person.interests), ("How you met", person.tie)]
            .compactMap { label, value in value.flatMap { $0.isEmpty ? nil : (label, $0) } }
        if rows.isEmpty {
            Text("Nothing yet.").font(.subheadline).foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(rows, id: \.0) { label, value in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(label).font(.subheadline).foregroundStyle(.secondary).frame(width: 104, alignment: .leading)
                        Text(value).font(.subheadline)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 11)
                    Divider()
                }
            }
        }
    }

    // MARK: History

    /// Conversations with their notes, and the times the glasses saw them without one.
    private enum Moment: Identifiable {
        case talked(Conversation)
        case saw(Date)
        var id: String { switch self { case .talked(let c): c.id.uuidString; case .saw(let d): "\(d.timeIntervalSince1970)" } }
        var at: Date { switch self { case .talked(let c): c.started; case .saw(let d): d } }
    }

    private var moments: [Moment] {
        let talks = crm.conversations(with: id)
        // A sighting during a conversation is that conversation, not a second entry.
        let sightings = (store.encounters[id] ?? []).filter { date in
            !talks.contains { date >= $0.started.addingTimeInterval(-600) && date <= ($0.ended ?? $0.started).addingTimeInterval(600) }
        }
        return (talks.map(Moment.talked) + sightings.map(Moment.saw)).sorted { $0.at > $1.at }
    }

    @ViewBuilder private func history(_ person: Person) -> some View {
        let all = self.moments
        let moments = allHistory ? all : Array(all.prefix(2))
        if all.isEmpty {
            Text("Talk with the mic on and each conversation with \(first(person)) is noted here.")
                .font(.subheadline).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(moments.enumerated()), id: \.element.id) { index, moment in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 0) {
                            Circle().fill(index == 0 ? Color.primary : Color(.tertiaryLabel))
                                .frame(width: 7, height: 7).padding(.top, 6)
                            if index < moments.count - 1 {
                                Rectangle().fill(Color(.separator)).frame(width: 1).frame(maxHeight: .infinity)
                            }
                        }
                        .frame(width: 7)
                        momentRow(moment).padding(.bottom, 16)
                    }
                }
                if all.count > moments.count {
                    Button("See more") { withAnimation { allHistory = true } }
                        .font(.subheadline.weight(.medium)).buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private func momentRow(_ moment: Moment) -> some View {
        switch moment {
        case .talked(let conversation):
            NavigationLink { ConversationDetail(id: conversation.id) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(meta(conversation)).font(.caption).foregroundStyle(.secondary)
                    Text(conversation.summary ?? "No summary yet")
                        .font(.subheadline)
                        .foregroundStyle(conversation.summary == nil ? .secondary : .primary)
                        .multilineTextAlignment(.leading)
                    if !conversation.topics.isEmpty {
                        Text(conversation.topics.prefix(3).joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .saw(let date):
            VStack(alignment: .leading, spacing: 2) {
                Text(dayAndTime(date)).font(.caption).foregroundStyle(.secondary)
                Text("Crossed paths, recognized by your glasses").font(.subheadline)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            content()
        }
        .padding(.top, 28)
    }

    private func first(_ person: Person) -> String {
        person.name.split(separator: " ").first.map(String.init) ?? person.name
    }
}

// MARK: - Editing

/// Add someone, or correct what's known about them. Roster people and contacts alike: the edits
/// live on this phone (`Store.update`), the team's roster file is untouched.
struct ContactEditor: View {
    @Environment(Store.self) private var store
    @Environment(CRM.self) private var crm
    @Environment(\.dismiss) private var dismiss
    /// nil = a new contact.
    let person: Person?
    /// Called with the saved person (for a new one, to open it).
    var saved: (Person) -> Void

    @State private var name = ""
    @State private var role = ""
    @State private var work = ""
    @State private var school = ""
    @State private var from = ""
    @State private var interests = ""
    @State private var tie = ""
    @State private var phone = ""
    @State private var email = ""
    @State private var linkedin = ""
    @State private var instagram = ""
    @State private var website = ""
    @State private var photo: UIImage?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 14) {
                        PhotoPick(image: $photo, current: person.flatMap { store.avatars[$0.id] }, size: 120)
                        TextField("Name", text: $name, axis: .vertical)
                            .font(.system(size: 30, weight: .semibold, design: .serif))
                            .multilineTextAlignment(.center)
                            .textContentType(.name)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                Section("About") {
                    TextField("What they do, in a few words", text: $role)
                    TextField("Work", text: $work)
                    TextField("School", text: $school)
                    TextField("From", text: $from)
                    TextField("Into", text: $interests, axis: .vertical)
                    TextField("How you met", text: $tie, axis: .vertical)
                }
                Section("Contact") {
                    TextField("Phone", text: $phone).textContentType(.telephoneNumber).keyboardType(.phonePad)
                    TextField("Email", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress)
                    TextField("LinkedIn profile or URL", text: $linkedin).keyboardType(.URL)
                    TextField("Instagram", text: $instagram)
                    TextField("Website", text: $website).keyboardType(.URL)
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
            .navigationTitle(person == nil ? "New contact" : "Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let person else { return }
        name = person.name
        role = person.role
        work = person.work ?? ""
        school = person.school ?? ""
        from = person.from ?? ""
        interests = person.interests ?? ""
        tie = person.tie ?? ""
        phone = person.phone ?? ""
        email = person.email ?? ""
        linkedin = person.linkedin ?? ""
        instagram = person.instagram.map { "@" + $0 } ?? ""
        website = person.website ?? ""
    }

    private func save() {
        func clean(_ text: String) -> String? {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let name = self.name.trimmingCharacters(in: .whitespaces)
        let id = person?.id ?? crm.add(name: name)
        var updated = person ?? Person(id: id, name: name, role: "")
        updated.name = name
        updated.role = clean(role) ?? (person?.role ?? "")
        updated.work = clean(work)
        updated.school = clean(school)
        updated.from = clean(from)
        updated.interests = clean(interests)
        updated.tie = clean(tie)
        // What was typed stands; links are cut down to the handle when they can be.
        updated.phone = clean(phone)
        updated.email = clean(email)
        updated.linkedin = Recap.Details.handle(linkedin, after: "/in/") ?? clean(linkedin)
        updated.instagram = Recap.Details.handle(instagram, after: "instagram.com/") ?? clean(instagram)
        updated.website = Recap.Details.website(website) ?? clean(website)
        store.update(updated)
        if let photo { store.setAvatar(id, photo) }
        crm.rename(id, to: name)
        dismiss()
        saved(updated)
    }
}

// MARK: - New person

/// Adding someone is two things: their name, big, in serif, and a photo. Everything else comes
/// later, from enrichment or a conversation.
struct NewPersonSheet: View {
    @Environment(Store.self) private var store
    @Environment(CRM.self) private var crm
    @Environment(\.dismiss) private var dismiss
    var saved: (Person) -> Void

    @State private var name = ""
    @State private var photo: UIImage?
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                PhotoPick(image: $photo, current: nil, size: 140)
                TextField("Name", text: $name, axis: .vertical)
                    .font(.system(size: 34, weight: .semibold, design: .serif))
                    .multilineTextAlignment(.center)
                    .textContentType(.name)
                    .focused($typing)
                    .padding(.vertical, 18).padding(.horizontal, 16)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                quickAdd
                Spacer()
            }
            .padding(24)
            .navigationTitle("New person")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { typing = true }
        }
    }

    /// The roster, one tap each: puts a removed person back exactly as they were (photos, details).
    private var quickAdd: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Quick add")
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(store.people) { person in
                        Button {
                            store.restore(person.id)
                            dismiss()
                            saved(person)
                        } label: {
                            VStack(spacing: 6) {
                                Avatar(person: person, size: 56)
                                Text(person.name.split(separator: " ").first.map(String.init) ?? person.name)
                                    .font(.footnote).foregroundStyle(.primary)
                                Text(store.removed.contains(person.id) ? "Removed" : "Added")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save() {
        let name = self.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = crm.add(name: name)
        let person = Person(id: id, name: name, role: "")
        store.update(person)
        if let photo { store.setAvatar(id, photo) }
        dismiss()
        saved(person)
    }
}

/// A round photo you tap to pick from the library.
struct PhotoPick: View {
    @Binding var image: UIImage?
    var current: UIImage?
    var size: CGFloat
    @State private var item: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $item, matching: .images) {
            Group {
                if let shown = image ?? current {
                    Image(uiImage: shown).resizable().scaledToFill()
                } else {
                    Image(systemName: "camera").font(.system(size: size * 0.24)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.secondarySystemBackground))
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "pencil").font(.system(size: 13, weight: .semibold))
                    .padding(7).background(.thinMaterial, in: Circle())
            }
        }
        .onChange(of: item) { _, picked in
            Task {
                if let data = try? await picked?.loadTransferable(type: Data.self), let loaded = UIImage(data: data) {
                    image = loaded
                }
            }
        }
    }
}

// MARK: - Face photos

/// Everyone's face photos as a grid: tap one to delete it, the + tile (first) to take or pick another.
/// Each photo is also a sample face ID matches against, so deleting a bad one helps.
struct FaceGallery: View {
    @Environment(Store.self) private var store
    let person: Person
    /// The photo tapped: make it the profile photo, or (one of theirs) delete it.
    @State private var chosen: (image: UIImage, shot: Store.Shot?)?
    @State private var adding = false
    @State private var upload: PhotosPickerItem?

    var body: some View {
        let shots = store.shots[person.id] ?? []
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)], spacing: 6) {
                // First tiles: take a photo, or upload one as the profile photo.
                Button { adding = true } label: { action("camera") }.buttonStyle(.plain)
                PhotosPicker(selection: $upload, matching: .images) { action("photo.badge.plus") }.buttonStyle(.plain)
                // Their profile photo, first.
                if let avatar = store.avatars[person.id] {
                    tile(avatar).overlay(alignment: .bottomLeading) {
                        Text("Profile").font(.caption2.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(.black.opacity(0.55), in: Capsule()).padding(5)
                    }
                }
                ForEach(shots.reversed()) { shot in
                    Button { chosen = (shot.image, shot) } label: { tile(shot.image) }.buttonStyle(.plain)
                }
                // The bundled photos face ID was built from; part of the app, so not deletable here.
                ForEach(Array(store.referencePhotos(person.id).enumerated()), id: \.offset) { _, image in
                    Button { chosen = (image, nil) } label: { tile(image) }.buttonStyle(.plain)
                }
            }
            .padding(6)
        }
        .navigationTitle("Face photos · \(store.samples(person.id))")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $adding) { EnrollView(person: person) }
        .onChange(of: upload) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    store.setAvatar(person.id, image)
                    store.addShot(person.id, embedding: nil, image: image)
                }
                upload = nil
            }
        }
        .confirmationDialog("This photo", isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } })) {
            Button("Use as profile photo") {
                if let chosen { store.setAvatar(person.id, chosen.image) }
                chosen = nil
            }
            if let shot = chosen?.shot {
                Button("Delete", role: .destructive) {
                    store.deleteShot(person.id, shot.id)
                    chosen = nil
                }
            }
        }
    }

    private func action(_ symbol: String) -> some View {
        Color(.secondarySystemBackground).aspectRatio(1, contentMode: .fit)
            .overlay(Image(systemName: symbol).font(.title2.weight(.medium)).foregroundStyle(.secondary))
    }

    private func tile(_ image: UIImage) -> some View {
        Image(uiImage: image).resizable().scaledToFill()
            .frame(minWidth: 0, maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
            .clipped()
    }
}
