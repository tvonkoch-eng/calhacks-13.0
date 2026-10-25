import ImageIO
import SwiftUI

/// Record what the glasses camera actually delivers and compare runs. The stream itself is fixed
/// at high/15 (see `Glasses.streamRes`); a tuning push can still move it.
struct StreamLabView: View {
    @Environment(Glasses.self) private var glasses

    @State private var runs: [FrameRun] = []
    @State private var bench: [String: Double] = [:]
    @State private var linkResults: [String] = []

    var body: some View {
        @Bindable var glasses = glasses
        List {
            Section("Streaming") {
                LabeledContent("Status", value: glasses.status)
                LabeledContent("Asked for", value: "\(glasses.streamRes) · \(glasses.streamFps) fps")
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
                Text("Saves full frames to Files → On My iPhone → CalHacks → frames, up to \(FrameRecorder.cap) per run.")
            }

            Section {
                Button(glasses.benching ? "Writing to the lens…" : "Run lens bench") {
                    Task { bench = await glasses.lensBench() }
                }
                .disabled(glasses.benching || !glasses.connected || glasses.replaying)
                ForEach(["name", "cardPlaceholder", "cardPhoto"], id: \.self) { shape in
                    if let ms = bench[shape] {
                        LabeledContent(shape == "name" ? "Name only" : shape == "cardPhoto" ? "Card with large photo" : "Card, photo placeholder",
                                       value: "\(Int(ms.rounded())) ms")
                    }
                }
            } header: {
                Text("Lens bench")
            } footer: {
                Text("Writes each card shape to the glasses 10 times and shows the median. Needs the glasses connected; the lens flickers between two people while it runs.")
            }

            Section {
                Button(glasses.linkProgress.isEmpty ? "Run link test" : glasses.linkProgress) {
                    Task { linkResults = await glasses.linkTest() }
                }
                .disabled(glasses.benching || !glasses.connected || glasses.replaying)
                ForEach(linkResults, id: \.self) { Text($0).font(.caption.monospacedDigit()) }
            } header: {
                Text("Link test")
            } footer: {
                Text("About 3 minutes with the glasses on. At 15 and 7 fps, writes nothing, a name, a card with an empty photo box, and cards with 96 px and 192 px photos, once a second, and measures what the stream delivers meanwhile.")
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
        .onAppear { runs = FrameRun.all() }
        // A run in progress keeps growing; refresh its row while the toggle is on.
        .task(id: glasses.recordFrames) {
            while glasses.recordFrames, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                runs = FrameRun.all()
            }
            runs = FrameRun.all()
        }
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

/// What the camera is delivering right now, on the home screen: the request is not the result,
/// so this shows the measured frame size and rate. Recording and the runs are one tap away.
struct StreamControls: View {
    @Environment(Glasses.self) private var glasses

    var body: some View {
        @Bindable var glasses = glasses
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "video")
                    .font(.caption)
                    .foregroundStyle(glasses.delivered == nil ? Color.secondary : Color.green)
                Text(glasses.delivered.map { "\($0.size) · \(String(format: "%.1f", $0.fps)) fps" } ?? "Not streaming")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle(isOn: $glasses.recordFrames) {
                    Label("Rec", systemImage: "record.circle")
                }
                .toggleStyle(.button)
                .tint(glasses.recordFrames ? .red : .secondary)
                .controlSize(.small)
                NavigationLink { StreamLabView() } label: {
                    Text("Runs").font(.caption.weight(.medium))
                }
            }
            // How much the face in view looks like its best match, every scan. Green once it clears
            // the bar for the lens; the runner-up shows how clear the win is.
            HStack(spacing: 6) {
                Image(systemName: "person.crop.square")
                    .font(.caption)
                    .foregroundStyle(glasses.likeness?.confident == true ? Color.green : Color.secondary)
                if let l = glasses.likeness {
                    // One line, always: a wrapped name moved the chat and the person card below.
                    Text("\(l.name) \(Int((l.score * 100).rounded()))%")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .lineLimit(1).layoutPriority(1)
                        .foregroundStyle(l.confident ? Color.green : Color.primary)
                    Text(l.runnerUp.map { "next \($0) −\(Int((l.gap * 100).rounded()))" } ?? "")
                        .font(.caption.monospacedDigit())
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(l.looks) looks")
                        .font(.caption2.monospacedDigit())
                        .lineLimit(1)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("No face in view").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Every frame of one run. Sort by sharpness to see the best and worst the link produced.
struct FrameRunView: View {
    @Environment(Glasses.self) private var glasses
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
            // Feeds this run through the live matcher; go back to the home screen to watch the
            // camera and lens tiles.
            Button("Replay") { glasses.replay(run) }
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

