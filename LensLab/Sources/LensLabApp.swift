import SwiftUI

@main
struct LensLabApp: App {
    @State private var lab = Lab()

    var body: some Scene {
        WindowGroup {
            LabView()
                .environment(lab)
                .task {
                    if let page = ProcessInfo.processInfo.environment["LENS_PAGE"].flatMap(Int.init),
                       Gallery.pages.indices.contains(page) {
                        lab.page = page
                    }
                    await lab.start()
                }
        }
    }
}

struct LabView: View {
    @Environment(Lab.self) private var lab

    var body: some View {
        @Bindable var lab = lab
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let view = lab.previewView { Preview(view: view) }
            }
            .frame(height: 430)

            List {
                ForEach(["Experience", "Components"], id: \.self) { section in
                    Section(section) {
                        ForEach(Gallery.pages.indices.filter { Gallery.pages[$0].section == section }, id: \.self) { index in
                            Button {
                                lab.page = index
                            } label: {
                                HStack {
                                    Text("\(index + 1)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22)
                                    Text(Gallery.pages[index].title).foregroundStyle(.primary)
                                    Spacer()
                                    if lab.page == index { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .safeAreaInset(edge: .top) {
                Text(lab.status).font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }
        }
    }
}

struct Preview: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
