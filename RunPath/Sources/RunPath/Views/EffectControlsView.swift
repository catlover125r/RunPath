import SwiftUI

struct EffectControlsView: View {
    @ObservedObject var vm: AnimationViewModel

    var body: some View {
        VStack(spacing: 10) {
            // Effect selector tabs
            effectTabs
            // Slider row
            sliderRow
        }
        .padding(.bottom, 6)
    }

    private var effectTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(EffectType.allCases) { effect in
                    let isSelected = vm.animationSettings.selectedEffect == effect
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            vm.animationSettings.selectedEffect = effect
                            vm.selectedKeyframeID = nil
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: effect.icon)
                                .font(.system(size: 11, weight: .medium))
                            Text(effect.label)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(isSelected ? Color.white : Color.white.opacity(0.1),
                                    in: Capsule())
                        .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var sliderRow: some View {
        let effect = vm.animationSettings.selectedEffect
        let track = vm.currentTrack
        let sliderVal: Binding<Double> = Binding(
            get: {
                if let kfID = vm.selectedKeyframeID,
                   let kf = track.keyframes.first(where: { $0.id == kfID }) {
                    return kf.value
                }
                return track.value(at: vm.timelinePosition)
            },
            set: { vm.setSliderValue($0) }
        )

        return HStack(spacing: 10) {
            Text(effect.formatValue(sliderVal.wrappedValue))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 70, alignment: .leading)

            if effect == .lineColor {
                ColorSlider(value: sliderVal)
            } else {
                Slider(value: sliderVal, in: effect.range)
                    .tint(Color.white)
            }

            HStack(spacing: 8) {
                Button {
                    vm.addKeyframeAtPlayhead()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.15), in: Circle())
                }
                .buttonStyle(.plain)

                Button {
                    vm.deleteSelectedKeyframe()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(vm.selectedKeyframeID != nil ? .white : .white.opacity(0.3))
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(vm.selectedKeyframeID != nil ? 0.15 : 0.05),
                                    in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(vm.selectedKeyframeID == nil)
            }
        }
    }
}

struct ColorSlider: View {
    @Binding var value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(hue: 0, saturation: 0.85, brightness: 1),
                        Color(hue: 0.17, saturation: 0.85, brightness: 1),
                        Color(hue: 0.33, saturation: 0.85, brightness: 1),
                        Color(hue: 0.5, saturation: 0.85, brightness: 1),
                        Color(hue: 0.67, saturation: 0.85, brightness: 1),
                        Color(hue: 0.83, saturation: 0.85, brightness: 1),
                        Color(hue: 1.0, saturation: 0.85, brightness: 1)
                    ]),
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(height: 6)
                .clipShape(Capsule())

                Circle()
                    .fill(Color(hue: value, saturation: 0.85, brightness: 1))
                    .frame(width: 20, height: 20)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .offset(x: CGFloat(value) * (geo.size.width - 20))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        value = max(0, min(1, Double(drag.location.x / geo.size.width)))
                    }
            )
        }
        .frame(height: 20)
    }
}
