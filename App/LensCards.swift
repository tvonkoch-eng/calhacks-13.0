import MWDATDisplay
import UIKit

/// Everything the lens is being shown, as plain values — the content of a card without its layout.
///
/// The SDK offers no way to read a real display back (`createPreviewView()` exists only for a
/// simulated pair), so the phone cannot screenshot the lens. It can mirror it: `LensCards.hud`
/// renders this and the panel on the phone draws this, both from the same instance captured at
/// the moment the card was built. The content therefore cannot drift; only the pixels differ.
struct LensShot: Equatable {
    /// Which card this is. The layouts differ, not just the words: the idle state is a floating
    /// row with no card behind it; `aid` (conversation aid, with or without who you're talking to)
    /// replaces the row entirely; `compact` is the person shrunk to one line while the aid listens.
    enum Kind: Equatable { case idle, person, message, aid, compact }
    /// A detail line that carries an icon on the lens (school / work / from / interests).
    struct Row: Equatable {
        var icon: String
        var text: String
    }

    var kind: Kind = .idle
    /// Conversation aid: the passing card's title and detail, and the pinned line to say next.
    var answer: String?
    var echo: String?
    var followup: String?
    /// The aid card's icon (a lens IconName raw value), for tool results: cart, cloud, calendar…
    var cardIcon: String?
    /// Work in flight, already worded with its countdown: "Researching GENIUS Act · 6s".
    var working: [String] = []
    var name: String?
    var headline: String?
    /// Person id, so the mirror can look the avatar up the same way the card did.
    var photo: String?
    /// The card is up but its photo hasn't been written yet: the photo's box holds a placeholder.
    var photoPending = false
    var primary: [String] = []
    var details: [Row] = []
    var secondary: [String] = []
    var title: String?
    var subtitle: String?
    var button: String = "Identify"
    /// SF Symbol standing in for the lens icon on the button.
    var buttonIcon: String = "eye"
    var connected: Int = 0
    /// Two or more people in the conversation: their first names in one row, the one talking
    /// marked. One person keeps the photo/name/headline strip above.
    var group: [Member] = []
    /// The wearer is the one talking.
    var meSpeaking = false
}

/// What the Ray-Ban Display lens shows. One root FlexBox per send; keep it glanceable:
/// who they are and three lines of background.
enum LensCards {
    /// The conversation aid's card. With `person` (the face you're talking to is known) a small
    /// strip on top says who; without, the aid's own header (a name they said) as meta. Then the
    /// passing card, title as heading and detail as body, and the pinned line to say next behind
    /// a speech bubble. No Identify row: the aid is brief, and the capture button still identifies.
    static func aid(_ view: LensView, person: Person?, group: [Member] = [], meSpeaking: Bool = false,
                    avatar: (String) -> UIImage?) -> FlexBox {
        let shot = Self.shot(aid: view, person: person, group: group, meSpeaking: meSpeaking)
        let photo = person.flatMap { avatar($0.id) }
        return FlexBox(direction: .column, spacing: 12) {
            if group.count >= 2 {
                groupRow(group, meSpeaking: meSpeaking, avatar: avatar)
            } else if let person {
                FlexBox(direction: .row, spacing: 10, crossAlignment: .center) {
                    if let photo { Image(image: photo, sizePreset: .icon, cornerRadius: .medium) }
                    FlexBox(direction: .column, spacing: 2) {
                        Text(person.name, style: .meta)
                        Text(person.headline, style: .meta, color: .secondary).flexShrink(1)
                    }
                }
            } else if let header = shot.name {
                Text(header, style: .meta, color: .secondary)
            }
            if let title = shot.answer {
                FlexBox(direction: .column, spacing: 4) {
                    if let icon = shot.cardIcon.flatMap(IconName.init(rawValue:)) {
                        FlexBox(direction: .row, spacing: 10, crossAlignment: .center) {
                            Icon(name: icon, style: .outline)
                            Text(title, style: .heading).flexShrink(1)
                        }
                    } else {
                        Text(title, style: .heading).flexShrink(1)
                    }
                    if let detail = shot.echo { Text(detail, style: .body, color: .secondary).flexShrink(1) }
                }
            }
            for line in shot.working {
                FlexBox(direction: .row, spacing: 10, crossAlignment: .center) {
                    Icon(name: .starCircleTriangleAi, style: .outline)
                    Text(line, style: .meta, color: .secondary).flexShrink(1)
                }
            }
            if let followup = shot.followup {
                FlexBox(direction: .row, spacing: 10, crossAlignment: .center) {
                    Icon(name: .speechBubble, style: .outline)
                    Text(followup, style: .body).flexShrink(1)
                }
            }
        }
        .padding(22)
        .background(.card)
    }

    /// Everyone you're talking to, in one row: a photo and a first name each, the speech bubble in
    /// place of the photo for whoever is talking, names dimmed for the rest. Past three, "+N".
    /// "You" leads the row while the wearer talks, so the row always says who has the floor.
    static func groupRow(_ group: [Member], meSpeaking: Bool, avatar: (String) -> UIImage?) -> FlexBox {
        let shown = Array(group.prefix(3))
        return FlexBox(direction: .row, spacing: 18, crossAlignment: .center) {
            if meSpeaking {
                FlexBox(direction: .row, spacing: 6, crossAlignment: .center) {
                    Icon(name: .speechBubble, style: .outline)
                    Text("You", style: .meta)
                }
            }
            for member in shown {
                FlexBox(direction: .row, spacing: 8, crossAlignment: .center) {
                    if member.speaking {
                        Icon(name: .speechBubble, style: .outline)
                    } else if let photo = avatar(member.id) {
                        Image(image: photo, sizePreset: .icon, cornerRadius: .medium)
                    }
                    Text(member.name, style: .meta, color: member.speaking ? .primary : .secondary)
                }
            }
            if group.count > shown.count {
                Text("+\(group.count - shown.count)", style: .meta, color: .secondary)
            }
        }
    }

    /// The group while the aid listens with nothing to show: one line per person, so it's clear
    /// at a glance that this is a conversation with all of them.
    static func compact(group: [Member], meSpeaking: Bool, avatar: (String) -> UIImage?) -> FlexBox {
        let shown = Array(group.prefix(3))
        return FlexBox(direction: .column, spacing: 10) {
            for member in shown {
                FlexBox(direction: .row, spacing: 12, crossAlignment: .center) {
                    if member.speaking {
                        Icon(name: .speechBubble, style: .outline)
                    } else if let photo = avatar(member.id) {
                        Image(image: photo, sizePreset: .icon, cornerRadius: .medium)
                    }
                    FlexBox(direction: .column, spacing: 2) {
                        Text(member.name, style: .body, color: member.speaking || !meSpeaking ? .primary : .secondary)
                        Text(member.headline, style: .meta, color: .secondary).flexShrink(1)
                    }
                }
            }
            if group.count > shown.count {
                Text("+\(group.count - shown.count) more", style: .meta, color: .secondary)
            }
        }
        .padding(20)
        .background(.card)
    }

    /// "Finding Target nearby · 6s", then "· almost there" once past the estimate. The lens can't
    /// animate on its own, so the glasses re-send this once a second while work is in flight.
    static func workLine(_ work: Work, at now: Date) -> String {
        work.remaining(at: now).map { "\(work.label) \u{00B7} \($0)s" } ?? "\(work.label) \u{00B7} almost there"
    }

    /// Who you're talking to, shrunk to one line once their card has been read and the aid is
    /// listening: photo, name, what they do.
    static func compact(_ person: Person, avatar: (String) -> UIImage?, identifying: Bool, connected: Int,
                        identify: @escaping @Sendable () -> Void) -> FlexBox {
        let photo = avatar(person.id)
        return FlexBox(direction: .column, spacing: 14) {
            FlexBox(direction: .row, spacing: 12, crossAlignment: .center) {
                if let photo { Image(image: photo, sizePreset: .icon, cornerRadius: .medium) }
                FlexBox(direction: .column, spacing: 2) {
                    Text(person.name, style: .body)
                    Text(person.headline, style: .meta, color: .secondary).flexShrink(1)
                }
            }
        }
        .padding(20)
        .background(.card)
    }

    /// The identity experience on the lens. Idle: nothing. With someone identified: a card with
    /// their photo, name, role and background. Recognition is automatic, so there is no button
    /// (the glasses' capture button still identifies on demand).
    static func hud(
        result: Identification,
        avatar: (String) -> UIImage?,
        identifying: Bool,
        confirming: Bool,
        connected: Int,
        photoPending: Bool = false,
        identify: @escaping @Sendable () -> Void
    ) -> FlexBox {
        // One description of the card, rendered here and mirrored on the phone.
        let shot = Self.shot(result: result, identifying: identifying, confirming: confirming,
                             connected: connected)

        switch result {
        case .known(let match, _):
            let person = match.person
            // The photo is the heavy part of a write (~430 ms at 288 px on the lens bench, text ~45 ms),
            // so the card goes up first with a placeholder in the photo's box — a 4x4 grey image
            // stretched to the same size, a few bytes — and the photo follows as a second write.
            let photo = photoPending ? Self.placeholder : avatar(person.id)
            // Three text styles exist, with no weights and no colors, so hierarchy is order and
            // emphasis is scarcity: exactly one line is .body -- what they do now -- and the eye
            // finds it because nothing else on the card looks like it.
            let primary = shot.primary
            let secondary = shot.secondary
            // Nobody populated yet: fall back to the old school/work/from rows, so a half-filled
            // people.json still renders something. The shot already made that choice; this only
            // re-reads the rows, because the lens draws an icon per kind and the mirror does not.
            let details = shot.details.isEmpty ? [] : Array(person.details.prefix(3))
            return FlexBox(direction: .column, spacing: 14) {
                FlexBox(direction: .row, spacing: 16, crossAlignment: .start) {
                    // Large: the photo fills a third of the card's width.
                    if let photo {
                        FlexBox(direction: .column) {
                            Image(image: photo, sizePreset: .fill, cornerRadius: .medium)
                        }
                        .flexGrow(1)
                    }
                    FlexBox(direction: .column, spacing: 3) {
                        Text(person.name, style: .heading)
                        Text(person.headline, style: .body).flexShrink(1)
                    }
                    .flexGrow(2)
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
            }
            .padding(22)
            .background(.card)

        default:
            // Recognition is automatic: with nobody on the card, the lens is clear glass.
            return FlexBox(direction: .column) {}
        }
    }

    /// The card's content, with no layout: what `hud` is about to draw, and what the phone panel
    /// mirrors. Pure, so calling it costs nothing and it can be captured on every lens write.
    static func shot(result: Identification, identifying: Bool, confirming: Bool,
                     connected: Int) -> LensShot {
        var shot = LensShot()
        shot.connected = connected
        shot.button = identifying ? "Identifying" : confirming ? "Are you sure?" : "Identify"
        shot.buttonIcon = confirming ? "checkmark" : "eye"
        switch result {
        case .known(let match, _):
            let person = match.person
            shot.kind = .person
            shot.name = person.name
            shot.headline = person.headline
            shot.photo = person.id
            let highlights = Array((person.highlights ?? []).prefix(Self.highlightCount))
            var primary: [String] = []
            if let tie = person.tie, !tie.isEmpty { primary.append(tie) }
            primary += highlights.map { "\u{2014} " + $0 }
            shot.primary = primary
            shot.secondary = [person.personal, person.source].compactMap { $0 }.filter { !$0.isEmpty }
            shot.details = primary.isEmpty
                ? person.details.prefix(3).map { LensShot.Row(icon: symbol($0.kind), text: $0.text) }
                : []
        case .noFace where !identifying, .unknown where !identifying:
            let (title, subtitle) = message(for: result)
            shot.kind = .message
            shot.title = title
            shot.subtitle = subtitle
        default:
            shot.kind = .idle
        }
        return shot
    }

    /// The first write when a face is named: the name and headline alone, no photo, so it reaches
    /// the glasses ahead of the full card, which follows as a second write.
    /// Stands in for the photo until it has been written: same box, almost no bytes.
    static let placeholder: UIImage = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format).image { context in
            UIColor(white: 0.28, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }()

    static func name(_ person: Person) -> FlexBox {
        FlexBox(direction: .column, spacing: 3) {
            Text(person.name, style: .heading)
            Text(person.headline, style: .body).flexShrink(1)
        }
        .padding(22)
        .background(.card)
    }

    static func shot(name person: Person) -> LensShot {
        var shot = LensShot(kind: .person)
        shot.name = person.name
        shot.headline = person.headline
        return shot
    }

    /// The aid's card, as the mirror sees it.
    static func shot(aid view: LensView, person: Person?, group: [Member] = [], meSpeaking: Bool = false) -> LensShot {
        var shot = LensShot(kind: .aid)
        if group.count >= 2 { shot.group = group; shot.meSpeaking = meSpeaking }
        shot.name = person?.name ?? view.header
        shot.headline = person?.headline
        shot.photo = person?.id
        if let card = view.card {
            shot.answer = card.title
            shot.echo = card.detail.isEmpty ? nil : card.detail
            shot.cardIcon = card.icon
        }
        shot.followup = view.followup
        shot.working = view.working.map { workLine($0, at: Date()) }
        return shot
    }

    static func shot(compact group: [Member], meSpeaking: Bool) -> LensShot {
        var shot = LensShot(kind: .compact)
        shot.group = group
        shot.meSpeaking = meSpeaking
        return shot
    }

    static func shot(compact person: Person, identifying: Bool, connected: Int) -> LensShot {
        var shot = LensShot(kind: .compact)
        shot.name = person.name
        shot.headline = person.headline
        shot.photo = person.id
        shot.connected = connected
        shot.button = identifying ? "Identifying" : "Identify"
        return shot
    }

    /// The phone's stand-in for an aid card's lens icon.
    static func symbol(lensIcon: String) -> String {
        switch lensIcon {
        case "cart": "cart"
        case "forkKnife": "fork.knife"
        case "coffeeCup": "cup.and.saucer"
        case "cloud", "cloudLightning", "cloudFiveDashes": "cloud"
        case "bell": "bell"
        case "calendar": "calendar"
        case "clock": "clock"
        case "exclamationCircle": "exclamationmark.circle"
        case "globeWesternHemisphere": "globe.americas"
        case "airplane": "airplane"
        case "cocktailGlass": "wineglass"
        case "crossBriefcase": "cross.case"
        case "house": "house"
        case "museumBuilding": "building.columns"
        case "stadium": "sportscourt"
        case "train": "tram"
        case "tree": "tree"
        default: lensIcon.hasPrefix("cloud") ? "cloud" : "circle"
        }
    }

    /// The SF Symbol that stands in for a lens icon on the phone. The lens icon set is Meta's own;
    /// these are the closest system glyphs, chosen to read the same at a glance.
    static func symbol(_ kind: Person.Kind) -> String {
        switch kind {
        case .school: "graduationcap"
        case .work: "lightbulb"
        case .from: "house"
        case .interests: "heart"
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
    static func counterBadge(_ count: Int) -> UIImage? {
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
