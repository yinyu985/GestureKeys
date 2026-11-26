import Foundation

public enum ShapePreset: String, CaseIterable, Identifiable {
    case upRight = "↗", upLeft = "↖", right = "→", left = "←", up = "↑", down = "↓"
    case downLeft = "↙", downRight = "↘"
    case upThenRight = "┌", upThenLeft = "┐", rightThenDown = "→↓", leftThenDown = "←↓"
    case check = "✓", caret = "∧", circle = "O"
    case v = "V", c = "C", l = "L", b = "B", w = "W"
    case two = "2", six = "6", seven = "7", less = "<", greater = ">"
    public var id: String { rawValue }
    // Retired presets remain readable in saved rules.
    public static let editorOptions: [Self] = [
        .up, .down,
        .left, .right,
        .upLeft, .upRight,
        .downLeft, .downRight,
        .circle, // The picker shows both directions in this row.
        .upThenLeft, .upThenRight,
        .leftThenDown, .rightThenDown,
        .v, .caret,
        .two, .six,
        .less, .greater,
        .c
    ]
    public var title: String {
        switch self {
        case .up: return L10n.text("由下往上")
        case .down: return L10n.text("由上往下")
        case .upRight: return L10n.text("从左下到右上")
        case .upLeft: return L10n.text("从右下到左上")
        case .downLeft: return L10n.text("从右上到左下")
        case .downRight: return L10n.text("从左上到右下")
        case .upThenRight: return L10n.text("先上后右 ┌")
        case .upThenLeft: return L10n.text("先上后左 ┐")
        case .rightThenDown: return L10n.text("先右后下 ┐")
        case .leftThenDown: return L10n.text("先左后下 ┌")
        case .check: return L10n.text("对勾 ✓")
        case .caret: return L10n.text("倒着的字母 V")
        case .circle: return L10n.text("O 圆圈（双向）")
        case .right: return L10n.text("由左往右")
        case .left: return L10n.text("由右往左")
        case .two, .six, .seven: return L10n.text("数字 %1$@", "\(rawValue)")
        case .less: return L10n.text("小于号 <")
        case .greater: return L10n.text("大于号 >")
        default: return L10n.text("字母 %1$@", "\(rawValue)")
        }
    }
}

/// Original, direction-preserving template matcher. No rotation normalization:
/// a leftward stroke must not become equivalent to a rightward one.
public enum Shape {
    public static func preset(_ shape: ShapePreset) -> [StrokePoint] {
        switch shape {
        case .upRight: return [StrokePoint(0, 100), StrokePoint(100, 0)]
        case .upLeft: return [StrokePoint(100, 100), StrokePoint(0, 0)]
        case .downLeft: return [StrokePoint(100, 0), StrokePoint(0, 100)]
        case .downRight: return [StrokePoint(0, 0), StrokePoint(100, 100)]
        case .upThenRight: return [StrokePoint(0, 100), StrokePoint(0, 0), StrokePoint(100, 0)]
        case .rightThenDown: return [StrokePoint(0, 0), StrokePoint(100, 0), StrokePoint(100, 100)]
        case .leftThenDown: return [StrokePoint(100, 0), StrokePoint(0, 0), StrokePoint(0, 100)]
        case .upThenLeft: return [StrokePoint(100, 100), StrokePoint(100, 0), StrokePoint(0, 0)]
        case .check: return [StrokePoint(0, 66), StrokePoint(26, 100), StrokePoint(100, 0)]
        case .caret: return [StrokePoint(0, 100), StrokePoint(50, 0), StrokePoint(100, 100)]
        case .circle: return (0...48).map { i in
            let angle = Double(i) * .pi / 24
            return StrokePoint(50 + 50 * sin(angle), 50 - 50 * cos(angle))
        }
        case .right: return [StrokePoint(0, 50), StrokePoint(100, 50)]
        case .left: return [StrokePoint(100, 50), StrokePoint(0, 50)]
        case .up: return [StrokePoint(50, 100), StrokePoint(50, 0)]
        case .down: return [StrokePoint(50, 0), StrokePoint(50, 100)]
        case .v: return [StrokePoint(0, 0), StrokePoint(50, 100), StrokePoint(100, 0)]
        case .w: return [StrokePoint(0, 0), StrokePoint(22, 100), StrokePoint(50, 29), StrokePoint(78, 100), StrokePoint(100, 0)]
        case .b:
            // One stroke: climb the stem, then draw both lobes from top to bottom.
            return [StrokePoint(0, 100), StrokePoint(0, 0), StrokePoint(33, 0), StrokePoint(51, 4),
                    StrokePoint(62, 14), StrokePoint(62, 29), StrokePoint(53, 42), StrokePoint(33, 48),
                    StrokePoint(3, 48), StrokePoint(37, 48), StrokePoint(60, 54), StrokePoint(70, 67),
                    StrokePoint(69, 82), StrokePoint(55, 95), StrokePoint(38, 100), StrokePoint(0, 100)]
        case .l: return [StrokePoint(0, 0), StrokePoint(0, 100), StrokePoint(100, 100)]
        case .two:
            return [StrokePoint(15, 23), StrokePoint(23, 10), StrokePoint(40, 3), StrokePoint(58, 4),
                    StrokePoint(72, 14), StrokePoint(77, 28), StrokePoint(70, 43), StrokePoint(55, 59),
                    StrokePoint(18, 97), StrokePoint(80, 97)]
        case .six:
            return [StrokePoint(66, 4), StrokePoint(40, 15), StrokePoint(23, 37), StrokePoint(15, 65),
                    StrokePoint(20, 84), StrokePoint(33, 95), StrokePoint(52, 98), StrokePoint(69, 89),
                    StrokePoint(76, 74), StrokePoint(73, 58), StrokePoint(60, 49), StrokePoint(43, 47),
                    StrokePoint(27, 54), StrokePoint(16, 66)]
        case .seven: return [StrokePoint(15, 3), StrokePoint(83, 3), StrokePoint(39, 98)]
        case .less: return [StrokePoint(78, 0), StrokePoint(18, 50), StrokePoint(78, 100)]
        case .greater: return [StrokePoint(22, 0), StrokePoint(82, 50), StrokePoint(22, 100)]
        case .c:
            return (0...32).map { i in
                let angle = -Double.pi / 3 - Double(i) * (4 * Double.pi / 3) / 32
                return StrokePoint(50 + 50 * cos(angle), 50 + 50 * sin(angle))
            }
        }
    }

    public static func normalize(_ input: [StrokePoint], count: Int = 64) -> [StrokePoint]? {
        guard input.count >= 2, input.count <= 4096, count >= 2,
              input.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        var points: [StrokePoint] = [input[0]]
        for p in input.dropFirst() where p.distance(to: points.last!) > 0.05 { points.append(p) }
        guard points.count > 1 else { return nil }
        var cumulative = [0.0]
        for i in 1..<points.count { cumulative.append(cumulative.last! + points[i - 1].distance(to: points[i])) }
        guard let length = cumulative.last, length >= 12 else { return nil }
        var samples: [StrokePoint] = []
        var segment = 1
        for i in 0..<count {
            let target = length * Double(i) / Double(count - 1)
            while segment < cumulative.count - 1 && cumulative[segment] < target { segment += 1 }
            let start = points[segment - 1], end = points[segment]
            let fraction = (target - cumulative[segment - 1]) / max(0.000001, cumulative[segment] - cumulative[segment - 1])
            samples.append(StrokePoint(start.x + (end.x - start.x) * fraction, start.y + (end.y - start.y) * fraction))
        }
        let minX = samples.map(\.x).min()!, maxX = samples.map(\.x).max()!
        let minY = samples.map(\.y).min()!, maxY = samples.map(\.y).max()!
        let scale = max(maxX - minX, maxY - minY)
        guard scale > 0.000001 else { return nil }
        let cx = samples.reduce(0) { $0 + $1.x } / Double(count)
        let cy = samples.reduce(0) { $0 + $1.y } / Double(count)
        return samples.map { StrokePoint(($0.x - cx) / scale, ($0.y - cy) / scale) }
    }

    /// Fit the path without resampling. A width cap can compress unusually wide previews.
    public static func thumbnail(_ points: [StrokePoint], width: Double, height: Double, padding: Double,
                                 maxWidthToHeightRatio: Double? = nil) -> [StrokePoint] {
        guard let first = points.first, points.count > 1, padding >= 0, width > 2 * padding, height > 2 * padding else { return [] }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            guard point.x.isFinite, point.y.isFinite else { return [] }
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let spanX = maxX - minX, spanY = maxY - minY
        guard spanX.isFinite, spanY.isFinite, max(spanX, spanY) > 0 else { return [] }
        let scale = min(spanX > 0 ? (width - 2 * padding) / spanX : .infinity,
                        spanY > 0 ? (height - 2 * padding) / spanY : .infinity)
        guard scale.isFinite else { return [] }
        let fittedHeight = spanY * scale
        let cap = maxWidthToHeightRatio.map { max(fittedHeight, (height - 2 * padding) * 0.9) * $0 } ?? .infinity
        let scaleX = spanX > 0 ? min(scale, cap / spanX) : scale
        let x = (width - spanX * scaleX) / 2, y = (height - fittedHeight) / 2
        return points.map { StrokePoint(($0.x - minX) * scaleX + x, ($0.y - minY) * scale + y) }
    }

    public static func distance(_ a: [StrokePoint], _ b: [StrokePoint]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        let position = sqrt(zip(a, b).reduce(0.0) { $0 + pow($1.0.distance(to: $1.1), 2) } / Double(a.count))
        // Endpoint direction penalizes reversals and gives straight gestures useful separation.
        let av = StrokePoint(a.last!.x - a[0].x, a.last!.y - a[0].y)
        let bv = StrokePoint(b.last!.x - b[0].x, b.last!.y - b[0].y)
        let al = hypot(av.x, av.y), bl = hypot(bv.x, bv.y)
        let direction = al > 0.1 && bl > 0.1 ? (1 - max(-1, min(1, (av.x * bv.x + av.y * bv.y) / (al * bl)))) / 2 : 0
        return position + direction * 0.12
    }

    public static let matchCutoff = 0.24
    public static let ambiguityMargin = 0.035
    static func equivalentTemplates(_ a: [StrokePoint], _ b: [StrokePoint]) -> Bool {
        guard let lhs = normalize(a), let rhs = normalize(b) else { return false }
        return distance(lhs, rhs) < ambiguityMargin
    }

    public enum Match: Equatable, Sendable {
        case matched(UUID, Double)
        case ambiguous
        case noMatch
    }

    public struct Template: Sendable {
        public let rule: Rule
        let normalized: [StrokePoint]

        init(rule: Rule, normalized: [StrokePoint]) {
            self.rule = rule
            self.normalized = normalized
        }
    }

    public struct Candidate: Sendable {
        public let ruleID: UUID
        public let distance: Double
    }

    public enum Failure: String, Sendable {
        case invalidStroke = "unnormalizable_stroke"
        case noTemplates = "no_gesture_templates"
        case noFiniteScores = "no_finite_scores"
        case outsideCutoff = "outside_match_cutoff"
        case ambiguous = "ambiguous_candidates"
    }

    public struct Recognition: Sendable {
        public let match: Match
        /// The two lowest finite distances, in rank order, when available.
        public let candidates: [Candidate]
        public let failure: Failure?
    }

    static func templates(rule: Rule, normalized: [StrokePoint]) -> [Template] {
        let template = Template(rule: rule, normalized: normalized)
        switch ShapePreset(rawValue: rule.shapeName) {
        case .circle, .v, .caret:
            return [template, Template(rule: rule, normalized: Array(normalized.reversed()))]
        case .upThenLeft, .upThenRight, .leftThenDown, .rightThenDown:
            // A right angle can have unequal legs. Keep their order and directions.
            return [template] + [0.55, 1.8].compactMap { widthScale in
                let points = rule.points.map { StrokePoint($0.x * widthScale, $0.y) }
                return normalize(points).map { Template(rule: rule, normalized: $0) }
            }
        default:
            return [template]
        }
    }

    public static func recognize(_ points: [StrokePoint], rules: [Rule]) -> Match {
        let all = rules.flatMap { rule in
            normalize(rule.points).map { Self.templates(rule: rule, normalized: $0) } ?? []
        }
        return recognize(points, templates: all).match
    }

    public static func recognize(_ points: [StrokePoint], templates: [Template]) -> Recognition {
        guard !templates.isEmpty else { return Recognition(match: .noMatch, candidates: [], failure: .noTemplates) }
        guard let candidate = normalize(points), let start = candidate.first, let end = candidate.last else {
            return Recognition(match: .noMatch, candidates: [], failure: .invalidStroke)
        }
        let dx = end.x - start.x, dy = end.y - start.y
        let chord = hypot(dx, dy)
        let maxDeviation = candidate.map { abs(dx * ($0.y - start.y) - dy * ($0.x - start.x)) }.max() ?? 0
        let isStraight = chord > 0.1 && maxDeviation < 0.18 * chord * chord
        let rightmost = candidate.map(\.x).max() ?? start.x
        let leftmost = candidate.map(\.x).min() ?? start.x
        // Chevron strokes need two horizontal legs. A small hook at the end of a corner is insufficient.
        let rightReturn = rightmost - max(start.x, end.x)
        let leftReturn = min(start.x, end.x) - leftmost

        var seen = Set<UUID>()
        let ranked = templates.indices.compactMap { index -> (index: Int, score: Double)? in
            let template = templates[index]
            switch ShapePreset(rawValue: template.rule.shapeName) {
            case .up, .down, .left, .right, .upLeft, .upRight, .downLeft, .downRight:
                guard isStraight else { return nil }
            case .upThenLeft, .upThenRight, .leftThenDown, .rightThenDown:
                guard !isStraight else { return nil }
            case .greater:
                guard rightReturn >= 0.5 * (rightmost - min(start.x, end.x)), rightReturn >= 0.25 * abs(dy) else { return nil }
            case .less:
                guard leftReturn >= 0.5 * (max(start.x, end.x) - leftmost), leftReturn >= 0.25 * abs(dy) else { return nil }
            default: break
            }
            let score = distance(candidate, template.normalized)
            return score.isFinite ? (index, score) : nil
        }.sorted { $0.score < $1.score }.filter { seen.insert(templates[$0.index].rule.id).inserted }
        guard let best = ranked.first else { return Recognition(match: .noMatch, candidates: [], failure: .noFiniteScores) }
        let closest = ranked.prefix(2).map { Candidate(ruleID: templates[$0.index].rule.id, distance: $0.score) }
        guard best.score < matchCutoff else { return Recognition(match: .noMatch, candidates: closest, failure: .outsideCutoff) }
        let tied = ranked.prefix { $0.score - best.score < ambiguityMargin }
        if tied.count == 1 {
            return Recognition(match: .matched(templates[best.index].rule.id, best.score), candidates: closest, failure: nil)
        }
        // The same physical shape can be drawn at different positions and scales. A unique
        // app-specific equivalent wins; never break a tie between different shapes or two local rules.
        let local = tied.filter { !templates[$0.index].rule.bundleID.isEmpty }
        if local.count == 1, let winner = local.first, winner.score < matchCutoff {
            let template = templates[winner.index]
            if tied.allSatisfy({ templates[$0.index].rule.id == template.rule.id || distance(template.normalized, templates[$0.index].normalized) < ambiguityMargin }) {
                return Recognition(match: .matched(template.rule.id, winner.score), candidates: closest, failure: nil)
            }
        }
        return Recognition(match: .ambiguous, candidates: closest, failure: .ambiguous)
    }
}
