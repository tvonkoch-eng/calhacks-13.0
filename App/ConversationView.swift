import SwiftUI

/// Phone-side view of the conversation aid. The demo happens on the lens; this is the operator
/// panel: is it hearing you, who said what (tagged ME / THEM once roles are known), and what the
/// aid did about it. "That was me" fixes who's who when the loudness guess got it backwards.
struct ConversationView: View {
    @Environment(Assistant.self) private var assistant

    var body: some View {
        let aid = assistant.aid
        List {
            Section {
                MicRow()
                if !aid.partial.isEmpty {
                    Text(aid.partial)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .animation(.none, value: aid.partial)
                }
            } footer: {
                if !assistant.note.isEmpty {
                    Text(assistant.note).foregroundStyle(.orange)
                } else if !aid.status.isEmpty {
                    Text(aid.status).foregroundStyle(.orange)
                } else if let name = aid.them.name {
                    Text("Talking to \(name)\(aid.them.recognised ? " (recognised)" : "").")
                } else {
                    Text("Answers their questions, defines what you might not know, and now and then suggests what to say.")
                }
            }

            if !aid.events.isEmpty {
                Section("Conversation") {
                    ForEach(aid.events.reversed()) { EventRow(event: $0) }
                }
            }
        }
        .navigationTitle("Listening")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Mic toggle plus a level meter, so you can tell "not listening" from "nobody said anything".
struct MicRow: View {
    @Environment(Assistant.self) private var assistant

    var body: some View {
        HStack(spacing: 14) {
            Button {
                if assistant.armed { assistant.disarm() } else { Task { await assistant.arm() } }
            } label: {
                Image(systemName: assistant.armed ? "mic.fill" : "mic.slash")
                    .font(.title3)
                    .frame(width: 46, height: 46)
                    .background(assistant.armed ? Color.accentColor : Color(.secondarySystemFill),
                                in: Circle())
                    .foregroundStyle(assistant.armed ? .white : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 5) {
                Text(assistant.armed ? "Listening" : "Not listening").font(.body.weight(.medium))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.secondarySystemFill))
                        Capsule().fill(Color.accentColor)
                            .frame(width: geo.size.width * CGFloat(assistant.level))
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(.vertical, 4)
    }
}

struct EventRow: View {
    @Environment(Assistant.self) private var assistant
    let event: Event

    var body: some View {
        switch event.kind {
        case .line:
            let tag = assistant.aid.tag(event.speaker)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(tag).font(.caption2.weight(.bold)).tracking(1)
                        .foregroundStyle(tag == "ME" ? Color.accentColor : .secondary)
                    Spacer()
                    if let speaker = event.speaker, tag != "ME" {
                        Button("That was me") { assistant.aid.markWearer(speaker) }
                            .font(.caption2).buttonStyle(.borderless)
                    }
                }
                Text(event.text).font(.body)
            }
            .padding(.vertical, 2)
        default:
            VStack(alignment: .leading, spacing: 2) {
                Label(event.text, systemImage: symbol).font(.footnote.weight(.medium))
                if !event.detail.isEmpty {
                    Text(event.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(event.kind == .status ? Color.orange : Color.primary)
        }
    }

    private var symbol: String {
        switch event.kind {
        case .answer: "text.bubble"
        case .define: "book"
        case .followup: "bubble.left"
        case .research, .lookup: "magnifyingglass"
        case .learned: "person.text.rectangle"
        case .roles: "person.2"
        case .status: "exclamationmark.triangle"
        case .line: "quote.bubble"
        }
    }
}
