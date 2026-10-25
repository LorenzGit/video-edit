import SwiftUI
import UIKit
import AVFoundation

enum MobileFramingDestination: Identifiable {
    case crop
    case clip(UUID)
    var id: String {
        switch self { case .crop: return "crop"; case .clip(let id): return id.uuidString }
    }
}

struct MobileFramingEditor: View {
    @EnvironmentObject private var vm: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    let destination: MobileFramingDestination
    @State private var crop = VideoCrop(canvasWidth: 1080, canvasHeight: 1920)
    @State private var framing = ClipFraming()
    @State private var previewPlayer = AVPlayer()
    @State private var ratio: Double?
    @State private var preset = "Free"

    private var clipID: UUID? { if case .clip(let id) = destination { return id }; return nil }
    private var isCrop: Bool { clipID == nil }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button("Cancel") { dismiss() }.frame(minWidth: 64, minHeight: 44)
                Spacer()
                VStack(spacing: 2) {
                    Text(isCrop ? "Crop video" : "Frame clip").font(.headline)
                    Text(isCrop ? "Applies to every clip" : "Only this clip")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Apply") {
                    if let clipID { vm.setClipFraming(framing, for: clipID) }
                    else { vm.setVideoCrop(crop) }
                    dismiss()
                }.fontWeight(.semibold).frame(minWidth: 64, minHeight: 44)
            }.padding(.horizontal, 12)
            GeometryReader { geometry in
                if geometry.size.width > geometry.size.height {
                    HStack(spacing: 18) {
                        canvas
                        ScrollView { controls }.frame(width: geometry.size.width * 0.44)
                    }
                } else {
                    VStack(spacing: 18) { canvas; controls }
                }
            }.padding(.horizontal, 16).padding(.bottom, 12)
        }
        .background(Theme.backgroundGradient.ignoresSafeArea())
        .preferredColorScheme(.dark).tint(Theme.accent)
        .onAppear {
            crop = vm.resolvedVideoCrop
            if let clipID { framing = vm.chunks.first(where: { $0.id == clipID })?.framing ?? ClipFraming() }
            if let source = vm.player.currentItem {
                let item = AVPlayerItem(asset: source.asset)
                item.audioMix = source.audioMix
                previewPlayer.replaceCurrentItem(with: item)
                previewPlayer.seek(to: CMTime(seconds: vm.currentTime, preferredTimescale: 600),
                                   toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
        .onDisappear { previewPlayer.pause(); previewPlayer.replaceCurrentItem(with: nil) }
    }

    private var canvas: some View {
        GeometryReader { geometry in
            let size = isCrop ? crop.canvasSize : crop.outputSize
            let fit = min(max(1, geometry.size.width - 32) / max(1, size.width),
                          max(1, geometry.size.height - 32) / max(1, size.height))
            let rect = CGRect(x: (geometry.size.width - size.width * fit) / 2,
                              y: (geometry.size.height - size.height * fit) / 2,
                              width: size.width * fit, height: size.height * fit)
            ZStack {
                Color.clear
                MobilePlayerView(player: previewPlayer,
                                 geometry: vm.mobileGeometry(crop: isCrop ? crop.fullCanvas : crop,
                                                             framing: isCrop ? nil : framing))
                    .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                if isCrop {
                    CropOverlay(crop: $crop, lockedRatio: ratio)
                        .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                } else {
                    framingGrid.frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                    FramingGestureSurface(framing: $framing,
                                          normalization: CGSize(width: rect.width / crop.width, height: rect.height / crop.height))
                        .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                }
            }.clipShape(RoundedRectangle(cornerRadius: 18))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var framingGrid: some View {
            GeometryReader { geometry in
                Path { path in
                    for fraction in [1.0 / 3, 2.0 / 3] {
                        let x = geometry.size.width * fraction
                        let y = geometry.size.height * fraction
                        path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                        path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                    }
                }.stroke(.white.opacity(0.2), lineWidth: 0.5)
            }.allowsHitTesting(false)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            if isCrop {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(["Original", "9:16", "1:1", "4:5", "16:9", "Free"], id: \.self) { name in
                            Button {
                                preset = name
                                switch name {
                                case "Original": crop = crop.fullCanvas; ratio = crop.canvasWidth / crop.canvasHeight
                                case "9:16": ratio = 9.0 / 16
                                case "1:1": ratio = 1
                                case "4:5": ratio = 4.0 / 5
                                case "16:9": ratio = 16.0 / 9
                                default: ratio = nil
                                }
                                if let ratio { crop = crop.aspect(ratio) }
                            } label: {
                                Text(name).font(.system(size: 12, weight: .semibold))
                                    .padding(.horizontal, 14).frame(height: 44)
                                    .foregroundStyle(preset == name ? Theme.bg : .white)
                                    .background(preset == name ? Theme.accent : Theme.panelHi,
                                                in: RoundedRectangle(cornerRadius: 12))
                            }.accessibilityLabel("Crop \(name)")
                        }
                    }
                }.scrollIndicators(.hidden)
                Text("\(Int(crop.outputSize.width)) × \(Int(crop.outputSize.height))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("cropDimensions")
                Text("Drag the frame to move it. Drag a corner to crop.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                HStack(spacing: 12) {
                    Button("Fill") { if let clipID { framing = vm.mobileFillFraming(framing, chunkID: clipID) } }
                    Spacer()
                    Button { framing.rotation = (framing.rotation + 90).remainder(dividingBy: 360) } label: {
                        Label("90°", systemImage: "rotate.right")
                    }.accessibilityLabel("Rotate clip 90 degrees")
                    Spacer()
                    Button("Reset") { framing = ClipFraming() }.accessibilityLabel("Reset clip framing")
                }.font(.system(size: 13, weight: .semibold)).frame(minHeight: 44)
                VStack(spacing: 6) {
                    HStack { Text("Zoom"); Spacer(); Text("\(Int((framing.zoom * 100).rounded()))%").accessibilityIdentifier("frameZoomValue") }
                        .font(.caption.monospacedDigit())
                    Slider(value: $framing.zoom, in: 0.1...12).accessibilityLabel("Clip zoom")
                    HStack { Text("Rotation"); Spacer(); Text("\(Int(framing.rotation.rounded()))°").accessibilityIdentifier("frameRotationValue") }
                        .font(.caption.monospacedDigit())
                    Slider(value: $framing.rotation, in: -180...180).accessibilityLabel("Clip rotation")
                }
                Text("Pinch to zoom. Drag to move. Use two fingers to rotate.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }.padding(16).background(Theme.panel, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct CropOverlay: View {
    @Binding var crop: VideoCrop
    let lockedRatio: Double?
    @State private var dragStart: VideoCrop?

    var body: some View {
        GeometryReader { geometry in
            let rect = CGRect(x: crop.x * geometry.size.width, y: crop.y * geometry.size.height,
                              width: crop.width * geometry.size.width, height: crop.height * geometry.size.height)
            ZStack {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geometry.size)); path.addRect(rect)
                }.fill(.black.opacity(0.6), style: FillStyle(eoFill: true)).allowsHitTesting(false)
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .overlay(Rectangle().stroke(.white, lineWidth: 1))
                    .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                    .gesture(DragGesture().onChanged { value in
                        if dragStart == nil { dragStart = crop }
                        guard var next = dragStart else { return }
                        next.x += value.translation.width / max(1, geometry.size.width)
                        next.y += value.translation.height / max(1, geometry.size.height)
                        crop = next.clamped
                    }.onEnded { _ in dragStart = nil })
                    .accessibilityIdentifier("cropMoveFrame").accessibilityLabel("Move crop frame")
                ForEach(0..<4) { corner in
                    let right = corner == 1 || corner == 2
                    let bottom = corner >= 2
                    RoundedRectangle(cornerRadius: 3).fill(Theme.accent).frame(width: 12, height: 12)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                        .position(x: right ? rect.maxX : rect.minX, y: bottom ? rect.maxY : rect.minY)
                        .gesture(DragGesture(coordinateSpace: .named("cropCanvas")).onChanged { value in
                            if dragStart == nil { dragStart = crop }
                            guard let original = dragStart else { return }
                            let anchorX = right ? original.x : original.x + original.width
                            let anchorY = bottom ? original.y : original.y + original.height
                            let pointX = min(1, max(0, value.location.x / max(1, geometry.size.width)))
                            let pointY = min(1, max(0, value.location.y / max(1, geometry.size.height)))
                            var width = max(0.1, right ? pointX - anchorX : anchorX - pointX)
                            var height = max(0.1, bottom ? pointY - anchorY : anchorY - pointY)
                            width = min(width, right ? 1 - anchorX : anchorX)
                            height = min(height, bottom ? 1 - anchorY : anchorY)
                            if let lockedRatio {
                                let normalized = lockedRatio * original.canvasHeight / original.canvasWidth
                                width = min(width, height * normalized)
                                height = width / normalized
                            }
                            var next = original
                            next.width = width; next.height = height
                            next.x = right ? anchorX : anchorX - width
                            next.y = bottom ? anchorY : anchorY - height
                            crop = next.clamped
                        }.onEnded { _ in dragStart = nil })
                        .accessibilityIdentifier("cropCorner-\(corner)").accessibilityLabel("Resize crop corner \(corner + 1)")
                }
            }.coordinateSpace(name: "cropCanvas")
        }
    }
}

private struct FramingGestureSurface: UIViewRepresentable {
    @Binding var framing: ClipFraming
    let normalization: CGSize
    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) {
        view.framing = framing; view.normalization = normalization
        view.changed = { framing = $0.clamped }
        view.accessibilityValue = "Zoom \(Int(framing.zoom * 100)) percent. Rotation \(Int(framing.rotation)) degrees. Horizontal \(Int(framing.offsetX * 100)) percent. Vertical \(Int(framing.offsetY * 100)) percent."
    }
    final class Surface: UIView, UIGestureRecognizerDelegate {
        var framing = ClipFraming()
        var normalization = CGSize(width: 1, height: 1)
        var changed: ((ClipFraming) -> Void)?
        private var panOrigin = CGPoint.zero
        private var zoomOrigin = 1.0
        private var rotationOrigin = 0.0
        override init(frame: CGRect) {
            super.init(frame: frame)
            accessibilityIdentifier = "clipFramingGestures"
            isAccessibilityElement = true
            accessibilityLabel = "Clip framing canvas"
            for gesture in [UIPanGestureRecognizer(target: self, action: #selector(pan(_:))),
                            UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:))),
                            UIRotationGestureRecognizer(target: self, action: #selector(rotate(_:)))] {
                gesture.delegate = self; addGestureRecognizer(gesture)
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        @objc private func pan(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began { panOrigin = CGPoint(x: framing.offsetX, y: framing.offsetY) }
            let delta = gesture.translation(in: self)
            framing.offsetX = panOrigin.x + delta.x / max(1, normalization.width)
            framing.offsetY = panOrigin.y + delta.y / max(1, normalization.height)
            changed?(framing)
        }
        @objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began { zoomOrigin = framing.zoom }
            framing.zoom = zoomOrigin * gesture.scale; changed?(framing)
        }
        @objc private func rotate(_ gesture: UIRotationGestureRecognizer) {
            if gesture.state == .began { rotationOrigin = framing.rotation }
            framing.rotation = rotationOrigin + gesture.rotation * 180 / .pi; changed?(framing)
        }
    }
}
