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
                ContactEditor(person: nil) { path.append($0) }
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
    private var everyone: [Person] { store.contacts.filter { $0.isMe != true } }

    /// Newest first: the last person added at the top.
    private var filtered: [Person] {
        let sorted = Array(everyone.reversed())
        guard !query.isEmpty else { return sorted }
        let q = query.lowercased()
        return sorted.filter { person in
            ([person.name, person.role, person.work, person.school, person.from, person.interests, crm.label(person.id)]
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
    let id: String
    @State private var editing = false
    @State private var note = ""
    @State private var learned = ""
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
                    PersonCRM(person: person, conversations: false, learned: false)
                    section("Notes") {
                        TextField("Anything worth remembering about \(first(person))", text: $note, axis: .vertical)
                            .font(.subheadline)
                            .lineLimit(3...10)
                            .padding(12)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    section("What you know") { knowledge(person) }
                    section("About") { about(person) }
                    section("History") { history(person) }.id("history")
                    if crm.consent(id) != .pending {
                        section("Recognition") {
                            NavigationLink { EnrollView(person: person) } label: {
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
                ToolbarItem(placement: .topBarTrailing) { Button("Edit") { editing = true } }
            }
            .sheet(isPresented: $editing) { ContactEditor(person: person) { _ in } }
            .onAppear { note = store.notes[id] ?? "" }
            .onChange(of: note) { _, text in store.setNote(id, text) }
        } else {
            Text("Forgotten.").foregroundStyle(.secondary)
        }
    }

    private func header(_ person: Person) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Avatar(person: person, size: 76, corner: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(person.name).font(.system(size: 28, weight: .semibold, design: .serif)).lineLimit(2)
                Text(crm.label(id) ?? person.headline).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Text(summary).font(.caption).foregroundStyle(.tertiary).padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
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
            Button { editing = true } label: {
                Text("Add where they work, study, what they're into").font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
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
        let moments = self.moments
        if moments.isEmpty {
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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name).textContentType(.name)
                    TextField("What they do, in a few words", text: $role)
                }
                Section("About") {
                    TextField("Work", text: $work)
                    TextField("School", text: $school)
                    TextField("From", text: $from)
                    TextField("Into", text: $interests, axis: .vertical)
                    TextField("How you met", text: $tie, axis: .vertical)
                }
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
        store.update(updated)
        crm.rename(id, to: name)
        dismiss()
        saved(updated)
    }
}
