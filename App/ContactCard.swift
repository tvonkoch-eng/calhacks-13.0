import SwiftUI
import Contacts
import ContactsUI
import CoreTransferable
import UniformTypeIdentifiers

// How to reach someone: the call/message/email/LinkedIn row under their name, the Contact rows,
// and getting them out of the app (a vCard, or straight into the iPhone's Contacts).

extension Person {
    var phoneURL: URL? { phone.flatMap { URL(string: "tel:" + $0.filter { $0.isNumber || $0 == "+" }) } }
    var messageURL: URL? { phone.flatMap { URL(string: "sms:" + $0.filter { $0.isNumber || $0 == "+" }) } }
    var emailURL: URL? { email.flatMap { URL(string: "mailto:" + $0) } }
    var linkedinURL: URL? { linkedin.flatMap { URL(string: "https://www.linkedin.com/in/" + $0) } }
    var instagramURL: URL? { instagram.flatMap { URL(string: "https://instagram.com/" + $0) } }
    var websiteURL: URL? { website.flatMap { URL(string: "https://" + $0) } }

    /// For the iPhone's Contacts app: name, work, and every way to reach them.
    var cnContact: CNMutableContact {
        let contact = CNMutableContact()
        let parts = name.split(separator: " ", maxSplits: 1).map(String.init)
        contact.givenName = parts.first ?? name
        contact.familyName = parts.count > 1 ? parts[1] : ""
        if let work {
            // "ML engineer at Stripe" → title + company.
            let split = work.components(separatedBy: " at ")
            if split.count == 2 { contact.jobTitle = split[0]; contact.organizationName = split[1] } else { contact.jobTitle = work }
        }
        if let phone { contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: phone))] }
        if let email { contact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: email as NSString)] }
        contact.urlAddresses = [("LinkedIn", linkedinURL), (CNLabelURLAddressHomePage, websiteURL)]
            .compactMap { label, url in url.map { CNLabeledValue(label: label, value: $0.absoluteString as NSString) } }
        if let instagram {
            contact.socialProfiles = [CNLabeledValue(label: nil, value: CNSocialProfile(urlString: instagramURL?.absoluteString, username: instagram, userIdentifier: nil, service: "Instagram"))]
        }
        return contact
    }
}

/// "(415) 555-0134" for a US number kept as digits; anything else as it was written.
func phoneDisplay(_ phone: String) -> String {
    var digits = phone.filter(\.isNumber)
    let us = digits.count == 11 && digits.hasPrefix("1") || digits.count == 10 && !phone.hasPrefix("+")
    guard us, phone.allSatisfy({ $0.isNumber || $0 == "+" }) else { return phone }
    if digits.count == 11 { digits.removeFirst() }
    let d = Array(digits)
    return "(\(String(d[0..<3]))) \(String(d[3..<6]))-\(String(d[6..<10]))"
}

// MARK: - Quick actions

/// Call, Message, Email, LinkedIn: whichever they have, as equal tiles under the name.
struct ReachActions: View {
    let person: Person

    var body: some View {
        let actions: [(String, String?, URL?)] = [
            ("Call", "phone.fill", person.phoneURL),
            ("Message", "message.fill", person.messageURL),
            ("Email", "envelope.fill", person.emailURL),
            ("LinkedIn", nil, person.linkedinURL),
        ].filter { $0.2 != nil }
        if !actions.isEmpty {
            HStack(spacing: 8) {
                ForEach(actions, id: \.0) { title, symbol, url in
                    Link(destination: url!) {
                        VStack(spacing: 5) {
                            Group {
                                if let symbol {
                                    Image(systemName: symbol).font(.system(size: 16, weight: .medium))
                                } else {
                                    Text("in").font(.system(size: 17, weight: .bold, design: .rounded))
                                }
                            }
                            .frame(height: 20)
                            Text(title).font(.caption.weight(.medium))
                        }
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
            .padding(.top, 18)
        }
    }
}

// MARK: - Contact rows

/// Every way to reach them, one ruled row each; tap to use, hold to copy.
struct ContactRows: View {
    let person: Person
    /// Opens the editor when there's nothing yet.
    var add: () -> Void

    var body: some View {
        let rows: [(String, String, URL?)] = [
            ("Phone", person.phone.map(phoneDisplay), person.phoneURL),
            ("Email", person.email, person.emailURL),
            ("LinkedIn", person.linkedin, person.linkedinURL),
            ("Instagram", person.instagram.map { "@" + $0 }, person.instagramURL),
            ("Website", person.website, person.websiteURL),
        ].compactMap { label, value, url in value.flatMap { $0.isEmpty ? nil : (label, $0, url) } }
        if rows.isEmpty {
            Button(action: add) {
                Text("Add a phone number, email or LinkedIn").font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
        } else {
            VStack(spacing: 0) {
                ForEach(rows, id: \.0) { label, value, url in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(label).font(.subheadline).foregroundStyle(.secondary).frame(width: 104, alignment: .leading)
                        if let url {
                            Link(value, destination: url).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                        } else {
                            Text(value).font(.subheadline).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = value }
                    }
                    Divider()
                }
            }
        }
    }
}

// MARK: - Out of the app

/// A contact as a .vcf, for the share sheet.
struct VCard: Transferable {
    let person: Person

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .vCard) { card in
            let data = try CNContactVCardSerialization.data(with: [card.person.cnContact])
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(card.person.name.replacingOccurrences(of: "/", with: "-") + ".vcf")
            try data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

/// The system "New Contact" screen, prefilled. Needs no Contacts permission: the wearer saves it.
struct NewContactSheet: UIViewControllerRepresentable {
    let person: Person
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = CNContactViewController(forNewContact: person.cnContact)
        controller.contactStore = CNContactStore()
        controller.delegate = context.coordinator
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    final class Coordinator: NSObject, CNContactViewControllerDelegate {
        let dismiss: DismissAction
        init(dismiss: DismissAction) { self.dismiss = dismiss }
        func contactViewController(_ controller: CNContactViewController, didCompleteWith contact: CNContact?) { dismiss() }
    }
}
