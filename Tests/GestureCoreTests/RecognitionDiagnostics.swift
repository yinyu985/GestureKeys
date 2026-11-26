import Foundation
import GestureCore

extension GestureCoreTests {
    func testRecognitionDiagnostics() throws {
        let up = Shape.preset(.up)
        let left = Rule(kind: .gesture, points: Shape.preset(.left), action: .copy)
        let down = Rule(kind: .gesture, points: Shape.preset(.down), action: .copy)
        let exact = Rule(kind: .gesture, points: up, action: .copy)
        let tilted = Rule(kind: .gesture, points: [StrokePoint(50, 100), StrokePoint(55, 0)], action: .copy)

        func recognize(_ points: [StrokePoint], _ rules: [Rule]) -> Shape.Recognition {
            let templates = RuleIndex(rules).scoped(to: "").mouseBindings(for: 1).templates
            return Shape.recognize(points, templates: templates)
        }
        func expectedDistance(to rule: Rule) -> Double {
            Shape.distance(Shape.normalize(up)!, Shape.normalize(rule.points)!)
        }

        let miss = recognize(up, [down, left])
        guard miss.match == .noMatch, miss.failure == .outsideCutoff,
              miss.candidates.map(\.ruleID) == [left.id, down.id],
              miss.candidates.map(\.distance) == [expectedDistance(to: left), expectedDistance(to: down)],
              miss.candidates[0].distance >= Shape.matchCutoff else {
            throw ConfigError.invalid("A gesture outside the cutoff must report its two closest rules and their distances.")
        }

        let tie = recognize(up, [tilted, down, exact])
        guard tie.match == .ambiguous, tie.failure == .ambiguous,
              tie.candidates.map(\.ruleID) == [exact.id, tilted.id],
              tie.candidates.map(\.distance) == [0, expectedDistance(to: tilted)],
              (0..<Shape.ambiguityMargin).contains(tie.candidates[1].distance - tie.candidates[0].distance) else {
            throw ConfigError.invalid("An ambiguous gesture must report the close pair, in score order.")
        }

        let vee = Rule(kind: .gesture, points: Shape.preset(.v), shapeName: ShapePreset.v.rawValue, action: .copy)
        guard recognize(vee.points, [vee]).candidates.map(\.ruleID) == [vee.id] else {
            throw ConfigError.invalid("Both directions of a V must report the same candidate only once.")
        }
        let empty = recognize(up, [])
        let short = recognize([StrokePoint(0, 0), StrokePoint(10, 0)], [exact])
        guard empty.failure == .noTemplates, short.failure == .invalidStroke,
              empty.candidates.isEmpty, short.candidates.isEmpty else {
            throw ConfigError.invalid("A stroke without scores must describe why its candidate list is empty.")
        }
    }
}
