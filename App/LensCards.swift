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
    enum Kind: Equatable { case idle, person, message, aid, compact, split }
    /// A detail line that carries an icon on the lens (school / work / from / interests).
    struct Row: Equatable {
        var icon: String
        var text: String
    }

    var kind: Kind = .idle
    /// One aid card as text: what `LensCards.cardBox` draws and the mirror redraws.
    struct CardText: Equatable {
        var title: String
        var detail: String?
        var icon: String?
    }

    /// The aid's cards, newest first. `answer`/`echo`/`cardIcon` repeat the newest one.
    var cards: [CardText] = []
    /// Conversation aid: the newest card's title and detail, and the pinned line to say next.
    var answer: String?
    var echo: String?
    var followup: String?
    /// The aid card's icon (a lens IconName raw value), for tool results: cart, cloud, calendar…
    var cardIcon: String?
    /// Work in flight, already worded with its countdown: "Researching GENIUS Act · 6s".
    var working: [String] = []
    var name: String?
    var headline: String?
    /// One line of context under the person at the bottom of the split lens.
    var context: String?
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
    /// One line from the CRM for a person's card ("You said: Send Avi the deck"). Set by Assistant.
    nonisolated(unsafe) static var recall: ((String) -> String?)?

    /// The lens while the aid listens: the aid's cards at the very top, newest first, who you're
    /// talking to pinned at the bottom, glass in between. The real renderer sizes the root to its
    /// content and sits it on the floor of the panel, so a growing spacer alone collapses and the
    /// cards land right on top of the person, mid-lens. The spacer therefore also gets an explicit
    /// height: what's left of the panel after an estimate of everything else (`LensFit`).
    static func split(_ view: LensView, person: Person?, group: [Member] = [], meSpeaking: Bool = false,
                      photoPending: Bool = false, avatar: (String) -> UIImage?) -> FlexBox {
        let shot = Self.shot(split: view, person: person, group: group, meSpeaking: meSpeaking)
        let gap = LensFit.gap(shot, bottom: bottom(person: person, group: group))
        return FlexBox(direction: .column, spacing: LensFit.spacing) {
            for (index, card) in shot.cards.enumerated() { cardBox(card, newest: index == 0) }
            // Always up, blank until there's something to say: the top third is the suggestions'.
            // It stretches down to the people, so the top third is one solid box: no glass between.
            extrasBox(shot, fill: gap)
            // The people have the bottom two-thirds: one card taking all of it, or two side by side.
            if shot.group.count >= 2 {
                groupCards(shot.group, avatar: avatar)
            } else if let person {
                // The photo is written after the card (`photoPending`), so the name lands first.
                personCard(person, shot: shot, avatar: { photoPending ? nil : avatar($0) })
            }
        }
        .flexGrow(1)
    }

    /// The bottom half, one person: the photo at the top, the name and what they do at the foot,
    /// with the space between filled so the card reads as tall as the half it sits in.
    static func personCard(_ person: Person, shot: LensShot, avatar: (String) -> UIImage?) -> FlexBox {
        FlexBox(direction: .column, spacing: 10) {
            header(photo: avatar(person.id), name: person.name, width: LensFit.personWidth, bright: true)
            // Why they matter, straight under the header: every bullet that fits.
            for line in shot.primary {
                Text(line, style: .body).flexShrink(1)
            }
            FlexBox(direction: .column) {}.padding(.top, LensFit.person(person, lines: shot.primary).left)
        }
        .padding(22)
        .background(.card)
    }

    enum Bottom { case none, person, group }

    static func bottom(person: Person?, group: [Member]) -> Bottom {
        group.count >= 2 ? .group : person != nil ? .person : .none
    }

    /// One passing card. The newest reads as a heading over its detail; an older one steps down
    /// (title as body, detail as meta), so the eye lands on what just came in.
    private static func cardBox(_ card: LensShot.CardText, newest: Bool) -> FlexBox {
        FlexBox(direction: .column, spacing: 4) {
            if let icon = card.icon.flatMap(IconName.init(rawValue:)) {
                FlexBox(direction: .row, spacing: 10, crossAlignment: .center) {
                    Icon(name: icon, style: .outline)
                    Text(card.title, style: newest ? .heading : .body).flexShrink(1)
                }
            } else {
                Text(card.title, style: newest ? .heading : .body).flexShrink(1)
            }
            if let detail = card.detail {
                Text(detail, style: newest ? .body : .meta, color: .secondary).flexShrink(1)
            }
        }
        .padding(20)
        // No card behind it: the aid's text sits on the glass.
    }

    /// Work in flight and the line to say next, under the cards.
    private static func extrasBox(_ shot: LensShot, fill: CGFloat = 0) -> FlexBox {
        FlexBox(direction: .column, spacing: 10) {
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
            let blank = shot.working.isEmpty && shot.followup == nil && shot.cards.isEmpty ? LensFit.blank : 0
            if blank + fill > 0 {
                FlexBox(direction: .column) {}.padding(.top, blank + fill)
            }
        }
        .padding(20)
        // No card behind it: the aid's text sits on the glass.
    }

    /// Everyone you're talking to, in one row: a photo and a first name each, the speech bubble in
    /// place of the photo for whoever is talking, names dimmed for the rest. Past three, "+N".
    /// "You" leads the row while the wearer talks, so the row always says who has the floor.
    /// A conversation of several: one card each, a quarter of the lens, side by side. Photo at the
    /// top, name and headline at the foot. Whoever is talking has the brighter name; no bubble.
    static func groupCards(_ group: [Member], avatar: (String) -> UIImage?) -> FlexBox {
        FlexBox(direction: .row, spacing: 12) {
            for member in group.prefix(2) {
                FlexBox(direction: .column, spacing: 8) {
                    header(photo: avatar(member.id), name: member.fullName.isEmpty ? member.name : member.fullName,
                           width: LensFit.memberWidth, bright: member.speaking)
                    for line in member.lines {
                        Text(line, style: .meta).flexShrink(1)
                    }
                    FlexBox(direction: .column) {}.padding(.top, LensFit.member(member, lines: member.lines).left)
                }
                .padding(22)
                .background(.card)
                .flexGrow(1)
                .flexShrink(1)
            }
        }
    }

    /// The photo on the left, sized to stand as tall as the full name beside it; everything else
    /// is bullets below. The lens has only icon-sized or filling images, so the photo fills a
    /// share of the row.
    private static func header(photo: UIImage?, name: String, width: CGFloat, bright: Bool) -> FlexBox {
        let share = Float(LensFit.photoShare(width))
        return FlexBox(direction: .row, spacing: LensFit.photoGap, crossAlignment: .center) {
            if let photo {
                FlexBox(direction: .column) { Image(image: photo, sizePreset: .fill, cornerRadius: .medium) }
                    .flexGrow(share).flexShrink(0)
            }
            FlexBox(direction: .column) {
                Text(twoLines(name), style: .heading, color: bright ? .primary : .secondary).flexShrink(1)
            }
            .flexGrow(1 - share).flexShrink(1)
        }
    }

    /// First name over the rest, so every name stands two lines tall beside its photo.
    static func twoLines(_ name: String) -> String {
        guard let space = name.firstIndex(of: " ") else { return name }
        return name[..<space] + "\n" + name[name.index(after: space)...].trimmingCharacters(in: .whitespaces)
    }

    /// A headline cut to fit half the lens: "Founder, Rillet (YC W24)" → "Founder, Rillet…".
    static func short(_ text: String, max: Int = 22) -> String {
        guard text.count > max else { return text }
        let cut = text.prefix(max)
        let word = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
        return word.trimmingCharacters(in: CharacterSet(charactersIn: " ,·-")) + "\u{2026}"
    }

    static func groupRow(_ group: [Member], meSpeaking: Bool, avatar: (String) -> UIImage?) -> FlexBox {
        let shown = Array(group.prefix(3))
        return FlexBox(direction: .row, spacing: 18, crossAlignment: .center) {
            if meSpeaking {
                Text("You", style: .meta)
            }
            for member in shown {
                FlexBox(direction: .row, spacing: 8, crossAlignment: .center) {
                    if let photo = avatar(member.id) {
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

    /// "Finding Target nearby · 6s", then "· almost there" once past the estimate. The lens can't
    /// animate on its own, so the glasses re-send this once a second while work is in flight.
    static func workLine(_ work: Work, at now: Date) -> String {
        work.remaining(at: now).map { "\(work.label) \u{00B7} \($0)s" } ?? "\(work.label) \u{00B7} almost there"
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
            // so the card goes up first with the photo's column held empty — no image at all — and
            // the photo follows as a second write.
            let photo = photoPending ? nil : avatar(person.id)
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
                    if photoPending || photo != nil {
                        FlexBox(direction: .column) {
                            if let photo {
                                Image(image: photo, sizePreset: .fill, cornerRadius: .medium)
                            } else {
                                Text(" ", style: .meta)
                            }
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
            // What you owe them, or talked about last (the CRM), before the background lines.
            shot.secondary = [recall?(person.id), person.personal, person.source].compactMap { $0 }.filter { !$0.isEmpty }
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
        shot.cards = view.cards.map { LensShot.CardText(title: $0.title, detail: $0.detail.isEmpty ? nil : $0.detail, icon: $0.icon) }
        if let card = view.card {
            shot.answer = card.title
            shot.echo = card.detail.isEmpty ? nil : card.detail
            shot.cardIcon = card.icon
        }
        shot.followup = view.followup
        shot.working = view.working.map { workLine($0, at: Date()) }
        return shot
    }

    /// The split lens, as the mirror sees it.
    static func shot(split view: LensView, person: Person?, group: [Member] = [], meSpeaking: Bool = false) -> LensShot {
        var shot = shot(aid: view, person: person, group: group, meSpeaking: meSpeaking)
        shot.kind = .split
        // What doesn't fit goes here, once, so the glass and the mirror drop the same thing.
        _ = LensFit.fit(&shot, bottom: bottom(person: person, group: group))
        if group.count >= 2 {
            // Each card gets every line that fits its own height as it wraps, and no more.
            shot.group = shot.group.map { member in
                var member = member
                member.lines = LensFit.member(member, lines: member.lines).lines
                return member
            }
        } else if let person {
            // Every line that fits the person's two-thirds as it wraps, and no more.
            let pool = info(person)
            shot.primary = LensFit.person(person, lines: pool).lines
            shot.context = pool.first
        }
        if let newest = shot.cards.first {
            shot.answer = newest.title
            shot.echo = newest.detail
            shot.cardIcon = newest.icon
        }
        return shot
    }

    /// Everything worth a line about someone, most telling first: recall, tie, highlights, details.
    static func info(_ person: Person) -> [String] {
        // What they do now leads; then how you know them, what you owe them, their best work,
        // and the rest of their background, each once.
        var pool: [String] = [person.headline]
        if let tie = person.tie { pool.append(tie) }
        if let recall = recall?(person.id) { pool.append(recall) }
        pool += person.highlights ?? []
        pool += person.details.map(\.text)
        if let personal = person.personal { pool.append(personal) }
        var seen = Set<String>()
        return pool.filter { !$0.isEmpty && seen.insert($0).inserted }.map { "\u{2022} " + $0 }
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

/// How tall the split lens's pieces come out, estimated with the system font at the sizes the
/// mirror was trued to (`LensMetrics`), so the cards can be pushed to the top of a panel whose
/// renderer won't stretch a spacer. It errs tall: an overestimate only leaves the cards a little
/// below the top edge, an underestimate would make the root taller than the panel.
enum LensFit {
    static let panel: CGFloat = 600
    /// The renderer's own gap under the root (`LensMetrics.bottom`).
    static let floor: CGFloat = 34
    static let spacing: CGFloat = 14
    /// Slack for the estimate: wrapping in Meta's typeface vs the system font.
    static let slack: CGFloat = 1.1
    static let margin: CGFloat = 16

    /// The aid's cards take the top third of the lens when there are people to show, and the people
    /// the bottom two-thirds, so their cards carry the most. `half` is what the bottom takes.
    static var half: CGFloat { available * 2 / 3 }
    /// Padding, photo, name and one headline line: what a person card takes before its fill.
    static let cardBase: CGFloat = 190

    /// Room left for the aid's cards: the top half when there are people, the whole lens when not.
    static func room(_ bottom: LensCards.Bottom) -> CGFloat { bottom == .none ? available : available - half }

    /// The space a people card needs filling down to the half: its base, plus a line for each text
    /// line that sits between the photo and the name.
    static func fill(lines: Int, room: CGFloat = half) -> CGFloat {
        max(0, room - cardBase - 26 * CGFloat(lines))
    }

    /// The person card's height in the split: the bottom half, grown into whatever the aid leaves.
    /// Fixed at the bottom share: the top is the suggestions', so the person never grows into it.
    static func personRoom(_ shot: LensShot) -> CGFloat { half }

    /// The empty suggestions box's inner height: one body line.
    static let blank: CGFloat = 30

    /// A person card's lines: those from `pool` that fit its height measured as they wrap, and the
    /// height left over, which goes between the photo and the name.
    static func person(_ person: Person, lines pool: [String]) -> (lines: [String], left: CGFloat) {
        take(pool, name: person.name, width: personWidth, font: body, gap: 10)
    }

    /// The same for one of two side-by-side cards.
    static func member(_ member: Member, lines pool: [String]) -> (lines: [String], left: CGFloat) {
        take(pool, name: member.fullName.isEmpty ? member.name : member.fullName,
             width: memberWidth, font: meta, gap: 8)
    }

    /// Inner widths of the one-person card and of each of two side-by-side cards.
    static let personWidth: CGFloat = panel - 44
    static let memberWidth: CGFloat = (panel - 12) / 2 - 44
    static let photoGap: CGFloat = 14

    /// The photo's share of the header row: tall enough for a full name on two heading lines.
    static func photoShare(_ width: CGFloat) -> CGFloat { width > 400 ? 0.2 : 0.38 }

    private static func take(_ pool: [String], name: String, width: CGFloat,
                             font: UIFont, gap: CGFloat) -> (lines: [String], left: CGFloat) {
        // Padding, then the header: the photo, or the name beside it if taller.
        let photo = (width - photoGap) * photoShare(width)
        let header = max(photo, lines(LensCards.twoLines(name), heading, width - photoGap - photo) * slack)
        var left = half - (44 + header + gap)
        var out: [String] = []
        for line in pool {
            let h = lines(line, font, width) * slack + gap
            // Too tall here, but a shorter one further down may still fit.
            if h > left { continue }
            left -= h
            out.append(line)
        }
        return (out, max(0, left.rounded(.down)))
    }

    /// Drops what won't fit in the aid's room (an older card's detail, then the older card) and
    /// returns the spacer's height.
    static func fit(_ shot: inout LensShot, bottom: LensCards.Bottom) -> CGFloat {
        // The newest card always stays: it is the answer they're waiting for. Older ones lose their
        // detail, then go; last of all the newest gives up its echo of the question.
        while content(shot, bottom: bottom) > room(bottom) {
            let last = shot.cards.count - 1
            if last < 0 { break }
            if shot.cards[last].detail != nil {
                shot.cards[last].detail = nil
            } else if last > 0 {
                shot.cards.removeLast()
            } else {
                break
            }
        }
        return gap(shot, bottom: bottom)
    }

    static func gap(_ shot: LensShot, bottom: LensCards.Bottom) -> CGFloat {
        let aid = bottom == .person ? available - personRoom(shot) : room(bottom)
        return max(0, (aid - content(shot, bottom: bottom)).rounded(.down))
    }

    private static var available: CGFloat { panel - floor - margin }

    /// The aid's part only: the cards and the extras, spacing included.
    static func content(_ shot: LensShot, bottom: LensCards.Bottom) -> CGFloat {
        let width = panel - 40
        var pieces: [CGFloat] = shot.cards.enumerated().map { index, card in
            let newest = index == 0
            let titleWidth = card.icon == nil ? width : width - 38
            var h = 40 + lines(card.title, newest ? heading : body, titleWidth)
            if let detail = card.detail { h += 4 + lines(detail, newest ? body : meta, width) }
            return h
        }
        if shot.working.isEmpty && shot.followup == nil {
            // The blank box only holds its line open when there is nothing else up top.
            pieces.append(40 + (shot.cards.isEmpty ? blank : 0))
        } else {
            var h: CGFloat = 40
            h += shot.working.map { lines($0, meta, width - 38) + 10 }.reduce(0, +)
            if let followup = shot.followup { h += lines(followup, body, width - 38) } else { h -= 10 }
            pieces.append(h)
        }
        // The spacer sits between them, so it adds one more gap.
        let gaps = CGFloat(pieces.count) * spacing
        return pieces.reduce(0, +) * slack + gaps
    }

    private static let heading = UIFont.systemFont(ofSize: 34, weight: .semibold)
    private static let body = UIFont.systemFont(ofSize: 25)
    private static let meta = UIFont.systemFont(ofSize: 21)

    private static func lines(_ text: String, _ font: UIFont, _ width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let box = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                  options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                  attributes: [.font: font], context: nil)
        return ceil(box.height)
    }
}
