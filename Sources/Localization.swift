import Combine
import Foundation

enum InterfaceLanguage: String, CaseIterable {
    case system, chinese, english
    static let preferenceKey = "QingSweep.interfaceLanguage"
    var locale: Locale { Locale(identifier: resolved == .chinese ? "zh_Hans" : "en") }
    var resolved: InterfaceLanguage {
        guard self == .system else { return self }
        return Self.resolve(preferredLanguages: Locale.preferredLanguages)
    }
    static func resolve(preferredLanguages: [String]) -> InterfaceLanguage {
        preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? .chinese : .english
    }
    static var current: InterfaceLanguage {
        (InterfaceLanguage(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "system") ?? .system).resolved
    }
    var title: String {
        switch self { case .system: return L("跟随系统"); case .chinese: return "简体中文"; case .english: return "English" }
    }
}

@MainActor final class LanguageSettings: ObservableObject {
    static let shared = LanguageSettings()
    @Published var choice: InterfaceLanguage {
        didSet { defaults.set(choice.rawValue, forKey: InterfaceLanguage.preferenceKey) }
    }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        choice = InterfaceLanguage(rawValue: defaults.string(forKey: InterfaceLanguage.preferenceKey) ?? "system") ?? .system
    }
    var locale: Locale { choice.locale }
}

/// Localizes application-owned display text while keeping persisted identifiers unchanged.
/// File names, paths, user input and application identifiers use verbatim presentation.
final class TranslationCatalog: @unchecked Sendable {
    struct Entry: Codable { let source: String; let english: String }
    private struct Pattern {
        let expression: NSRegularExpression
        let embedded: NSRegularExpression?
        let initial: Character?
        let english: String
        let positions: [Int]
        let weight: Int
    }
    private let exact: [String: String]
    private let patterns: [Pattern]
    private let fragments: [(source: String, english: String)]
    private let cache = NSCache<NSString, NSString>()
    let entries: [Entry]

    init(entries: [Entry]) {
        self.entries = entries
        exact = Dictionary(entries.map { ($0.source, $0.english) }, uniquingKeysWith: { first, _ in first })
        let placeholder = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)
        patterns = entries.compactMap { entry in
            let value = entry.source as NSString
            let markers = placeholder.matches(in: entry.source, range: NSRange(location: 0, length: value.length))
            guard !markers.isEmpty else { return nil }
            var cursor = 0, expression = "^", positions: [Int] = [], weight = 0
            let numericOnly = entry.source.range(of: #"^\{[0-9]+\}\s*/\s*\{[0-9]+\}\s*项"#, options: .regularExpression) != nil
            for marker in markers {
                let literal = value.substring(with: NSRange(location: cursor, length: marker.range.location - cursor))
                expression += NSRegularExpression.escapedPattern(for: literal); weight += literal.count
                let following = value.substring(from: marker.range.location + marker.range.length)
                let number = numericOnly || following.range(of: #"^\s*(项|个|次|组|处|份|天|秒|分|时|%)"#, options: .regularExpression) != nil
                expression += number ? "([0-9][0-9, .]*)" : "(.*?)"
                positions.append(Int(value.substring(with: marker.range(at: 1)))!)
                cursor = marker.range.location + marker.range.length
            }
            let tail = value.substring(from: cursor)
            expression += NSRegularExpression.escapedPattern(for: tail) + "$"; weight += tail.count
            guard let regex = try? NSRegularExpression(pattern: expression, options: [.dotMatchesLineSeparators]) else { return nil }
            let canEmbed = weight >= 4 && !entry.source.hasPrefix("{") && !entry.source.hasSuffix("}")
            let embedded = canEmbed ? try? NSRegularExpression(pattern: String(expression.dropFirst().dropLast()), options: [.dotMatchesLineSeparators]) : nil
            return Pattern(expression: regex, embedded: embedded, initial: entry.source.first, english: entry.english, positions: positions, weight: weight)
        }.sorted { $0.weight > $1.weight }
        fragments = entries.filter { !$0.source.contains("{0}") && $0.source.count >= 2 && !$0.source.contains("\n") }
            .map { ($0.source, $0.english) }.sorted { $0.source.count > $1.source.count }
        cache.countLimit = 2048; cache.totalCostLimit = 2_000_000
    }
    convenience init(url: URL) throws {
        try self.init(entries: JSONDecoder().decode([Entry].self, from: Data(contentsOf: url)))
    }

    func text(_ source: String, language: InterfaceLanguage) -> String {
        guard language.resolved == .english, source.range(of: #"[\p{Han}]"#, options: .regularExpression) != nil else { return source }
        if let cached = cache.object(forKey: source as NSString) { return cached as String }
        let result = render(source)
        if source.utf8.count < 20_000 { cache.setObject(result as NSString, forKey: source as NSString, cost: result.utf8.count) }
        return result
    }

    /// A per-file error prefix is a file name, even when it equals an interface label.
    func error(_ source: String, language: InterfaceLanguage) -> String {
        guard language.resolved == .english else { return source }
        return source.components(separatedBy: "\n").map { line in
            if exact[line] != nil { return text(line, language: language) }
            guard let separator = line.range(of: "：") else { return text(line, language: language) }
            let label = String(line[..<separator.upperBound])
            if exact[label] != nil { return text(line, language: language) }
            return String(line[..<separator.lowerBound]) + ": " + text(String(line[separator.upperBound...]), language: language)
        }.joined(separator: "\n")
    }
    func sourceTitles(matchingEnglish query: String, language: InterfaceLanguage) -> [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard language.resolved == .english, query.count >= 2 else { return [] }
        return Array(Set(entries.filter {
            $0.source.count <= 30 && $0.english.count <= 45 && !$0.source.contains("{0}") &&
            $0.source.rangeOfCharacter(from: CharacterSet(charactersIn: "。，；：！？\n")) == nil &&
            $0.english.localizedCaseInsensitiveContains(query)
        }.map(\.source)).sorted().prefix(64))
    }

    private func render(_ source: String) -> String {
        if let translated = exact[source] { return translated }
        let original = source as NSString
        for pattern in patterns {
            guard let match = pattern.expression.firstMatch(in: source, range: NSRange(location: 0, length: original.length)) else { continue }
            return format(pattern, match: match, original: original)
        }
        // Legacy reports compose descriptions from several stored phrases. Translate only
        // known application phrases; absolute paths and URLs remain opaque.
        let protected = try! NSRegularExpression(pattern: #"https?://\S+|(?m)(?:^|(?<=[\t ]))(?:file://)?/[^\s/][^\n]*"#)
        let ranges = protected.matches(in: source, range: NSRange(location: 0, length: original.length)).map(\.range)
        var result = "", index = source.startIndex
        while index < source.endIndex {
            let offset = index.utf16Offset(in: source)
            if let range = ranges.first(where: { $0.location == offset }), let swiftRange = Range(range, in: source) {
                result += source[swiftRange]; index = swiftRange.upperBound; continue
            }
            if let match = patterns.lazy.filter({ $0.initial == source[index] && $0.embedded != nil }).compactMap({ pattern -> (Pattern, NSTextCheckingResult)? in
                guard let match = pattern.embedded?.firstMatch(in: source, options: [.anchored], range: NSRange(location: offset, length: original.length - offset)), match.range.length > 0 else { return nil }
                return (pattern, match)
            }).first, let range = Range(match.1.range, in: source) {
                result += format(match.0, match: match.1, original: original); index = range.upperBound; continue
            }
            if let fragment = fragments.first(where: { candidate in
                guard source[index...].hasPrefix(candidate.source) else { return false }
                // A suffix such as " 扫描" must not consume the start of " 扫描完成".
                if candidate.source.first?.isWhitespace == true, candidate.source.last?.isLetter == true {
                    let end = source.index(index, offsetBy: candidate.source.count)
                    if end < source.endIndex, source[end].isLetter || source[end].isNumber { return false }
                }
                return true
            }) {
                result += fragment.english; index = source.index(index, offsetBy: fragment.source.count)
            } else { result.append(source[index]); index = source.index(after: index) }
        }
        return result
    }
    private func format(_ pattern: Pattern, match: NSTextCheckingResult, original: NSString) -> String {
        var result = pattern.english
        for (group, position) in pattern.positions.enumerated() where original.substring(with: match.range(at: group + 1)) == "1" {
            for (plural, singular) in Self.countWords { result = result.replacingOccurrences(of: "{\(position)} " + plural, with: "{\(position)} " + singular) }
        }
        let marker = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#), template = result as NSString
        for token in marker.matches(in: result, range: NSRange(location: 0, length: template.length)).reversed() {
            let position = Int(template.substring(with: token.range(at: 1)))!
            guard let group = pattern.positions.firstIndex(of: position), let range = Range(token.range, in: result) else { continue }
            result.replaceSubrange(range, with: original.substring(with: match.range(at: group + 1)))
        }
        return result
    }
    private static let countWords = [("items", "item"), ("files", "file"), ("locations", "location"), ("batches", "batch"), ("groups", "group"), ("copies", "copy"), ("categories", "category"), ("results", "result")]
}

enum Localization {
    static let catalog: TranslationCatalog = {
        guard let url = Bundle.main.url(forResource: "Translations", withExtension: "json"), let value = try? TranslationCatalog(url: url) else { return TranslationCatalog(entries: []) }
        return value
    }()
    static func error(_ source: String) -> String { catalog.error(source, language: .current) }
}

func L(_ source: String) -> String { Localization.catalog.text(source, language: .current) }
