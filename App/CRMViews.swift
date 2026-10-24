import SwiftUI
import UserNotifications

// The phone side of the personal CRM (App/CRM.swift): what's due, people met but not yet kept,
// each person's conversations and what you learned, and one conversation's notes.

/// Local notifications for reminders, one per reminder id. Asked for the first time a reminder
/// is made, which is right after a conversation, not at launch.
enum Nudges {
    static func schedule(_ reminder: Reminder, title: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [reminder.id.uuidString])
        guard reminder.open, reminder.due > .now else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = reminder.text
            content.sound = .default
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.due)
            center.add(UNNotificationRequest(identifier: reminder.id.uuidString, content: content,
                                             trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
        }
    }

    static func cancel(_ id: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id.uuidString])
    }
}

/// "Overdue", "Today", "Tomorrow", "Fri", "Nov 3".
func dueLabel(_ date: Date, now: Date = .now) -> String {
    let calendar = Calendar.current
    if date < now, !calendar.isDateInToday(date) { return "Overdue" }
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInTomorrow(date) { return "Tomorrow" }
    if date.timeIntervalSince(now) < 6 * 86400 { return date.formatted(.dateTime.weekday(.abbreviated)) }
    return date.formatted(.dateTime.month(.abbreviated).day())
}

extension CRM {
    /// A contact as a `Person`, so it opens the same record screen and, once saved, joins the
    /// matcher in `Store`.
    func person(_ contact: Contact) -> Person {
        Person(id: contact.id, name: contact.name, role: label(contact.id) ?? "Met \(dayAndTime(contact.created))")
    }
}

// MARK: - Home

/// Above the people list: the conversation being kept, what's due, and people met but not yet
/// kept. Nothing at all when there's nothing to do.
struct FollowUps: View {
    @Environment(CRM.self) private var crm
    let now: Date

    var body: some View {
        let due = crm.upcoming(now: now)
        let pending = crm.pending
        VStack(alignment: .leading, spacing: 0) {
            if let live = crm.live {
                HStack(spacing: 8) {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                    Text(liveLine(live)).font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
            if !due.isEmpty {
                SectionLabel("Follow up").padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 2)
                ForEach(due) { ReminderRow(reminder: $0, showWho: true, now: now).padding(.horizontal, 20) }
            }
            if !pending.isEmpty {
                SectionLabel("New people").padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 2)
                ForEach(pending) { contact in
                    NavigationLink(value: crm.person(contact)) { PendingRow(contact: contact, now: now) }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 20)
                }
            }
        }
        .animation(.default, value: due.map(\.id))
    }

    private func liveLine(_ live: CRM.Live) -> String {
        let with = live.faces.isEmpty ? "" : " with " + live.faces.map { crm.first($0) }.joined(separator: ", ")
        return "Taking notes on this conversation\(with)"
    }
}

/// Someone met but not kept: who they said they were, and how long until they're forgotten.
struct PendingRow: View {
    @Environment(CRM.self) private var crm
    let contact: Contact
    let now: Date

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.name).font(.body.weight(.medium))
                    if let line = crm.label(contact.id) ?? crm.conversations(with: contact.id).first?.summary {
                        Text(line).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(forgottenIn).font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            Divider()
        }
    }

    private var forgottenIn: String {
        let left = contact.created.addingTimeInterval(crm.pendingDays * 86400).timeIntervalSince(now)
        let days = max(0, Int((left / 86400).rounded(.up)))
        return days <= 1 ? "Forgotten tomorrow" : "Forgotten in \(days) days"
    }
}

struct ReminderRow: View {
    @Environment(CRM.self) private var crm
    let reminder: Reminder
    var showWho = false
    var now: Date = .now

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Button { crm.complete(reminder.id) } label: {
                    Image(systemName: reminder.open ? "circle" : "checkmark.circle.fill")
                        .font(.system(size: 19, weight: .light))
                        .foregroundStyle(reminder.open ? Color.secondary : Color.green)
                }
                .buttonStyle(.plain)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                VStack(alignment: .leading, spacing: 2) {
                    Text(reminder.text)
                        .font(.subheadline)
                        .strikethrough(!reminder.open, color: .secondary)
                        .foregroundStyle(reminder.open ? .primary : .secondary)
                    Text(subline).font(.caption).foregroundStyle(overdue ? Color.red : Color.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .contextMenu {
                Button("Tomorrow", systemImage: "moon") { crm.snooze(reminder.id, days: 1) }
                Button("Next week", systemImage: "calendar") { crm.snooze(reminder.id, days: 7) }
                Button("Delete", systemImage: "trash", role: .destructive) { crm.deleteReminder(reminder.id) }
            }
            Divider()
        }
    }

    private var overdue: Bool { reminder.open && reminder.due < now && !Calendar.current.isDateInToday(reminder.due) }

    private var subline: String {
        let kind = switch reminder.kind {
        case .todo: "You said you would"
        case .waiting: "They said they would"
        case .checkIn: "It's been a while"
        }
        let who = showWho && reminder.kind != .checkIn ? crm.first(reminder.person) + " · " : ""
        return who + kind + " · " + dueLabel(reminder.due, now: now)
    }
}

struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(conversation.summary ?? "No summary yet")
                        .font(.subheadline)
                        .foregroundStyle(conversation.summary == nil ? .secondary : .primary)
                        .multilineTextAlignment(.leading)
                    Text(meta(conversation)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            Divider()
        }
    }
}

/// "Today, 3:10 PM · 12 min · near Union Square, SF".
func meta(_ conversation: Conversation) -> String {
    let minutes = max(1, Int((conversation.length / 60).rounded()))
    return ([dayAndTime(conversation.started), "\(minutes) min"] + [conversation.place].compactMap { $0 })
        .joined(separator: " · ")
}

// MARK: - Person

/// The CRM's sections of a person's record: keep or forget (someone met but not kept), what's
/// open between you, what you talked about, what you learned. Sits under the stats in `PersonView`.
struct PersonCRM: View {
    @Environment(CRM.self) private var crm
    @Environment(\.dismiss) private var dismiss
    let person: Person
    @State private var draft = ""
    @FocusState private var typing: Bool

    private var first: String { person.name.split(separator: " ").first.map(String.init) ?? person.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if crm.consent(person.id) == .pending { consent }

            block("Follow up") {
                ForEach(crm.open(for: person.id)) { ReminderRow(reminder: $0) }
                HStack(spacing: 10) {
                    Image(systemName: "plus").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                    TextField("Remind me to…", text: $draft)
                        .font(.subheadline)
                        .focused($typing)
                        .submitLabel(.done)
                        .onSubmit { add(days: 1) }
                    if !draft.isEmpty {
                        Menu("Tomorrow") {
                            Button("Later today") { add(days: 0) }
                            Button("Tomorrow") { add(days: 1) }
                            Button("In 3 days") { add(days: 3) }
                            Button("Next week") { add(days: 7) }
                            Button("In a month") { add(days: 30) }
                        } primaryAction: { add(days: 1) }
                        .font(.footnote.weight(.medium))
                    }
                }
                .padding(.vertical, 10)
            }

            let conversations = crm.conversations(with: person.id)
            block("Conversations") {
                if conversations.isEmpty {
                    Text("Talk with the mic on and each conversation with \(first) is noted here: a summary, what you learned, what you owe each other.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(conversations) { conversation in
                        NavigationLink { ConversationDetail(id: conversation.id) } label: {
                            ConversationRow(conversation: conversation)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            let facts = crm.facts(about: person.id)
            if !facts.isEmpty {
                block("Learned") {
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
                }
            }
        }
    }

    /// Someone met but not kept. The rule the whole CRM follows: nobody is recognizable or kept
    /// past a week unless they opted in (the roster) or the wearer chose to keep them.
    private var consent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You met \(first) but haven't kept them. Their notes are forgotten in a week, and they can't be recognized.")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button { crm.keep(person.id) } label: {
                    Text("Keep \(first)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(.systemBackground))
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(Color.primary, in: Capsule())
                }
                Menu {
                    ForEach(crm.roster(ids: crm.rosterIDs)) { known in
                        Button(known.name) { crm.merge(person.id, into: known.id); dismiss() }
                    }
                } label: {
                    Text("This was…").font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                }
                Spacer()
                Button("Forget", role: .destructive) { crm.forgetPerson(person.id); dismiss() }
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .tint(.primary)
        }
        .padding(.top, 22)
    }

    private func block<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(title)
            content()
        }
        .padding(.top, 28)
    }

    private func add(days: Int) {
        crm.remind(person.id, draft, due: CRM.due(days, from: .now))
        draft = ""
        typing = false
    }
}

extension CRM {
    struct Named: Identifiable { var id: String; var name: String }
    /// Everyone a contact could turn out to be: the roster and kept contacts.
    func roster(ids: [String]) -> [Named] {
        ids.compactMap { id in roster(id).map { Named(id: id, name: $0.name) } } + saved.map { Named(id: $0.id, name: $0.name) }
    }
}

// MARK: - One conversation

/// The notes from one conversation. No transcript: it is never kept.
struct ConversationDetail: View {
    @Environment(CRM.self) private var crm
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var retrying = false

    var body: some View {
        if let conversation = crm.conversations.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(conversation)
                    let reminders = crm.reminders.filter { $0.conversation == id && $0.kind != .checkIn }
                    if !reminders.isEmpty {
                        SectionLabel("Follow up").padding(.top, 28).padding(.bottom, 4)
                        ForEach(reminders) { ReminderRow(reminder: $0) }
                    }
                    let facts = crm.facts.filter { $0.conversation == id }
                    if !facts.isEmpty {
                        SectionLabel("Learned").padding(.top, 28).padding(.bottom, 4)
                        ForEach(facts) { fact in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(fact.text).font(.subheadline).padding(.vertical, 10)
                                Divider()
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Delete these notes", systemImage: "trash", role: .destructive) {
                            crm.delete(id)
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        } else {
            Text("Deleted.").foregroundStyle(.secondary)
        }
    }

    private func header(_ conversation: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(crm.name(conversation.person)).font(.system(size: 28, weight: .semibold, design: .serif))
            if let label = conversation.label { Text(label).font(.callout).padding(.top, 3) }
            Text(meta(conversation)).font(.callout).foregroundStyle(.secondary).padding(.top, 3)
            if let summary = conversation.summary {
                Text(summary).font(.body).padding(.top, 16)
            } else if crm.canRetry(id) {
                Button(retrying ? "Summarizing…" : "Summarize again") {
                    retrying = true
                    Task { await crm.retryRecap(id); retrying = false }
                }
                .font(.subheadline.weight(.medium))
                .disabled(retrying)
                .padding(.top, 16)
                if !crm.note.isEmpty { Text(crm.note).font(.caption).foregroundStyle(.secondary).padding(.top, 4) }
            } else {
                Text("The summary failed and the transcript is never kept, so only what was noted live is here.")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.top, 16)
            }
            if !conversation.topics.isEmpty { TagRow(tags: conversation.topics).padding(.top, 12) }
        }
        .padding(.top, 8)
    }
}
