import MWDATDisplay
import UIKit

/// What the Ray-Ban Display lens shows. One root FlexBox per send; keep it glanceable:
/// who they are and three lines of background.
enum LensCards {
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

    /// The identity experience on the lens. Idle: just the bottom row, floating. With someone
    /// identified: a card with their photo, name, role and background, over the same bottom row.
    /// The bottom row is the people-met counter on the left and Identify on the right; Identify is
    /// the only control and always has focus, so a pinch presses it.
    static func hud(
        result: Identification,
        avatar: (String) -> UIImage?,
        identifying: Bool,
        confirming: Bool,
        connected: Int,
        identify: @escaping @Sendable () -> Void
    ) -> FlexBox {
        let label = identifying ? "Identifying" : confirming ? "Are you sure?" : "Identify"
        let bottom = bottomRow(label: label, icon: confirming ? .checkmark : .eye, connected: connected, identify: identify)

        switch result {
        case .known(let match, _):
            let person = match.person
            let photo = avatar(person.id)
            // Three text styles exist, with no weights and no colors, so hierarchy is order and
            // emphasis is scarcity: exactly one line is .body -- what they do now -- and the eye
            // finds it because nothing else on the card looks like it.
            let highlights = Array((person.highlights ?? []).prefix(Self.highlightCount))
            var primary: [String] = []
            if let tie = person.tie, !tie.isEmpty { primary.append(tie) }
            primary += highlights.map { "\u{2014} " + $0 }
            let secondary = [person.personal, person.source].compactMap { $0 }.filter { !$0.isEmpty }
            // Nobody populated yet: fall back to the old school/work/from rows, so a half-filled
            // people.json still renders something.
            let details = primary.isEmpty ? Array(person.details.prefix(3)) : []
            return FlexBox(direction: .column, spacing: 14) {
                FlexBox(direction: .row, spacing: 14, crossAlignment: .center) {
                    if let photo { Image(image: photo, sizePreset: .icon, cornerRadius: .medium) }
                    FlexBox(direction: .column, spacing: 3) {
                        Text(person.name, style: .heading)
                        Text(person.headline, style: .body).flexShrink(1)
                    }
                }
                FlexBox(direction: .column, spacing: 7) {
                    for line in primary {
                        Text(line, style: .meta).flexShrink(1)
                    }
                    for detail in details {
                        FlexBox(direction: .row, spacing: 10, crossAlignment: .center) {
                            Icon(name: icon(detail.kind), style: .outline)
                            Text(detail.text, style: .body).flexShrink(1)
                        }
                    }
                    for line in secondary {
                        Text(line, style: .meta, color: .secondary).flexShrink(1)
                    }
                }
                bottom
            }
            .padding(22)
            .background(.card)

        case .noFace where !identifying, .unknown where !identifying:
            let (title, subtitle) = message(for: result)
            return FlexBox(direction: .column, spacing: 16) {
                FlexBox(direction: .column, spacing: 4) {
                    Text(title, style: .heading)
                    Text(subtitle, style: .meta, color: .secondary)
                }
                bottom
            }
            .padding(22)
            .background(.card)

        default:
            return FlexBox(direction: .column) { bottom }.padding(20)
        }
    }

    private static func bottomRow(label: String, icon: IconName, connected: Int,
                                  identify: @escaping @Sendable () -> Void) -> FlexBox {
        let badge = counterBadge(connected)
        return FlexBox(direction: .row, spacing: 8, crossAlignment: .center) {
            FlexBox(direction: .row, spacing: 6, crossAlignment: .center) {
                Icon(name: .person, style: .outline)
                if let badge { Image(image: badge, sizePreset: .icon) }
            }
            .flexGrow(1)
            ButtonGroup(alignment: .end) {
                Button(label: label, style: .primary, iconName: icon, onClick: identify)
                    .actionRole(.primary)
            }
        }
    }

    private static func message(for result: Identification) -> (String, String) {
        // A face we saw but would not stake a name on. Saying so beats naming the wrong person.
        if case .unknown = result { return ("Not sure who that is", "Get closer and press again") }
        return ("No one in view", "Face them and try again")
    }

    /// How many highlights fit under the name. The panel is 600x600 and the card also carries a
    /// photo row and the Identify row, so three is the ceiling in practice. Tunable on the phone
    /// with UserDefaults key "lensHighlights", no rebuild.
    private static var highlightCount: Int {
        let n = UserDefaults.standard.integer(forKey: "lensHighlights")
        return n > 0 ? n : 3
    }

    /// No plain briefcase exists in the lens icon set (crossBriefcase is a first-aid kit).
    private static func icon(_ kind: Person.Kind) -> IconName {
        switch kind {
        case .school: .graduationCap
        case .work: .lightBulb
        case .from: .house
        case .interests: .heart
        }
    }

    /// A small green tag with the count in it. The lens text has no colors, so the tag is drawn.
    private static func counterBadge(_ count: Int) -> UIImage? {
        let size = CGSize(width: 48, height: 48)
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIColor(red: 0.20, green: 0.78, blue: 0.45, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
            let text = "\(count)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: count > 9 ? 22 : 28, weight: .bold),
                .foregroundColor: UIColor.white,
            ]
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
                      withAttributes: attributes)
        }
    }
}
