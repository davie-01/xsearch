import Foundation

/// One "search within / exclude from these results" step (full window). A step is query text
/// added to the input, so the engine answers it like any typed query and the result limit
/// applies after it, not before.
public struct Refinement: Equatable, Sendable {
    public var term: String
    public var exclude: Bool

    public init(term: String, exclude: Bool) {
        self.term = term
        self.exclude = exclude
    }

    /// Every word of the term, quoted so operators, wildcards and filter prefixes in it stay
    /// literal. Within: all words must appear; exclude: a result with any of them goes.
    public var clause: String {
        term.split(whereSeparator: \.isWhitespace).map { word in
            (exclude ? "-" : "") + "\"" + word.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }.joined(separator: " ")
    }

    /// Whether the step can be written with this syntax: exclusion needs the operators.
    public func isUsable(_ syntax: QuerySyntax) -> Bool {
        !clause.isEmpty && (!exclude || syntax.operators)
    }

    /// The input with the steps ANDed on. An input with `|` is grouped first, since AND binds
    /// tighter than OR (`a | b x` is `a | (b x)`); the parentheses stand alone so filters inside
    /// them are still read as filters.
    public static func apply(_ steps: [Refinement], to input: String, syntax: QuerySyntax) -> String {
        let clauses = steps.filter { $0.isUsable(syntax) }.map(\.clause)
        guard !clauses.isEmpty else { return input }
        let base = input.trimmingCharacters(in: .whitespaces)
        let grouped = syntax.operators && base.contains("|") ? "( " + base + " )" : base
        return ([grouped] + clauses).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
