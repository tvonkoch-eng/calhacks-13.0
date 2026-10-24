import MWDATDisplay
import UIKit

/// What the Ray-Ban Display lens shows. One root FlexBox per send.
enum LensCards {
    static func working() -> FlexBox {
        FlexBox(direction: .row, spacing: 10, crossAlignment: .center) {
            Icon(name: .eye)
            Text("Identifying…", style: .heading)
        }
        .padding(20)
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
            return FlexBox(direction: .column, spacing: 10) {
                FlexBox(direction: .row, spacing: 10, crossAlignment: .center) {
                    Icon(name: .eye)
                    Text("Ready", style: .heading)
                }
                Text(hasFaces ? "Look at someone, then press Identify" : "No faces saved yet. Add them in the phone app",
                     style: .meta, color: .secondary)
                Button(label: "Identify", style: .primary, iconName: .eye, onClick: identify)
            }
            .padding(20)
            .background(.card)

        case .known(let match, _):
            let person = match.person
            let photo = avatar(person.id)
            let details = person.details
            return FlexBox(direction: .column, spacing: 12) {
                FlexBox(direction: .row, spacing: 12, crossAlignment: .center) {
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
                for detail in details {
                    FlexBox(direction: .row, spacing: 8, crossAlignment: .center) {
                        Icon(name: icon(detail.kind), style: .outline)
                        Text(detail.text, style: .body)
                    }
                }
                ButtonGroup {
                    Button(label: "Again", style: .secondary, iconName: .twoArrowsClockwise, onClick: identify)
                    Button(label: "Done", style: .outline, iconName: .checkmark, onClick: dismiss)
                }
            }
            .padding(20)
            .background(.card)

        case .unknown:
            return message(
                icon: .person,
                title: hasFaces ? "Not in your contacts" : "No faces saved yet",
                detail: hasFaces ? "Save them from the phone app" : "Add photos in the phone app",
                identify: identify, dismiss: dismiss
            )

        case .noFace:
            return message(icon: .eye, title: "No face in view", detail: "Face them and try again",
                           identify: identify, dismiss: dismiss)
        }
    }

    private static func message(
        icon: IconName, title: String, detail: String,
        identify: @escaping @Sendable () -> Void, dismiss: @escaping @Sendable () -> Void
    ) -> FlexBox {
        FlexBox(direction: .column, spacing: 10) {
            FlexBox(direction: .row, spacing: 10, crossAlignment: .center) {
                Icon(name: icon)
                Text(title, style: .heading)
            }
            Text(detail, style: .meta, color: .secondary)
            ButtonGroup {
                Button(label: "Again", style: .secondary, iconName: .twoArrowsClockwise, onClick: identify)
                Button(label: "Done", style: .outline, iconName: .checkmark, onClick: dismiss)
            }
        }
        .padding(20)
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
