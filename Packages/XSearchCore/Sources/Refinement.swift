import Foundation

/// One "在结果中" step of the full window: words the results must all contain, may contain any
/// of, or must not contain. A step is query text added to the input, so the engine answers it
/// like any typed query and the result limit applies after it, not before.
public struct Refinement: Equatable, Sendable {
    public enum Kind: String, Sendable { case all, any, none }

    public var term: String
    public var kind: Kind
    /// The whole term as one unit, appearing exactly as typed (spaces included).
    public var exact: Bool

    public init(term: String, kind: Kind, exact: Bool = false) {
        self.term = term
        self.kind = kind
        self.exact = exact
    }

    /// The step as query text: all → `a b`, any → `(a | b)`, none → `-a -b`.
    public var clause: String {
        let w = Self.words(term, exact: exact)
        switch kind {
        case .all: return w.joined(separator: " ")
        case .any: return w.count > 1 ? "(" + w.joined(separator: " | ") + ")" : w.first ?? ""
        case .none: return w.map { "-" + $0 }.joined(separator: " ")
        }
    }

    /// Whether the step can be written with this syntax: OR and NOT are operators.
    public func isUsable(_ syntax: QuerySyntax) -> Bool {
        !clause.isEmpty && (kind == .all || syntax.operators)
    }

    /// The input with the steps ANDed on (unusable ones left out, not searched for literally).
    public static func apply(_ steps: [Refinement], to input: String, syntax: QuerySyntax) -> String {
        and(input, steps.filter { $0.isUsable(syntax) }.map(\.clause).joined(separator: " "), syntax: syntax)
    }

    /// `extra` ANDed onto `input`. An input with `|` is grouped first, since AND binds tighter
    /// than OR (`a | b x` is `a | (b x)`); the parentheses stand alone so filters inside them are
    /// still read as filters.
    public static func and(_ input: String, _ extra: String, syntax: QuerySyntax) -> String {
        let base = input.trimmingCharacters(in: .whitespaces)
        guard !extra.isEmpty else { return input }
        guard !base.isEmpty else { return extra }
        return (syntax.operators && base.contains("|") ? "( " + base + " )" : base) + " " + extra
    }

    /// A term's words: plain words stay readable, words the parser would read as syntax are
    /// quoted, and quoted runs pass through. `exact` takes the whole term as one phrase.
    static func words(_ term: String, exact: Bool) -> [String] {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        if exact { return [quoted(trimmed.replacingOccurrences(of: "\"", with: ""))] }
        return ContentQuery.rawTokens(trimmed).map { token in
            if token.hasPrefix("\""), token.hasSuffix("\""), token.count >= 2 { return token }
            let special = token.hasPrefix("-") || token.contains(":") || token.contains(where: { "|()*?\"\\~".contains($0) })
            return special ? quoted(token) : token
        }
    }

    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
