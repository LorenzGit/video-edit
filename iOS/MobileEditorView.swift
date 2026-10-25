import SwiftUI
import PhotosUI
import Photos
import UniformTypeIdentifiers
import AVFoundation

private struct SharedMovie: Identifiable {
    let id = UUID()
    let url: URL
}

struct MobileEditorView: View {
    @EnvironmentObject private var vm: EditorViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @StateObject private var photoLoader = PhotoImportLoader()
    @State private var photos: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var importingAudio = false
    @State private var showExport = false
    @State private var showAudio = false
    @State private var audioVolume: Double = 1
    @State private var changingVolume = false
    @State private var showSpeed = false
    @State private var framingEditor: MobileFramingDestination?
    @State private var confirmNew = false
    @State private var loadingPhotos = false
    @State private var sharedMovie: SharedMovie?
    @State private var zoom: Double = 44
    @State private var fitsTimeline = false
    @State private var timelineWidth: CGFloat = 320

    private var compact: Bool { verticalSizeClass == .compact }
    private var busy: Bool { vm.isImporting || loadingPhotos || vm.isExporting }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                GeometryReader { geometry in
                    let landscape = geometry.size.width > geometry.size.height
                    Group {
                        if vm.hasContent {
                            if landscape {
                                HStack(spacing: 16) {
                                    preview
                                    editingDock.frame(width: geometry.size.width * 0.49)
                                }.padding(.horizontal, 16).padding(.bottom, 16)
                            } else {
                                VStack(spacing: 14) {
                                    preview
                                    editingDock
                                }.padding(.horizontal, 16).padding(.bottom, 16)
                            }
                        } else { emptyState }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                if let message = vm.statusMessage {
                    HStack(alignment: .top, spacing: 12) {
                        Text(message).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                        Button { vm.statusMessage = nil } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }.accessibilityLabel("Dismiss message")
                    }
                    .padding(12).background(Theme.panelHi, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal).padding(.bottom, 6)
                }
            }
            .disabled(busy)
            .overlay {
                if busy {
                    ZStack {
                        Color.black.opacity(0.65).ignoresSafeArea()
                        VStack(spacing: 16) {
                            if vm.isExporting {
                                Image(systemName: "square.and.arrow.up").font(.largeTitle)
                                Text("Exporting video").font(.headline)
                                ProgressView(value: vm.exportProgress).frame(width: 220)
                                Text("\(Int(vm.exportProgress * 100))%")
                                    .monospacedDigit().foregroundStyle(.secondary)
                                Text("Keep Reel open until export finishes.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            } else {
                                if photoLoader.isLoading, photoLoader.fractionCompleted > 0 {
                                    ProgressView(value: photoLoader.fractionCompleted).frame(width: 220)
                                    Text("\(Int(photoLoader.fractionCompleted * 100))%")
                                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                } else { ProgressView() }
                                Text(photoLoader.isLoading ? "Loading original video…" : "Preparing video…")
                                    .font(.headline)
                                if photoLoader.isLoading {
                                    Button("Cancel") { photoLoader.cancel() }.frame(minHeight: 44)
                                }
                            }
                        }.padding(28).background(Theme.panel, in: RoundedRectangle(cornerRadius: 22))
                    }
                }
            }
            .photosPicker(isPresented: $showPhotos, selection: $photos, maxSelectionCount: 20,
                          selectionBehavior: .ordered, matching: .videos, preferredItemEncoding: .current)
            .onChange(of: photos) { _, items in
                guard !items.isEmpty else { return }
                loadingPhotos = true
                Task {
                    for item in items {
                        do {
                            let movie = try await photoLoader.load(item)
                            await vm.importMobileFiles([movie.url], consumingStagedFiles: true)
                            MovieImportStorage.discard(movie.url)
                        } catch is CancellationError {
                            break
                        } catch {
                            vm.statusMessage = "Couldn't open a selected video: \(error.localizedDescription)"
                        }
                    }
                    photos = []
                    loadingPhotos = false
                }
            }
            .fileImporter(isPresented: $showFiles,
                          allowedContentTypes: importingAudio ? [.audio] : [.movie],
                          allowsMultipleSelection: !importingAudio) { result in
                switch result {
                case .success(let urls):
                    Task { await vm.importMobileFiles(urls, asAudio: importingAudio) }
                case .failure(let error): vm.statusMessage = error.localizedDescription
                }
            }
            .sheet(isPresented: $showExport) { MobileExportSheet().environmentObject(vm) }
            .sheet(isPresented: $showSpeed) { speedSheet }
            .fullScreenCover(item: $framingEditor) { destination in
                MobileFramingEditor(destination: destination).environmentObject(vm)
            }
            .onChange(of: vm.chunks) { _, _ in
                if showAudio {
                    vm.prepareMobileWaveforms()
                    if vm.mobileAudioTarget != nil && vm.selectedMobileAudioSegment == nil { vm.selectMobileAudioAtPlayhead() }
                }
            }
            .onChange(of: vm.audioChunks) { previous, current in
                if previous.isEmpty, let audio = current.first {
                    showAudio = true
                    vm.selectMobileAudio(.added(audio.id))
                }
                if showAudio { vm.prepareMobileWaveforms() }
            }
            .sheet(item: $sharedMovie) { movie in MobileShareSheet(url: movie.url) }
            .onChange(of: vm.exportedURL) { _, url in
                if let url { sharedMovie = SharedMovie(url: url) }
            }
            .confirmationDialog("Start a new video?", isPresented: $confirmNew, titleVisibility: .visible) {
                Button("Discard current draft", role: .destructive) { vm.newMobileProject() }
            } message: { Text("Your current draft and its imported media will be removed from Reel.") }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    if vm.isPlaying { vm.togglePlay() }
                    vm.saveMobileDraft()
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Menu {
                importActions
                if vm.sourceURL != nil {
                    Divider()
                    Button("New video", systemImage: "plus.rectangle", role: .destructive) { confirmNew = true }
                }
            } label: {
                HStack(spacing: 6) {
                    Text("Reel").font(.system(size: compact ? 21 : 25, weight: .bold, design: .rounded)).tracking(-0.6)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                }.foregroundStyle(.white).frame(minHeight: 44)
            }.accessibilityLabel("Project menu")
            Spacer(minLength: 12)
            Button { vm.undo() } label: {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 16, weight: .medium))
                    .frame(width: 40, height: 44)
            }.disabled(!vm.canUndo).accessibilityLabel("Undo")
            Button { vm.redo() } label: {
                Image(systemName: "arrow.uturn.forward").font(.system(size: 16, weight: .medium))
                    .frame(width: 40, height: 44)
            }.disabled(!vm.canRedo).accessibilityLabel("Redo")
            Button { showExport = true } label: {
                HStack(spacing: 7) {
                    Text("Export").font(.system(size: 13, weight: .semibold))
                    Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .bold))
                }.padding(.horizontal, 16).frame(height: 40)
                    .foregroundStyle(vm.hasContent ? Theme.bg : Color.white.opacity(0.35))
                    .background(vm.hasContent ? Theme.accent : Theme.panelHi,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }.disabled(!vm.hasContent).accessibilityLabel("Export video")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 20).padding(.top, compact ? 0 : 2).padding(.bottom, compact ? 4 : 12)
    }

    @ViewBuilder private var importActions: some View {
        Button("Add from Photos", systemImage: "photo.on.rectangle") { showPhotos = true }
        Button("Add from Files", systemImage: "folder") { importingAudio = false; showFiles = true }
        if vm.hasContent {
            Button("Add audio file", systemImage: "music.note") { importingAudio = true; showFiles = true }
            if vm.hasImportedAudioTrack {
                Button("Remove added audio", systemImage: "waveform.slash") { vm.removeImportedAudio() }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: compact ? 12 : 22) {
            Spacer(minLength: 0)
            if !compact {
                Image(systemName: "play.rectangle.on.rectangle.fill")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 100, height: 100)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 30))
            }
            VStack(spacing: 10) {
                Text("Make the cut.").font(.system(size: 32, weight: .bold, design: .rounded)).tracking(-0.8)
                Text("Your clips. Just the good parts.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            VStack(spacing: 8) {
                Button { showPhotos = true } label: {
                    Label("Choose videos", systemImage: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: 270).frame(height: 54)
                        .foregroundStyle(Theme.bg)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18))
                }.buttonStyle(.plain)
                Button("Browse Files") { importingAudio = false; showFiles = true }
                    .font(.subheadline.weight(.medium)).foregroundStyle(.secondary).frame(minHeight: 44)
            }.padding(.top, compact ? 0 : 10)
            Spacer(minLength: 0)
            if !compact {
                Text("No accounts. No watermark.").font(.caption).foregroundStyle(.tertiary)
            }
        }.padding(compact ? 12 : 28)
    }

    private var preview: some View {
        GeometryReader { available in
            let geometry = vm.mobilePreviewGeometry
            let size = geometry?.outputSize ?? vm.resolvedVideoCrop.outputSize
            let fit = min(available.size.width / max(1, size.width),
                          available.size.height / max(1, size.height))
            MobilePlayerView(player: vm.player, geometry: geometry)
                .frame(width: max(0, size.width * fit), height: max(0, size.height * fit))
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.05)))
                .contentShape(Rectangle())
                .onTapGesture { vm.togglePlay() }
                .accessibilityLabel("Video preview")
                .position(x: available.size.width / 2, y: available.size.height / 2)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editingDock: some View {
        VStack(spacing: compact ? 6 : 12) {
            if compact {
                ScrollView(.vertical) {
                    VStack(spacing: 6) {
                        timelinePanel
                        if showAudio { audioControls }
                    }
                }
            } else {
                timelinePanel
                if showAudio { audioControls }
            }
            tools
        }
    }

    private var timelinePanel: some View {
        VStack(spacing: 0) {
            transport.padding(.horizontal, 16).padding(.top, compact ? 4 : 10).padding(.bottom, compact ? 0 : 4)
            MobileTimelineView(editor: vm, pointsPerSecond: $zoom, fitsTimeline: $fitsTimeline,
                               showsAudio: showAudio, compact: compact)
                .frame(height: (compact ? 78 : 116) + (showAudio ? (compact ? 40 : 52) : 0)
                       + (showAudio && vm.hasImportedAudioTrack ? (compact ? 40 : 52) : 0))
                .background {
                    GeometryReader { geometry in
                        Color.clear.onAppear { timelineWidth = geometry.size.width }
                            .onChange(of: geometry.size.width) { _, width in timelineWidth = width }
                    }
                }
            HStack(spacing: 0) {
                Menu { importActions } label: {
                    Label("Add clip", systemImage: "plus").font(.system(size: 11, weight: .semibold))
                        .frame(minHeight: 44)
                }.accessibilityLabel("Import video")
                Spacer(minLength: 4)
                Button("Fit") { fitsTimeline = true }
                    .font(.system(size: 11, weight: .semibold)).frame(width: 36, height: 44)
                    .foregroundStyle(fitsTimeline ? Theme.accent : .white.opacity(0.65))
                    .accessibilityLabel("Fit timeline")
                    .accessibilityValue(fitsTimeline ? "Entire timeline visible" : "Zoomed")
                Button { changeZoom(by: 1 / 1.5) } label: {
                    Image(systemName: "minus.magnifyingglass").font(.system(size: 14)).frame(width: 40, height: 44)
                }.accessibilityLabel("Zoom out")
                Button { changeZoom(by: 1.5) } label: {
                    Image(systemName: "plus.magnifyingglass").font(.system(size: 14)).frame(width: 40, height: 44)
                }.accessibilityLabel("Zoom in")
            }.padding(.horizontal, 14).foregroundStyle(.white.opacity(0.65)).buttonStyle(.plain)
        }
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.05)))
    }

    private var audioControls: some View {
        VStack(spacing: 8) {
            if let segment = vm.selectedMobileAudioSegment, segment.hasAudio {
                if vm.muteAudio && vm.mobileSourceAudioSelected {
                    Button("Enable clip audio") { vm.muteAudio = false }
                        .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                } else {
                    Group {
                        if compact {
                            HStack(spacing: 10) {
                                audioFadeButton(for: segment)
                                volumeSlider(for: segment)
                                volumeValue(for: segment)
                                sectionMuteButton(for: segment)
                            }
                        } else {
                            VStack(spacing: 8) {
                                HStack {
                                    Text(vm.mobileSourceAudioSelected ? "Clip audio" : "Added audio")
                                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                    Spacer()
                                    audioFadeButton(for: segment)
                                    volumeValue(for: segment)
                                    sectionMuteButton(for: segment)
                                }
                                volumeSlider(for: segment)
                            }
                        }
                    }
                }
            } else {
                Text(vm.hasAudio || vm.hasImportedAudioTrack ? "Tap an audio section to adjust its volume" : "This video has no audio")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            if !compact && (vm.hasAudio || vm.hasImportedAudioTrack) {
                Text("Split audio at both ends of a spot, then adjust that section.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }.padding(.horizontal, 14).padding(.vertical, compact ? 4 : 10)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
    }

    private func audioFadeButton(for segment: MobileAudioSegment) -> some View {
        Button { vm.setMobileAudioFade(!segment.fades) } label: {
            Label("Fade", systemImage: segment.fades ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11, weight: .semibold)).frame(minHeight: 44)
                .foregroundStyle(segment.fades ? Color(red: 0.24, green: 0.83, blue: 0.72) : .secondary)
        }.accessibilityLabel("Fade audio section").accessibilityValue(segment.fades ? "On" : "Off")
    }

    private func volumeSlider(for segment: MobileAudioSegment) -> some View {
        Slider(value: Binding(get: { changingVolume ? audioVolume : Double(segment.volume) },
                              set: { audioVolume = $0 }), in: 0...1) { editing in
            if editing { audioVolume = Double(segment.volume); changingVolume = true }
            else { changingVolume = false; vm.setMobileAudioVolume(audioVolume) }
        }.tint(Color(red: 0.24, green: 0.83, blue: 0.72)).accessibilityLabel("Audio section volume")
    }

    private func volumeValue(for segment: MobileAudioSegment) -> some View {
        Text("\(Int(((changingVolume ? audioVolume : Double(segment.volume)) * 100).rounded()))%")
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .accessibilityIdentifier("audioVolumePercent")
    }

    private func sectionMuteButton(for segment: MobileAudioSegment) -> some View {
        Button { vm.setMobileAudioVolume(segment.volume == 0 ? 1 : 0) } label: {
            Image(systemName: segment.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .frame(width: 44, height: compact ? 44 : 32)
        }.accessibilityLabel(segment.volume == 0 ? "Unmute audio section" : "Mute audio section")
    }

    private var transport: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(timecode(vm.currentTime, showCentis: true))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
                    .accessibilityIdentifier("playheadTime")
                Text("PLAYHEAD").font(.system(size: 9, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(.white.opacity(0.5))
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { vm.togglePlay() } label: {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .offset(x: vm.isPlaying ? 0 : 1)
                    .foregroundStyle(Theme.bg).frame(width: 44, height: 44)
                    .background(Theme.accent, in: Circle())
            }.buttonStyle(.plain).accessibilityLabel(vm.isPlaying ? "Pause" : "Play")
            VStack(alignment: .trailing, spacing: 3) {
                Text(timecode(vm.totalDuration, showCentis: true))
                    .font(.system(size: 14, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.55))
                    .accessibilityIdentifier("totalDuration")
                Text("DURATION").font(.system(size: 9, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(.white.opacity(0.5))
            }.frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func changeZoom(by factor: Double) {
        let current = fitsTimeline
            ? MobileTimelineView.fittedScale(duration: vm.totalDuration, width: timelineWidth) : zoom
        zoom = max(0.001, min(max(240, current), current * factor))
        fitsTimeline = false
    }

    private var tools: some View {
        VStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                toolRow
                ScrollView(.horizontal) { toolRow }.scrollIndicators(.hidden)
            }
            if vm.chunks.count > 1 {
                Text("Hold and drag a clip to reorder")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
        }
    }

    private var toolRow: some View {
        HStack(spacing: 4) {
            Button {
                if vm.mobileSourceAudioSelected { vm.splitMobileAudioAtPlayhead() }
                else { vm.splitAtPlayhead() }
            } label: {
                toolLabel(vm.mobileSourceAudioSelected || vm.hasAudioSelection ? "Split audio" : "Split", "scissors", prominent: true)
            }.accessibilityLabel(vm.mobileSourceAudioSelected || vm.hasAudioSelection ? "Split audio" : "Split")
            Button {
                showAudio.toggle()
                if showAudio {
                    vm.prepareMobileWaveforms()
                    vm.selectMobileAudioAtPlayhead()
                } else { vm.selectMobileAudio(nil) }
            } label: {
                toolLabel("Audio", "waveform", prominent: showAudio)
            }.accessibilityLabel(showAudio ? "Hide audio timeline" : "Show audio timeline")
            Button {
                if vm.isPlaying { vm.togglePlay() }
                framingEditor = .crop
            } label: { toolLabel("Crop", "crop") }.accessibilityLabel("Crop entire video")
            Button {
                if let clip = vm.prepareMobileFraming() { framingEditor = .clip(clip.id) }
            } label: { toolLabel("Frame", "arrow.up.left.and.arrow.down.right") }.accessibilityLabel("Frame clip")
            Button { showSpeed = true } label: {
                toolLabel("Speed", "speedometer")
            }.disabled(vm.selectedMobileChunk == nil && vm.selectedAudioChunk == nil).accessibilityLabel("Speed")
            Button(role: .destructive) { vm.deleteSelected() } label: {
                toolLabel("Delete", "trash", destructive: true)
            }.disabled(!vm.hasAnySelection).accessibilityLabel("Delete")
        }.buttonStyle(.plain)
    }

    private func toolLabel(_ title: String, _ icon: String, prominent: Bool = false,
                           destructive: Bool = false) -> some View {
        VStack(spacing: compact ? 5 : 8) {
            Image(systemName: icon).font(.system(size: 18, weight: .medium))
            Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(minWidth: 44, maxWidth: .infinity).frame(height: compact ? 52 : 64)
        .foregroundStyle(destructive ? Color(red: 1, green: 0.48, blue: 0.5) : (prominent ? Theme.accent : .white.opacity(0.8)))
        .background(prominent ? Theme.accentSoft : Theme.panel,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var speedSheet: some View {
        NavigationStack {
            List {
                Section(vm.selection.isEmpty ? "Speed for all clips" : "Selected clip speed") {
                    ForEach([0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 8], id: \.self) { speed in
                        Button {
                            vm.setSpeed(speed); showSpeed = false
                        } label: {
                            HStack {
                                Text(speedLabel(speed)).foregroundStyle(.primary)
                                Spacer()
                                if vm.activeSpeed == speed { Image(systemName: "checkmark") }
                            }.frame(minHeight: 32)
                        }
                    }
                }
            }.navigationTitle("Playback speed").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSpeed = false } } }
        }.presentationDetents([.medium, .large])
    }
}

struct MobilePlayerView: UIViewRepresentable {
    let player: AVPlayer
    let geometry: MobilePreviewGeometry?

    func makeUIView(context: Context) -> Container {
        let view = Container()
        view.playerLayer.player = player
        view.geometry = geometry
        return view
    }

    func updateUIView(_ view: Container, context: Context) {
        view.geometry = geometry
        view.setNeedsLayout()
    }

    static func dismantleUIView(_ view: Container, coordinator: ()) { view.playerLayer.player = nil }

    final class Container: UIView {
        let playerLayer = AVPlayerLayer()
        var geometry: MobilePreviewGeometry?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            layer.addSublayer(playerLayer)
            playerLayer.videoGravity = .resize
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let geometry else { return }
            let fit = min(bounds.width / max(1, geometry.outputSize.width),
                          bounds.height / max(1, geometry.outputSize.height))
            let origin = CGPoint(x: (bounds.width - geometry.outputSize.width * fit) / 2,
                                 y: (bounds.height - geometry.outputSize.height * fit) / 2)
            let transform = geometry.transform
                .concatenating(CGAffineTransform(scaleX: fit, y: fit))
                .concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
            let center = CGPoint(x: geometry.encodedSize.width / 2, y: geometry.encodedSize.height / 2).applying(transform)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // The viewport clips content to the output canvas, including when
            // the editor letterboxes a portrait project in a landscape screen.
            let cropFrame = CGRect(origin: origin, size: CGSize(width: geometry.outputSize.width * fit,
                                                                height: geometry.outputSize.height * fit))
            let mask = CAShapeLayer()
            mask.path = UIBezierPath(rect: cropFrame).cgPath
            layer.mask = mask
            playerLayer.bounds = CGRect(origin: .zero, size: geometry.encodedSize)
            playerLayer.position = center
            playerLayer.setAffineTransform(CGAffineTransform(a: transform.a, b: transform.b,
                                                           c: transform.c, d: transform.d, tx: 0, ty: 0))
            CATransaction.commit()
        }
    }
}

private struct MobileExportSheet: View {
    @EnvironmentObject var vm: EditorViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("MP4 video") {
                    Picker("Resolution", selection: $vm.exportResolution) {
                        ForEach(EditorViewModel.ExportResolution.allCases) { Text($0.title).tag($0) }
                    }
                    LabeledContent("Dimensions", value: vm.exportDimensions(for: vm.exportResolution))
                    Picker("Compression", selection: $vm.exportCompression) {
                        ForEach(EditorViewModel.ExportCompression.allCases) { Text($0.title).tag($0) }
                    }
                    Text(vm.exportCompression.detail).font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Text("Save to Photos or Files, or send to another app.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button {
                        dismiss()
                        // Export completes asynchronously, after this sheet has dismissed.
                        vm.exportMobile()
                    } label: {
                        Label("Export and share", systemImage: "square.and.arrow.up")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 40)
                    }.accessibilityIdentifier("exportAndShare")
                }
            }.navigationTitle("Export video").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }.presentationDetents([.large])
    }
}

private struct MobileShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
