import Foundation
import SwiftUI

enum EffectType: String, CaseIterable, Codable, Identifiable {
    case speed = "Speed"
    case smoothness = "Smoothness"
    case cameraAltitude = "Altitude"
    case cameraTilt = "Tilt"
    case lineThickness = "Thickness"
    case lineColor = "Color"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .speed: return "speedometer"
        case .smoothness: return "waveform.path"
        case .cameraAltitude: return "arrow.up.and.down"
        case .cameraTilt: return "view.3d"
        case .lineThickness: return "line.diagonal"
        case .lineColor: return "paintpalette"
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .speed: return 0.1...1.9
        case .smoothness: return 0.0...1.0
        case .cameraAltitude: return 100...25000
        case .cameraTilt: return 0...85
        case .lineThickness: return 1...24
        case .lineColor: return 0...1
        }
    }

    var defaultValue: Double {
        switch self {
        case .speed: return 1.0
        case .smoothness: return 0.7
        case .cameraAltitude: return 1200
        case .cameraTilt: return 55
        case .lineThickness: return 5
        case .lineColor: return 0.58   // blue-ish by default
        }
    }

    var label: String { rawValue }

    var nudgeAmount: Double {
        switch self {
        case .speed:          return 0.1
        case .smoothness:     return 0.05
        case .cameraAltitude: return 100
        case .cameraTilt:     return 5
        case .lineThickness:  return 0.5
        case .lineColor:      return 0.05
        }
    }

    func formatValue(_ v: Double) -> String {
        switch self {
        case .speed: return String(format: "%.1fx", v)
        case .smoothness: return String(format: "%.0f%%", v * 100)
        case .cameraAltitude: return String(format: "%.0f m", v)
        case .cameraTilt: return String(format: "%.0f°", v)
        case .lineThickness: return String(format: "%.1f pt", v)
        case .lineColor: return String(format: "%.0f°", v * 360)
        }
    }
}

struct Keyframe: Identifiable, Codable {
    let id: UUID
    var position: Double  // 0..1 along timeline
    var value: Double

    init(id: UUID = UUID(), position: Double, value: Double) {
        self.id = id
        self.position = position
        self.value = value
    }
}

class EffectTrack: ObservableObject, Identifiable, Codable {
    let id: UUID
    let effectType: EffectType
    @Published var keyframes: [Keyframe]

    enum CodingKeys: String, CodingKey {
        case id, effectType, keyframes
    }

    init(effectType: EffectType) {
        self.id = UUID()
        self.effectType = effectType
        let def = effectType.defaultValue
        self.keyframes = [
            Keyframe(position: 0.0, value: def),
            Keyframe(position: 1.0, value: def)
        ]
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        effectType = try c.decode(EffectType.self, forKey: .effectType)
        keyframes = try c.decode([Keyframe].self, forKey: .keyframes)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(effectType, forKey: .effectType)
        try c.encode(keyframes, forKey: .keyframes)
    }

    func value(at position: Double) -> Double {
        let sorted = keyframes.sorted { $0.position < $1.position }
        guard !sorted.isEmpty else { return effectType.defaultValue }
        if position <= sorted.first!.position { return sorted.first!.value }
        if position >= sorted.last!.position { return sorted.last!.value }
        for i in 0..<(sorted.count - 1) {
            let a = sorted[i], b = sorted[i + 1]
            if position >= a.position && position <= b.position {
                let t = (position - a.position) / (b.position - a.position)
                let smooth = t * t * (3 - 2 * t)
                return a.value + (b.value - a.value) * smooth
            }
        }
        return effectType.defaultValue
    }

    func addKeyframe(at position: Double, value: Double) {
        let existing = keyframes.first { abs($0.position - position) < 0.005 }
        if existing != nil { return }
        keyframes.append(Keyframe(position: position, value: value))
        keyframes.sort { $0.position < $1.position }
    }

    func removeKeyframe(id: UUID) {
        guard keyframes.count > 2 else { return }
        keyframes.removeAll { $0.id == id }
    }
}

class AnimationSettings: ObservableObject, Codable {
    @Published var tracks: [EffectTrack]
    @Published var selectedEffect: EffectType = .speed

    enum CodingKeys: String, CodingKey {
        case tracks
    }

    init() {
        tracks = EffectType.allCases.map { EffectTrack(effectType: $0) }
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tracks = try c.decode([EffectTrack].self, forKey: .tracks)
        selectedEffect = .speed
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tracks, forKey: .tracks)
    }

    func track(for effect: EffectType) -> EffectTrack {
        tracks.first { $0.effectType == effect } ?? EffectTrack(effectType: effect)
    }

    func value(for effect: EffectType, at position: Double) -> Double {
        track(for: effect).value(at: position)
    }
}
