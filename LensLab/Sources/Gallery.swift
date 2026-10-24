import MWDATDisplay
import UIKit

/// Every page is one root FlexBox, which is all the lens accepts per send.
struct LensPage {
    let title: String
    var section = "Components"
    /// `go(index)` moves the lens to another page, so buttons can drive a flow.
    let view: (_ go: @escaping @Sendable (Int) -> Void) -> FlexBox
}

enum Gallery {
    static let face = UIImage(named: "avi.png")
    static let noop: @Sendable () -> Void = {}

    static let pages: [LensPage] = Experience.pages + components

    static let components: [LensPage] = [
        LensPage(title: "Person card") { _ in
            FlexBox(direction: .column, spacing: 16) {
                FlexBox(direction: .row, spacing: 14, crossAlignment: .center) {
                    if let face { Image(image: face, sizePreset: .icon, cornerRadius: .medium) }
                    FlexBox(direction: .column, spacing: 2) {
                        Text("Avi Shah", style: .heading)
                        Text("LSE Economics, year abroad at UCSB", style: .meta, color: .secondary)
                    }
                }
                FlexBox(direction: .column, spacing: 10) {
                    row(.graduationCap, "LSE · Economics")
                    row(.crossBriefcase, "Summer Analyst · BofA London")
                    row(.house, "London")
                }
                ButtonGroup {
                    Button(label: "Done", style: .primary, iconName: .checkmark, onClick: noop).actionRole(.primary)
                    Button(label: "Again", style: .secondary, iconName: .twoArrowsClockwise, onClick: noop)
                }
            }
            .padding(24).background(.card)
        },
        LensPage(title: "Live answer") { _ in
            FlexBox(direction: .column, spacing: 8) {
                Text("330 meters", style: .heading)
                Text("how tall is the eiffel tower", style: .meta, color: .secondary)
            }
            .padding(24).background(.card)
        },
        LensPage(title: "Text styles") { _ in
            FlexBox(direction: .column, spacing: 10) {
                Text("Heading · primary", style: .heading)
                Text("Heading · secondary", style: .heading, color: .secondary)
                Text("Body · primary. Longer body text wraps onto a second line when it runs out of width.", style: .body)
                Text("Body · secondary", style: .body, color: .secondary)
                Text("Meta · primary", style: .meta)
                Text("Meta · secondary", style: .meta, color: .secondary)
            }
            .padding(24).background(.card)
        },
        LensPage(title: "Icons") { _ in
            FlexBox(direction: .row, spacing: 14, wrap: true) {
                for name in icons { Icon(name: name) }
                for name in icons.prefix(8) { Icon(name: name, style: .outline) }
            }
            .padding(24).background(.card)
        },
        LensPage(title: "Buttons") { _ in
            FlexBox(direction: .column, spacing: 14) {
                Button(label: "Primary", style: .primary, iconName: .checkmark, onClick: noop)
                Button(label: "Secondary", style: .secondary, iconName: .speechBubble, onClick: noop)
                Button(label: "Outline", style: .outline, onClick: noop)
                ButtonGroup {
                    Button(label: "Save", style: .primary, iconName: .plus, onClick: noop).actionRole(.primary)
                    Button(label: "Later", style: .secondary, iconName: .clock, onClick: noop)
                    Button(label: "No", style: .outline, iconName: .x, onClick: noop)
                }
            }
            .padding(24).background(.card)
        },
        LensPage(title: "Layout") { _ in
            FlexBox(direction: .column, spacing: 12) {
                Text("Row · start / center / end", style: .meta, color: .secondary)
                FlexBox(direction: .row, spacing: 8, alignment: .start) { Icon(name: .star); Text("start", style: .body) }
                FlexBox(direction: .row, spacing: 8, alignment: .center) { Icon(name: .star); Text("center", style: .body) }
                FlexBox(direction: .row, spacing: 8, alignment: .end) { Icon(name: .star); Text("end", style: .body) }
                Text("No background (floats on the lens)", style: .meta, color: .secondary)
                FlexBox(direction: .row, spacing: 8) { Icon(name: .heart); Text("background: none", style: .body) }
                    .padding(8).background(.none)
            }
            .padding(24).background(.card)
        },
        LensPage(title: "Recents list") { _ in
            FlexBox(direction: .column, spacing: 12) {
                Text("Recent", style: .heading)
                person("Avi Shah", "Just now", current: true)
                person("Mirabelle Brown", "16 min ago", current: false)
                person("Joaquin Del Pego", "2 hr ago", current: false)
            }
            .padding(24).background(.card)
        },
        LensPage(title: "Notification") { _ in
            FlexBox(direction: .row, spacing: 12, crossAlignment: .center) {
                Icon(name: .bell)
                FlexBox(direction: .column, spacing: 2) {
                    Text("Joaquin is nearby", style: .body)
                    Text("Last talked 2 hr ago", style: .meta, color: .secondary)
                }
            }
            .padding(16).background(.card)
        },
        LensPage(title: "Floating (no card)") { _ in
            FlexBox(direction: .column, spacing: 6) {
                Text("Avi Shah", style: .heading)
                Text("LSE Economics · from London", style: .body, color: .secondary)
            }
            .padding(24)
        },
        LensPage(title: "Large photo") { _ in
            FlexBox(direction: .row, spacing: 16, crossAlignment: .center) {
                if let face { Image(image: face, sizePreset: .fill, cornerRadius: .medium) }
                FlexBox(direction: .column, spacing: 4) {
                    Text("Avi Shah", style: .heading)
                    Text("Just now", style: .meta, color: .secondary)
                }
            }
            .padding(24).background(.card)
        },
    ]

    static let icons: [IconName] = [
        .person, .personCircle, .threePeopleOverlapping, .speechBubble, .threeDotSpeechBubble,
        .eye, .smartGlasses, .metaAi, .magicWand, .starCircleTriangleAi, .graduationCap,
        .crossBriefcase, .house, .heart, .star, .calendar, .clock, .bell, .envelopeOpen,
        .phone, .globeWesternHemisphere, .lightBulb, .checkmark, .checkmarkCircle, .x,
        .plus, .gear, .twoArrowsClockwise, .exclamationTriangle, .iCircle,
    ]

    static func row(_ icon: IconName, _ text: String) -> FlexBox {
        FlexBox(direction: .row, spacing: 10, crossAlignment: .center) {
            Icon(name: icon, style: .outline)
            Text(text, style: .body)
        }
    }

    static func person(_ name: String, _ when: String, current: Bool) -> FlexBox {
        FlexBox(direction: .row, spacing: 10, crossAlignment: .center) {
            Icon(name: current ? .personCircle : .person, style: current ? .filled : .outline)
            Text(name, style: .body, color: current ? .primary : .secondary).flexGrow(1)
            Text(when, style: .meta, color: .secondary)
        }
    }
}
