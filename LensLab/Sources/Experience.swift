import MWDATDisplay
import UIKit

/// A designed walk-through of the product on the lens. Primary buttons advance the story,
/// so it can be clicked through in the preview like the real thing.
enum Experience {
    static let avi = UIImage(named: "avi.png")
    static let mirabelle = UIImage(named: "mirabelle.jpeg")

    static let pages: [LensPage] = [
        // 1. The instant a face matches: just the name, floating, nothing to dismiss.
        LensPage(title: "Recognized", section: "Experience") { go in
            FlexBox(direction: .column, spacing: 4) {
                FlexBox(direction: .row, spacing: 8, crossAlignment: .center) {
                    Icon(name: .smartGlasses, style: .outline)
                    Text("Recognized", style: .meta, color: .secondary)
                }
                Text("Avi Shah", style: .heading)
                Text("LSE Economics · year abroad at UCSB", style: .body, color: .secondary)
            }
            .padding(24)
            .onTap { go(1) }
        },

        // 2. Who they are, in three lines.
        LensPage(title: "Person", section: "Experience") { go in
            FlexBox(direction: .column, spacing: 16) {
                FlexBox(direction: .row, spacing: 14, crossAlignment: .center) {
                    if let avi { Image(image: avi, sizePreset: .icon, cornerRadius: .medium) }
                    FlexBox(direction: .column, spacing: 2) {
                        Text("Avi Shah", style: .heading)
                        Text("Met 3 times · last 2 hr ago", style: .meta, color: .secondary)
                    }
                }
                FlexBox(direction: .column, spacing: 10) {
                    line(.graduationCap, "LSE · Economics")
                    line(.lightBulb, "Summer Analyst, BofA London")
                    line(.house, "From London")
                }
                ButtonGroup {
                    Button(label: "Context", style: .primary, iconName: .iCircle) { go(2) }.actionRole(.primary)
                    Button(label: "Done", style: .secondary, iconName: .checkmark) { go(0) }
                }
            }
            .padding(24).background(.card)
        },

        // 3. What you share and where you left off: the CRM, on your face.
        LensPage(title: "Context", section: "Experience") { go in
            FlexBox(direction: .column, spacing: 14) {
                Text("Where you left off", style: .meta, color: .secondary)
                FlexBox(direction: .column, spacing: 10) {
                    line(.threePeopleOverlapping, "Teammates at Cal Hacks 13.0")
                    line(.calendar, "Last talked today, 6:40 PM")
                    line(.pencil, "Owes you the demo script")
                }
                ButtonGroup {
                    Button(label: "Ask", style: .primary, iconName: .metaAi) { go(3) }.actionRole(.primary)
                    Button(label: "Back", style: .secondary, iconName: .arrowLeft) { go(1) }
                }
            }
            .padding(24).background(.card)
        },

        // 4. A question someone just asked, answered before they finish.
        LensPage(title: "Live answer", section: "Experience") { go in
            FlexBox(direction: .column, spacing: 10) {
                FlexBox(direction: .row, spacing: 8, crossAlignment: .center) {
                    Icon(name: .metaAi)
                    Text("how tall is the eiffel tower", style: .meta, color: .secondary)
                }
                Text("330 meters", style: .heading)
                Text("Including antennas · completed in 1889", style: .body, color: .secondary)
            }
            .padding(24).background(.card)
            .onTap { go(4) }
        },

        // 5. A spoken note, confirmed without breaking eye contact.
        LensPage(title: "Note saved", section: "Experience") { go in
            FlexBox(direction: .row, spacing: 12, crossAlignment: .center) {
                Icon(name: .checkmarkCircle)
                FlexBox(direction: .column, spacing: 2) {
                    Text("Saved to Avi", style: .body)
                    Text("Send him the pitch deck tonight", style: .meta, color: .secondary)
                }
            }
            .padding(18).background(.card)
            .onTap { go(5) }
        },

        // 6. The follow-up, offered when the conversation ends.
        LensPage(title: "Follow-up", section: "Experience") { go in
            FlexBox(direction: .column, spacing: 14) {
                FlexBox(direction: .row, spacing: 14, crossAlignment: .center) {
                    if let mirabelle { Image(image: mirabelle, sizePreset: .icon, cornerRadius: .medium) }
                    FlexBox(direction: .column, spacing: 2) {
                        Text("Follow up with Mirabelle", style: .heading)
                        Text("Tomorrow · 10:00 AM", style: .meta, color: .secondary)
                    }
                }
                ButtonGroup {
                    Button(label: "Add to calendar", style: .primary, iconName: .calendar) { go(6) }.actionRole(.primary)
                    Button(label: "Later", style: .secondary, iconName: .clock) { go(6) }
                }
            }
            .padding(24).background(.card)
        },

        // 7. Who you've met tonight.
        LensPage(title: "Tonight", section: "Experience") { go in
            FlexBox(direction: .column, spacing: 12) {
                FlexBox(direction: .row, spacing: 8, crossAlignment: .center) {
                    Text("Tonight", style: .heading).flexGrow(1)
                    Text("3 people", style: .meta, color: .secondary)
                }
                recent("Avi Shah", "LSE · BofA London", "now", strong: true)
                recent("Mirabelle Brown", "UCSB · Financial Math", "16 min", strong: false)
                recent("Joaquin Del Pego", "UCSB · LegalTime AI", "2 hr", strong: false)
            }
            .padding(24).background(.card)
            .onTap { go(0) }
        },
    ]

    private static func line(_ icon: IconName, _ text: String) -> FlexBox {
        FlexBox(direction: .row, spacing: 10, crossAlignment: .center) {
            Icon(name: icon, style: .outline)
            Text(text, style: .body)
        }
    }

    private static func recent(_ name: String, _ detail: String, _ when: String, strong: Bool) -> FlexBox {
        FlexBox(direction: .row, spacing: 12, crossAlignment: .center) {
            Icon(name: strong ? .personCircle : .person, style: strong ? .filled : .outline)
            FlexBox(direction: .column, spacing: 0) {
                Text(name, style: .body, color: strong ? .primary : .secondary)
                Text(detail, style: .meta, color: .secondary)
            }
            .flexGrow(1)
            Text(when, style: .meta, color: .secondary)
        }
    }
}
