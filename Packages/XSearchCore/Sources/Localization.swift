import Foundation

/// UI language (设置 › 通用 › 语言). Chinese is the source language: every UI string is written
/// in Chinese and looked up in the English table (Strings+en.swift) when English is in use.
public enum UILanguage: String, CaseIterable, Sendable {
    case system, zh, en

    /// The choice is the app's AppleLanguages override, so system-drawn UI (open panels, Sparkle,
    /// standard menu items) follows it too. Applies from the next launch.
    public static var chosen: UILanguage {
        get {
            switch UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String] {
            case let list? where list.first?.hasPrefix("en") == true: .en
            case let list? where list.first?.hasPrefix("zh") == true: .zh
            default: .system
            }
        }
        set {
            switch newValue {
            case .system: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            case .zh: UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
            case .en: UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
            }
        }
    }
}

public enum Loc {
    /// Decided once at launch: the bundle's preferred localization (the app ships en and
    /// zh-Hans). Without a bundle (tests, tools) the UI stays Chinese. XS_LANG overrides (dev).
    public static let isEnglish: Bool = {
        if let lang = ProcessInfo.processInfo.environment["XS_LANG"] { return lang.hasPrefix("en") }
        // Only the app ships both; another process (tests, the XPC service) has neither.
        guard Set(Bundle.main.localizations).isSuperset(of: ["en", "zh-Hans"]) else { return false }
        return Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true
    }()

    /// The locale dates and numbers are formatted in.
    public static var locale: Locale { Locale(identifier: isEnglish ? "en_US" : "zh_CN") }

    /// Messages that come from the index, the extraction worker or the engine (diagnosis,
    /// warnings, part names). They are stored and passed around in Chinese; this translates
    /// them for display, including the ones with numbers or names in them.
    public static func display(_ message: String) -> String {
        isEnglish ? english(message) : message
    }

    static func english(_ message: String) -> String {
        if let s = englishStrings[message] { return s }
        for (pattern, template) in englishPatterns {
            guard let m = pattern.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)) else { continue }
            var out = template
            for i in stride(from: m.numberOfRanges - 1, through: 1, by: -1) {
                let part = Range(m.range(at: i), in: message).map { String(message[$0]) } ?? ""
                out = out.replacingOccurrences(of: "$\(i)", with: english(part))
            }
            return out
        }
        return message
    }
}

/// The UI text for `zh` in the current language.
public func L(_ zh: String) -> String {
    Loc.isEnglish ? (englishStrings[zh] ?? zh) : zh
}

/// The UI text for `zh` where the same Chinese word reads differently in English (a group
/// heading "收藏" is "Favorites", the menu item "Favorite"): entry "收藏#group".
public func L(_ zh: String, context: String) -> String {
    Loc.isEnglish ? (englishStrings[zh + "#" + context] ?? L(zh)) : zh
}

/// `zh` with `%@` placeholders filled in order (`%1$@`, `%2$@` by position, so a translation
/// can reorder them). An English text "one‖other" has a singular form, used when the first
/// numeric argument is 1 ("%@ file‖%@ files").
public func L(_ zh: String, _ args: String...) -> String {
    fill(L(zh), args)
}

func fill(_ text: String, _ args: [String]) -> String {
    var template = text
    if let bar = template.range(of: "‖") {
        let count = args.first { !$0.isEmpty && $0.allSatisfy { $0.isNumber || $0 == "," } }
        template = count == "1" ? String(template[..<bar.lowerBound]) : String(template[bar.upperBound...])
    }
    var out = ""
    var next = 0
    var rest = Substring(template)
    while let r = rest.range(of: "%") {
        out += rest[..<r.lowerBound]
        let after = rest[r.upperBound...]
        if after.hasPrefix("@") {
            out += next < args.count ? args[next] : ""
            next += 1
            rest = after.dropFirst()
        } else if let digit = after.first?.wholeNumberValue, after.dropFirst().hasPrefix("$@") {
            out += digit - 1 < args.count ? args[digit - 1] : ""
            rest = after.dropFirst(3)
        } else {
            out += "%"
            rest = after
        }
    }
    return out + rest
}
