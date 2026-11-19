import Foundation

/// Bounded, deterministic mouse-gesture state, independent of event taps and UI.
public struct StrokeSession {
    public private(set) var points: [StrokePoint]
    public private(set) var distance = 0.0
    public let startedAt: TimeInterval
    public init(start: StrokePoint, time: TimeInterval) { points = [start]; startedAt = time }
    public var isDrag: Bool { distance >= 10 }
    public mutating func append(_ p: StrokePoint, time: TimeInterval) -> Bool {
        guard time - startedAt <= 10, points.count < 2048, p.x.isFinite, p.y.isFinite else { return false }
        if let last = points.last, last.distance(to: p) >= 0.75 {
            distance += last.distance(to: p); points.append(p)
        }
        return true
    }
}
