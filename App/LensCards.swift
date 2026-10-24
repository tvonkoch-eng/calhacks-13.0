import MWDATDisplay
import UIKit

/// What the Ray-Ban Display lens shows. One root FlexBox per send; keep it glanceable:
/// who they are and three lines of background.
enum LensCards {
    static func working() -> FlexBox {
        FlexBox(direction: .row, spacing: 12, crossAlignment: .center) {
            Icon(name: .eye)
            Text("Recognizing", style: .heading)
        }
        .padding(24)
        .background(.card)
    }

    /// A conversation answer: the answer big, the question it answers small underneath.
    static func answer(_ card: AnswerCard) -> FlexBox {
        let headline = card.answer.isEmpty ? "\u{2026}" : card.answer
        let echo = card.echo
        return FlexBox(direction: .column, spacing: 8) {
            Text(headline, style: .heading)
            Text(echo, style: .meta, color: .secondary)
        }
        .padding(24)
        .background(.card)
    }

    static func card(
        for result: Identification,
        avatar: (String) -> UIImage?,
        hasFaces: Bool,
        identify: @escaping @Sendable () -> Void,
        dismiss: @escaping @Sendable () -> Void
    ) -> FlexBox {
        switch result {
        case .ready:
            return FlexBox(direction: .column, spacing: 14) {
                FlexBox(direction: .row, spacing: 12, crossAlignment: .center) {
                    Icon(name: .smartGlasses)
                    FlexBox(direction: .column, spacing: 2) {
                        Text("Ready", style: .heading)
                        Text("Look at someone, then identify", style: .meta, color: .secondary)
                    }
                }
                Button(label: "Identify", style: .primary, iconName: .eye, onClick: identify)
            }
            .padding(24)
            .background(.card)

        case .known(let match, _):
            let person = match.person
            let photo = avatar(person.id)
            let details = Array(person.details.prefix(3))
            return FlexBox(direction: .column, spacing: 16) {
                FlexBox(direction: .row, spacing: 14, crossAlignment: .center) {
                    if let photo {
                        Image(image: photo, sizePreset: .icon, cornerRadius: .medium)
                    } else {
                        Icon(name: .personCircle)
                    }
                    FlexBox(direction: .column, spacing: 2) {
                        Text(person.name, style: .heading)
                        Text(person.role, style: .meta, color: .secondary)
                    }
                }
                FlexBox(direction: .column, spacing: 10) {
                    for detail in details {
                        FlexBox(direction: .row, spacing: 10, crossAlignment: .center) {
                            Icon(name: icon(detail.kind), style: .outline)
                            Text(detail.text, style: .body)
                        }
                    }
                }
                ButtonGroup {
                    Button(label: "Done", style: .primary, iconName: .checkmark, onClick: dismiss)
                        .actionRole(.primary)
                    Button(label: "Again", style: .secondary, iconName: .twoArrowsClockwise, onClick: identify)
                }
            }
            .padding(24)
            .background(.card)

        case .unknown:
            return message(icon: .person, title: "No one saved yet", detail: "Add people in the app",
                           identify: identify, dismiss: dismiss)

        case .noFace:
            return message(icon: .eye, title: "No one in view", detail: "Look at them and try again",
                           identify: identify, dismiss: dismiss)
        }
    }

    private static func message(
        icon: IconName, title: String, detail: String,
        identify: @escaping @Sendable () -> Void, dismiss: @escaping @Sendable () -> Void
    ) -> FlexBox {
        FlexBox(direction: .column, spacing: 14) {
            FlexBox(direction: .row, spacing: 12, crossAlignment: .center) {
                Icon(name: icon)
                FlexBox(direction: .column, spacing: 2) {
                    Text(title, style: .heading)
                    Text(detail, style: .meta, color: .secondary)
                }
            }
            ButtonGroup {
                Button(label: "Again", style: .primary, iconName: .twoArrowsClockwise, onClick: identify)
                    .actionRole(.primary)
                Button(label: "Done", style: .secondary, iconName: .checkmark, onClick: dismiss)
            }
        }
        .padding(24)
        .background(.card)
    }

    private static func icon(_ kind: Person.Kind) -> IconName {
        switch kind {
        case .school: .graduationCap
        case .work: .crossBriefcase
        case .from: .house
        case .interests: .heart
        }
    }
}
