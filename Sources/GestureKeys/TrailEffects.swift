import CoreGraphics
import GestureCore

private struct TrailSamplePoint {
    let point: CGPoint
    let angle: Double
    let distance: Double

    func offset(along: Double = 0, across: Double = 0) -> CGPoint {
        let dx = cos(angle), dy = sin(angle)
        return CGPoint(x: point.x + dx * along - dy * across, y: point.y + dy * along + dx * across)
    }
}

private struct TrailTrack {
    let points: [CGPoint]
    let distances: [Double]
    let detail: Double
    var length: Double { distances.last ?? 0 }

    init(_ input: [CGPoint]) {
        guard let first = input.first else { points = []; distances = []; detail = 1; return }
        var points = [first]
        var distances = [0.0]
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in input.dropFirst() {
            let previous = points[points.count - 1]
            let step = hypot(point.x - previous.x, point.y - previous.y)
            guard step > 0.01 else { continue }
            points.append(point)
            distances.append(distances[distances.count - 1] + step)
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        self.points = points
        self.distances = distances
        // Compact gestures need a narrow trail even when the width is at its maximum.
        detail = min(1, max(0.18, max(maxX - minX, maxY - minY) / 65))
    }

    func samples(spacing: Double, limit: Int) -> [TrailSamplePoint] {
        guard points.count > 1 else { return [] }
        // Keep the sampling lattice anchored at the start as the gesture grows.
        let step = spacing * max(1, ceil(length / (spacing * Double(limit - 1))))
        var segment = 1
        let offsets = Array(stride(from: 0.0, to: length, by: step)) + [length]
        return offsets.map { distance in
            while segment < distances.count - 1 && distances[segment] < distance { segment += 1 }
            let start = points[segment - 1], end = points[segment]
            let fraction = (distance - distances[segment - 1]) / (distances[segment] - distances[segment - 1])
            let dx = end.x - start.x, dy = end.y - start.y
            return TrailSamplePoint(point: CGPoint(x: start.x + dx * fraction, y: start.y + dy * fraction),
                                    angle: atan2(dy, dx), distance: distance)
        }
    }
}

private struct TrailRandom {
    var seed: UInt64

    mutating func unit() -> Double {
        seed &+= 0x9e3779b97f4a7c15
        var bits = (seed ^ (seed >> 30)) &* 0xbf58476d1ce4e5b9
        bits = (bits ^ (bits >> 27)) &* 0x94d049bb133111eb
        return Double((bits ^ (bits >> 31)) >> 11) / 9_007_199_254_740_992
    }

    mutating func spread() -> Double { unit() + unit() + unit() - 1.5 }
}

private extension TrailTint {
    func color(lift: Double = 0, alpha: Double = 1) -> CGColor {
        CGColor(red: red + (1 - red) * lift, green: green + (1 - green) * lift, blue: blue + (1 - blue) * lift, alpha: alpha)
    }
}

enum TrailRenderer {
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let petal: CGPath = {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -1.4, y: 5.45))
        path.addCurve(to: CGPoint(x: -7.9, y: -2.5), control1: CGPoint(x: -4.7, y: 4.3), control2: CGPoint(x: -7.2, y: 1))
        path.addCurve(to: CGPoint(x: -3.1, y: -9.25), control1: CGPoint(x: -8.6, y: -6.2), control2: CGPoint(x: -6.5, y: -8.9))
        path.addCurve(to: CGPoint(x: 0.54, y: -7.56), control1: CGPoint(x: -1.8, y: -9.39), control2: CGPoint(x: -0.25, y: -8.94))
        path.addCurve(to: CGPoint(x: 3.96, y: -8.19), control1: CGPoint(x: 1.35, y: -8.63), control2: CGPoint(x: 2.6, y: -8.78))
        path.addCurve(to: CGPoint(x: 7.07, y: -0.74), control1: CGPoint(x: 7.14, y: -6.73), control2: CGPoint(x: 8.37, y: -3.98))
        path.addCurve(to: CGPoint(x: 0.54, y: 5.3), control1: CGPoint(x: 5.77, y: 2.53), control2: CGPoint(x: 2.54, y: 4.92))
        path.addQuadCurve(to: CGPoint(x: -1.4, y: 5.45), control: CGPoint(x: -0.56, y: 5.75))
        path.closeSubpath()
        return path
    }()

    private static func scale(for style: TrailStyle) -> Double { pow(style.width / 3, 0.60) }

    static func bounds(_ points: [CGPoint], style: TrailStyle) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let inset = style.effect == .line ? style.width / 2 + 2 : 50 * scale(for: style)
        return CGRect(x: minX - inset, y: minY - inset, width: maxX - minX + 2 * inset, height: maxY - minY + 2 * inset)
    }

    static func draw(_ points: [CGPoint], style: TrailStyle, phase: Double, opacity: Double = 1, in context: CGContext) {
        guard points.count > 1, opacity > 0 else { return }
        let tint = style.tint
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if style.effect == .line {
            let path = CGMutablePath()
            path.addLines(between: points)
            context.setLineWidth(style.width)
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.33))
            context.addPath(path)
            context.strokePath()
            context.setStrokeColor(tint.color())
            context.addPath(path)
            context.strokePath()
            return
        }

        let track = TrailTrack(points)
        let scale = scale(for: style)
        let particleSize = scale * (0.30 + 0.70 * track.detail)
        let scatter = (0.76 + 0.24 * scale) * track.detail
        if opacity < 1 {
            context.setAlpha(opacity)
            context.beginTransparencyLayer(in: bounds(points, style: style), auxiliaryInfo: nil)
        }
        defer { if opacity < 1 { context.endTransparencyLayer() } }
        switch style.effect {
        case .line: break
        case .petals: drawPetals(track, tint: tint, scale: particleSize, scatter: scatter, phase: phase, in: context)
        case .squares: drawSquares(track, tint: tint, scale: particleSize, scatter: scatter, phase: phase, in: context)
        case .dots: drawDots(track, tint: tint, scale: particleSize, scatter: scatter, phase: phase, in: context)
        case .meteor: drawMeteor(track, tint: tint, scale: scale * (0.52 + 0.48 * track.detail), in: context)
        }
    }

    private static func age(_ sample: TrailSamplePoint, on track: TrailTrack) -> Double {
        min(1, (track.length - sample.distance) / 240)
    }

    private static func drawPetals(_ track: TrailTrack, tint: TrailTint, scale: Double, scatter: Double, phase: Double, in context: CGContext) {
        let gradients = [0.12, 0.34, 0.57].compactMap { lift in
            CGGradient(colorsSpace: colorSpace,
                       colors: [tint.color(lift: min(0.93, lift + 0.27)), tint.color(lift: lift), tint.color()] as CFArray,
                       locations: [0, 0.56, 1])
        }
        guard !gradients.isEmpty else { return }
        var random = TrailRandom(seed: 77)
        for sample in track.samples(spacing: 8.5, limit: 150) {
            let age = age(sample, on: track)
            let seed = random.unit()
            let spread = (random.spread() * (6 + 7 * age) + sin(phase * 4 + seed * 12) * 2 * age) * scatter
            let position = sample.offset(along: random.spread() * 4 * scatter, across: spread)
            let size = scale * (0.54 + random.unit() * 0.42) * (1 - 0.24 * age)
            let spin = seed * 2 * .pi + (phase * 2.4 + age) * (seed - 0.5)
            context.saveGState()
            context.translateBy(x: position.x, y: position.y)
            context.rotate(by: spin)
            context.scaleBy(x: size * (0.76 + random.unit() * 0.26), y: size)
            context.setAlpha((1 - 0.56 * age) * (0.65 + random.unit() * 0.35))
            context.addPath(petal)
            context.clip()
            context.drawLinearGradient(gradients[Int(seed * Double(gradients.count))],
                                       start: CGPoint(x: -5, y: -8), end: CGPoint(x: 4, y: 5),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            context.restoreGState()
        }
    }

    private static func drawSquares(_ track: TrailTrack, tint: TrailTint, scale: Double, scatter: Double, phase: Double, in context: CGContext) {
        var random = TrailRandom(seed: 389)
        let colors = [tint.color(), tint.color(lift: 0.22), tint.color(lift: 0.48)]
        let sizes = [1.6, 2.1, 2.6, 3.1, 3.8, 4.7, 5.6]
        let grid = max(0.75, 1.65 * scale)
        for sample in track.samples(spacing: 3.8, limit: 240) {
            let age = age(sample, on: track)
            let seed = random.unit()
            let drift = (random.spread() * (3.6 + 3 * age) + sin(phase * 3 + seed * 18) * age) * scatter
            let position = sample.offset(along: random.spread() * 2.1 * scatter, across: drift)
            let size = sizes[Int(random.unit() * Double(sizes.count))] * scale
            let square = CGRect(x: (position.x / grid).rounded() * grid - size / 2,
                                y: (position.y / grid).rounded() * grid - size / 2, width: size, height: size)
            let color = colors[Int(seed * Double(colors.count))]
            context.setAlpha((1 - 0.62 * age) * (0.52 + random.unit() * 0.48))
            if random.unit() < 0.18 && size >= 2.4 {
                context.setStrokeColor(color)
                context.setLineWidth(max(0.65, scale * 0.75))
                context.stroke(square)
            } else {
                context.setFillColor(color)
                context.fill(square)
            }
        }
    }

    private static func drawDots(_ track: TrailTrack, tint: TrailTint, scale: Double, scatter: Double, phase: Double, in context: CGContext) {
        var random = TrailRandom(seed: 4164)
        let colors = [tint.color(), tint.color(lift: 0.24), tint.color(lift: 0.62)]
        for sample in track.samples(spacing: 2.9, limit: 154) {
            let age = age(sample, on: track)
            for _ in 0..<7 {
                let seed = random.unit()
                let across = random.spread() * (5.6 + 2.6 * age) + sin(phase * 3 + seed * 18) * age
                let position = sample.offset(along: random.spread() * 2.8 * scatter, across: across * scatter)
                let radius = (0.36 + random.unit() * 0.6) * scale
                context.setFillColor(colors[Int(seed * Double(colors.count))])
                context.setAlpha((1 - 0.65 * age) * (0.42 + random.unit() * 0.52))
                context.fillEllipse(in: CGRect(x: position.x - radius, y: position.y - radius, width: 2 * radius, height: 2 * radius))
            }
        }
    }

    static func meteorWidth(distance: Double, scale: Double) -> Double {
        // A fixed minimum and a gradual falloff keep a long tail visible.
        scale * (0.9 + 6.5 / pow(1 + distance / 170, 1.14))
    }

    private static func drawMeteor(_ track: TrailTrack, tint: TrailTint, scale: Double, in context: CGContext) {
        let samples = track.samples(spacing: 2.6, limit: 600)
        guard let tip = samples.last else { return }
        let segments = zip(samples, samples.dropFirst()).map { a, b in
            let distance = track.length - (a.distance + b.distance) / 2
            let brightness = (0.40 + 0.60 / (1 + distance / 155)) * min(1, b.distance / 16)
            return (start: a.point, end: b.point, width: meteorWidth(distance: distance, scale: scale), brightness: brightness)
        }
        // Draw the body in chronological order so a stroke crossing itself preserves its bright leading end.
        let bands: [(width: Double, lift: Double, alpha: Double)] = [(2.7, 0, 0.12), (1.8, 0, 0.20), (1, 0.20, 0.82), (0.36, 0.72, 0.79)]
        for band in bands {
            context.setStrokeColor(tint.color(lift: band.lift))
            for segment in segments {
                context.setAlpha(band.alpha * segment.brightness)
                context.setLineWidth(segment.width * band.width)
                context.move(to: segment.start)
                context.addLine(to: segment.end)
                context.strokePath()
            }
        }

        context.setAlpha(1)
        context.translateBy(x: tip.point.x, y: tip.point.y)
        context.rotate(by: tip.angle)
        context.scaleBy(x: scale, y: scale)
        let glow = CGGradient(colorsSpace: colorSpace,
                              colors: [tint.color(lift: 0.55, alpha: 0.45), tint.color(alpha: 0.11), tint.color(alpha: 0)] as CFArray,
                              locations: [0, 0.47, 1])
        if let glow {
            context.drawRadialGradient(glow, startCenter: .zero, startRadius: 2, endCenter: .zero, endRadius: 16, options: [])
        }
        let head = CGMutablePath()
        head.move(to: CGPoint(x: -14, y: 0))
        head.addCurve(to: CGPoint(x: 0.8, y: -4.7), control1: CGPoint(x: -9, y: -2.2), control2: CGPoint(x: -5, y: -4.8))
        head.addCurve(to: CGPoint(x: 0.8, y: 4.7), control1: CGPoint(x: 6.4, y: -4.5), control2: CGPoint(x: 6.4, y: 4.5))
        head.addCurve(to: CGPoint(x: -14, y: 0), control1: CGPoint(x: -5, y: 4.8), control2: CGPoint(x: -9, y: 2.2))
        head.closeSubpath()
        context.setFillColor(tint.color(lift: 0.70))
        context.addPath(head)
        context.fillPath()
        context.setFillColor(tint.color(lift: 0.94))
        context.fillEllipse(in: CGRect(x: -3.5, y: -2.9, width: 7.8, height: 5.8))
    }
}
