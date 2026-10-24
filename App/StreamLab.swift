import ImageIO
import SwiftUI

/// Pick the stream's resolution and frame rate on the phone, record what actually arrives, and
/// compare runs. The knobs are the same `streamRes`/`streamFps` that `qmship -t` pushes, so the
/// last one set — here or by a push — wins.
struct StreamLabView: View {
    @Environment(Glasses.self) private var glasses

    @State private var res = "low"
    @State private var fps = 7
    @State private var runs: [FrameRun] = []

    private static let resolutions = [("low", "Low · 360×640"), ("medium", "Medium · 504×896"), ("high", "High · 720×1280")]
    /// The only rates the SDK accepts.
    private static let rates = [2, 7, 15, 24, 30]

    var body: some View {
        @Bindable var glasses = glasses
        List {
            Section {
                Picker("Resolution", selection: $res) {
                    ForEach(Self.resolutions, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Frame rate", selection: $fps) {
                    ForEach(Self.rates, id: \.self) { Text("\($0) fps").tag($0) }
                }
                .pickerStyle(.segmented)
                Button("Apply") { glasses.setStream(res: res, fps: fps) }
                    .disabled(res == glasses.streamRes && fps == glasses.streamFps)
            } header: {
                Text("Requested")
            } footer: {
                Text(applyNote)
            }

            Section("Delivered") {
                LabeledContent("Status", value: glasses.status)
                LabeledContent("Frame size", value: glasses.delivered?.size ?? "—")
                LabeledContent("Frame rate", value: glasses.delivered.map { String(format: "%.1f fps", $0.fps) } ?? "—")
                if let pov = glasses.pov {
                    Image(uiImage: pov).resizable().scaledToFit().frame(maxHeight: 240)
                        .frame(maxWidth: .infinity)
                }
            }

            Section {
                Toggle("Record every frame", isOn: $glasses.recordFrames)
            } footer: {
                Text("Saves full frames to Files → On My iPhone → CalHacks → frames. A new run starts whenever the settings change, up to \(FrameRecorder.cap) frames each.")
            }

            Section("Runs") {
                if runs.isEmpty { Text("No recordings yet").foregroundStyle(.secondary) }
                ForEach(runs) { run in
                    NavigationLink { FrameRunView(run: run) } label: { RunRow(run: run) }
                }
                .onDelete { offsets in
                    for i in offsets { try? FileManager.default.removeItem(at: runs[i].url) }
                    runs.remove(atOffsets: offsets)
                }
            }
        }
        .navigationTitle("Stream lab")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { runs = FrameRun.all() }
        .onAppear {
            res = glasses.streamRes
            fps = glasses.streamFps
            runs = FrameRun.all()
        }
        // A run in progress keeps growing; refresh its row while the toggle is on.
        .task(id: glasses.recordFrames) {
            while glasses.recordFrames, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                runs = FrameRun.all()
            }
            runs = FrameRun.all()
        }
    }

    private var applyNote: String {
        if glasses.mocking { return "Phone sim always streams medium at 24 fps; these apply to real glasses." }
        return "Applying restarts the glasses session (a few seconds without video). The SDK may still send less when Bluetooth is busy: check Delivered."
    }
}

private struct RunRow: View {
    let run: FrameRun

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(run.asked).font(.body.weight(.medium))
            Text("\(run.frames.count) frames · \(String(format: "%.1f", run.fps)) fps · sharpness \(String(format: "%.3f", run.medianSharpness))")
                .font(.footnote).foregroundStyle(.secondary)
            Text(run.sizes).font(.caption).foregroundStyle(.tertiary)
            Text(run.name.split(separator: "_").prefix(2).joined(separator: " ")).font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

/// Every frame of one run. Sort by sharpness to see the best and worst the link produced.
struct FrameRunView: View {
    let run: FrameRun
    @State private var bySharpness = false

    private var frames: [FrameRun.Frame] {
        bySharpness ? run.frames.sorted { $0.sharpness > $1.sharpness } : run.frames
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 4)], spacing: 4) {
                ForEach(frames) { frame in
                    NavigationLink { FrameDetail(frame: frame) } label: {
                        Thumb(url: frame.url)
                            .aspectRatio(9 / 16, contentMode: .fit)
                            .overlay(alignment: .bottomLeading) {
                                Text(String(format: "%.3f", frame.sharpness))
                                    .font(.caption2.monospacedDigit())
                                    .padding(3)
                                    .background(.black.opacity(0.6))
                                    .foregroundStyle(.white)
                            }
                    }
                }
            }
            .padding(4)
        }
        .navigationTitle(run.asked)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button(bySharpness ? "By time" : "By sharpness") { bySharpness.toggle() }
        }
    }
}

private struct FrameDetail: View {
    let frame: FrameRun.Frame
    @State private var zoom: CGFloat = 1

    var body: some View {
        VStack(spacing: 8) {
            ScrollView([.horizontal, .vertical]) {
                if let image = UIImage(contentsOfFile: frame.url.path) {
                    // Zoom 1 is pixel for pixel, which is what judging blur needs.
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: CGFloat(frame.width) / UIScreen.main.scale * zoom,
                               height: CGFloat(frame.height) / UIScreen.main.scale * zoom)
                }
            }
            Slider(value: $zoom, in: 0.5...4)
                .padding(.horizontal)
            Text("#\(frame.seq) · \(frame.size) · \(frame.ms) ms · sharpness \(String(format: "%.3f", frame.sharpness))")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .toolbar { ShareLink(item: frame.url) }
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A downsampled thumbnail, decoded off the main thread: a run can hold 900 full frames.
private struct Thumb: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemBackground)
            .overlay { if let image { Image(uiImage: image).resizable().scaledToFill() } }
            .clipped()
            .task(id: url) {
                image = await Task.detached(priority: .utility) { [url] in
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                              kCGImageSourceCreateThumbnailFromImageAlways: true,
                              kCGImageSourceThumbnailMaxPixelSize: 240,
                          ] as CFDictionary) else { return nil }
                    return UIImage(cgImage: cg)
                }.value
            }
    }
}
