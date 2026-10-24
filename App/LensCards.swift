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

    /// The whole identity experience on the lens: who you're looking at (if anyone), and one
    /// row along the bottom with the people-met counter on the left and Identify on the right.
    /// No card behind it, so it floats; Identify is the only control and always has focus,
    /// so a pinch presses it.
    static func hud(
        result: Identification,
        identifying: Bool,
        confirming: Bool,
        connected: Int,
        identify: @escaping @Sendable () -> Void
    ) -> FlexBox {
        let label = identifying ? "Identifying" : confirming ? "Are you sure?" : "Identify"
        let icon: IconName = confirming ? .checkmark : .eye
        let badge = counterBadge(connected)
        let (title, subtitle) = headline(for: result, identifying: identifying)

        return FlexBox(direction: .column, spacing: 18) {
            if let title {
                FlexBox(direction: .column, spacing: 4) {
                    Text(title, style: .heading)
                    if let subtitle { Text(subtitle, style: .meta, color: .secondary) }
                }
            }
            FlexBox(direction: .row, spacing: 8, crossAlignment: .center) {
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
        .padding(20)
    }

    private static func headline(for result: Identification, identifying: Bool) -> (String?, String?) {
        // While identifying, the current person stays up; a stale "No one in view" does not.
        switch result {
        case .known(let match, _): return (match.person.name, match.person.role)
        case .noFace where !identifying: return ("No one in view", "Face them and try again")
        case .unknown where !identifying: return ("No one saved yet", "Add people in the app")
        default: return (nil, nil)
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
