import SwiftUI
import AppKit

struct TimelineView: View {
    @EnvironmentObject var vm: EditorViewModel

    private let rulerHeight: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.stroke).frame(height: 1)
            GeometryReader { geo in
                Group {
                    if vm.totalDuration <= 0 {
                        emptyTimeline
                    } else {
                        timelineBody(width: geo.size.width, height: geo.size.height)
                    }
                }
                .onChange(of: geo.size.width, initial: true) { _, w in vm.timelineWidth = w }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .frame(height: 150)
        .background(Theme.panel.opacity(0.45))
    }

    private func fitScale(_ width: CGFloat) -> Double {
        Double(width) / max(vm.totalDuration, 0.0001)
    }

    // MARK: Body (ruler + clips + playhead, horizontally scrollable)

    private func timelineBody(width: CGFloat, height: CGFloat) -> some View {
        let total = max(vm.totalDuration, 0.0001)
        let scale = vm.pps ?? fitScale(width)
        let contentWidth = CGFloat(total * scale)
        let bodyHeight = height
        let clipHeight = max(40, height - rulerHeight - 6)
        let playheadX = min(max(CGFloat(vm.currentTime) * CGFloat(scale), 0), contentWidth)
        let anchorStep = max(1, Int((total / 400).rounded(.up)))

        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 6) {
                        RulerView(scale: CGFloat(scale), total: total, width: contentWidth)
                            .frame(width: contentWidth, height: rulerHeight)
                            .contentShape(Rectangle())
                            .gesture(scrubGesture(scale: scale))
                        chunkRow(scale: CGFloat(scale))
                            .frame(width: contentWidth, height: clipHeight)
                    }

                    // Invisible scroll anchors so playback can keep the playhead in view.
                    ForEach(Array(stride(from: 0, through: Int(total), by: anchorStep)), id: \.self) { sec in
                        Color.clear
                            .frame(width: 1, height: 1)
                            .position(x: CGFloat(Double(sec) * scale), y: 1)
                            .id(sec)
                    }

                    PlayheadView()
                        .frame(width: 12, height: bodyHeight)
                        .offset(x: playheadX - 6)
                        .allowsHitTesting(false)
                }
                .frame(width: contentWidth, height: bodyHeight)
            }
            .frame(height: bodyHeight)
            .onChange(of: vm.currentTime) { _, time in
                guard vm.isPlaying, vm.pps != nil, !vm.isScrubbing else { return }
                let snapped = (Int(time) / anchorStep) * anchorStep
                proxy.scrollTo(snapped, anchor: .center)
            }
        }
    }

    private func chunkRow(scale: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { vm.clearSelection() }
            HStack(spacing: 0) {
                ForEach(vm.chunks) { chunk in
                    ChunkView(chunk: chunk, slotWidth: CGFloat(chunk.outputDuration) * scale)
                }
            }
        }
    }

    private func scrubGesture(scale: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in vm.scrub(to: Double(value.location.x) / max(scale, 0.0001)) }
            .onEnded { _ in vm.endScrub() }
    }

    private var emptyTimeline: some View {
        VStack(spacing: 6) {
            Image(systemName: "rectangle.on.rectangle.slash")
                .font(.system(size: 18))
                .foregroundStyle(Theme.textTertiary)
            Text("All clips removed — press ⌘Z to undo")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - One clip on the timeline

private struct ChunkView: View {
    @EnvironmentObject var vm: EditorViewModel
    let chunk: Chunk
    let slotWidth: CGFloat

    private var isSelected: Bool { vm.selection.contains(chunk.id) }
    private var visibleWidth: CGFloat { max(2, slotWidth - 4) }

    var body: some View {
        FilmstripCard(chunk: chunk, width: visibleWidth, isSelected: isSelected)
            .frame(width: visibleWidth)
            .frame(width: max(2, slotWidth))
            .contentShape(Rectangle())
            .onTapGesture {
                let additive = NSEvent.modifierFlags.contains(.command)
                vm.select(chunk.id, additive: additive)
            }
    }
}

private struct FilmstripCard: View {
    @EnvironmentObject var vm: EditorViewModel
    let chunk: Chunk
    let width: CGFloat
    let isSelected: Bool

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let aspect = vm.aspect(sourceID: chunk.sourceID)
            let tileW = max(30, h * aspect)
            let tiles = max(1, Int((width / tileW).rounded(.up)))
            ZStack {
                Theme.clip
                HStack(spacing: 0) {
                    ForEach(0..<tiles, id: \.self) { i in
                        let sourceTime = chunk.start
                            + (Double(i) + 0.5) / Double(tiles) * chunk.sourceDuration
                        thumb(at: sourceTime, w: width / CGFloat(tiles), sourceID: chunk.sourceID)
                    }
                }
                LinearGradient(
                    colors: [.clear, .black.opacity(0.5)],
                    startPoint: .center, endPoint: .bottom
                )
                badges
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isSelected ? Theme.accent : Theme.clipBorder,
                        lineWidth: isSelected ? 2 : 1)
        )
        .shadow(color: isSelected ? Theme.accent.opacity(0.35) : .clear, radius: 6)
    }

    @ViewBuilder
    private func thumb(at sourceTime: Double, w: CGFloat, sourceID: UUID) -> some View {
        ZStack {
            Theme.clip
            if let image = vm.thumbnail(sourceID: sourceID, near: sourceTime) {
                Image(nsImage: image).resizable().scaledToFill()
            }
        }
        .frame(width: w)
        .clipped()
    }

    private var badges: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                if chunk.speed != 1.0 {
                    Text(speedLabel(chunk.speed))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.speedTint))
                }
                Spacer()
                if width > 54 {
                    Text(timecode(chunk.outputDuration))
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 5)
        }
    }
}

// MARK: - Playhead

private struct PlayheadView: View {
    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.white)
                .frame(width: 12, height: 14)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
            Rectangle()
                .fill(Color.white)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Ruler

private struct RulerView: View {
    let scale: CGFloat
    let total: Double
    let width: CGFloat

    var body: some View {
        let step = niceTimeStep(scale: scale)
        let count = step > 0 ? Int(total / step) : 0
        ZStack(alignment: .topLeading) {
            ForEach(0...max(0, count), id: \.self) { i in
                let t = Double(i) * step
                let x = CGFloat(t) * scale
                if x <= width - 4 {
                    VStack(alignment: .leading, spacing: 3) {
                        Rectangle().fill(Theme.strokeHi).frame(width: 1, height: 6)
                        Text(timecode(t, showCentis: step < 1))
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize()
                    }
                    .offset(x: x)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// Picks a human-friendly time step so ticks land roughly every ~80pt.
private func niceTimeStep(scale: CGFloat) -> Double {
    let targetSeconds = 80.0 / Double(max(scale, 0.0001))
    let candidates: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
    for c in candidates where c >= targetSeconds { return c }
    return candidates.last ?? 3600
}
