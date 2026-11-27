import Foundation

/// Bounded, deterministic mouse-gesture state, independent of event taps and UI.
public struct StrokeSession {
    public private(set) var points: [StrokePoint]
    public private(set) var distance = 0.0
    public let startedAt: TimeInterval
    public init(start: StrokePoint, time: TimeInterval) { points = [start]; startedAt = time }
    public private(set) var isDrag = false
    public mutating func append(_ p: StrokePoint, time: TimeInterval) -> Bool {
        guard p.x.isFinite, p.y.isFinite else { return false }
        // Latch once the pointer leaves the click radius, not after enough jitter in place.
        if !isDrag, points[0].distance(to: p) >= 10 { isDrag = true }
        guard time - startedAt <= 10, points.count < 2048 else { return false }
        let step = points.last!.distance(to: p)
        if step >= 0.75 { distance += step; points.append(p) }
        return true
    }
}
