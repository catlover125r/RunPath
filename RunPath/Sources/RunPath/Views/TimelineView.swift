import SwiftUI

struct TimelineView: View {
    @ObservedObject var vm: AnimationViewModel
    @State private var isDraggingPlayhead = false

    var body: some View {
        VStack(spacing: 0) {
            EffectControlsView(vm: vm)
            trackRow
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // Track line + add/delete buttons to the right
    private var trackRow: some View {
        HStack(spacing: 10) {
            trackLine

            // Diamond-shaped add keyframe button
            Button {
                vm.addKeyframeAtPlayhead()
            } label: {
                DiamondShape()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 16, height: 16)
                    .overlay(
                        Image(systemName: "plus")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.black)
                    )
            }
            .buttonStyle(.plain)

            // Trash button — enabled only when a keyframe is selected
            Button {
                vm.deleteSelectedKeyframe()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(vm.selectedKeyframeID != nil ? .white : .white.opacity(0.25))
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(vm.selectedKeyframeID != nil ? 0.12 : 0.04))
                    )
            }
            .buttonStyle(.plain)
            .disabled(vm.selectedKeyframeID == nil)
        }
        .frame(height: 36)
    }

    private var trackLine: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                // Track background
                Capsule()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 2)
                    .frame(maxWidth: .infinity)

                // Progress fill
                Capsule()
                    .fill(Color.white.opacity(0.5))
                    .frame(width: max(2, CGFloat(vm.timelinePosition) * w), height: 2)

                // Keyframes
                let track = vm.currentTrack
                ForEach(track.keyframes) { kf in
                    let x = CGFloat(kf.position) * w
                    let isSelected = vm.selectedKeyframeID == kf.id
                    DiamondShape()
                        .fill(isSelected ? Color.white : Color.white.opacity(0.55))
                        .frame(width: 12, height: 12)
                        .offset(x: x - 6)
                        .overlay(
                            DiamondShape()
                                .stroke(Color.white, lineWidth: isSelected ? 1.5 : 0)
                                .frame(width: 14, height: 14)
                                .offset(x: x - 7)
                        )
                        .onTapGesture {
                            if vm.selectedKeyframeID == kf.id {
                                vm.selectKeyframe(nil)
                            } else {
                                vm.selectKeyframe(kf.id)
                                vm.timelinePosition = kf.position
                            }
                        }
                }

                // Playhead
                let playX = CGFloat(vm.timelinePosition) * w
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: 36)
                    .offset(x: playX - 1)
                    .overlay(
                        Circle()
                            .fill(Color.white)
                            .frame(width: 10, height: 10)
                            .offset(x: playX - 5, y: -18)
                    )
            }
            .frame(height: 36)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { val in
                        let pos = max(0, min(1, Double(val.location.x / w)))
                        vm.selectKeyframe(nil)
                        vm.seek(to: pos)
                    }
            )
        }
        .frame(height: 36)
    }
}

struct DiamondShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        p.closeSubpath()
        return p
    }
}
