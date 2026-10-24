import SwiftUI

/// Phone-side view of the conversation assistant. The demo happens on the lens; this is the
/// operator panel — is it hearing you, what did it think the question was, and how early did the
/// answer land. The timing readout is the number worth watching.
struct ConversationView: View {
    @Environment(Assistant.self) private var assistant

    var body: some View {
        List {
            Section {
                MicRow()
                if !assistant.transcript.isEmpty {
                    Text(assistant.transcript)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .animation(.none, value: assistant.transcript)
                }
            } footer: {
                if !assistant.note.isEmpty {
                    Text(assistant.note).foregroundStyle(.orange)
                } else {
                    Text("Questions about the world get answered on the lens. Questions about the people in the room are ignored.")
                }
            }

            if !assistant.turns.isEmpty {
                Section("Questions") {
                    ForEach(assistant.turns) { TurnRow(turn: $0) }
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

struct TurnRow: View {
    let turn: Turn

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(turn.question).font(.footnote).foregroundStyle(.secondary)
            switch turn.state {
            case .thinking:
                Label("Answering…", systemImage: "ellipsis").font(.body).foregroundStyle(.secondary)
            case .answering, .done:
                Text(turn.answer).font(.body.weight(.medium))
            case .personal:
                Label("Skipped: about the people talking", systemImage: "person.fill.xmark")
                    .font(.footnote).foregroundStyle(.secondary)
            case .incomplete:
                Label("Too cut off to answer", systemImage: "scissors")
                    .font(.footnote).foregroundStyle(.secondary)
            case .abandoned:
                Label("Not a question after all", systemImage: "text.badge.xmark")
                    .font(.footnote).foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
            if let timing { Text(timing).font(.caption.monospacedDigit()).foregroundStyle(.tertiary) }
        }
        .padding(.vertical, 2)
    }

    /// Negative lead means we were still waiting when they stopped talking.
    private var timing: String? {
        guard let lead = turn.lead else { return nil }
        let ms = Int((abs(lead) * 1000).rounded())
        let fires = turn.fires > 1 ? " · \(turn.fires) tries" : ""
        return lead >= 0 ? "on lens \(ms) ms before you finished\(fires)"
                         : "on lens \(ms) ms after you finished\(fires)"
    }
}
