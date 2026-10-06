import Foundation

/// Shortens open-data stop names to how DB writes them:
/// "Frankfurt (Main) Hauptbahnhof" → "Frankfurt (Main) Hbf", "Minden, Bahnhof" → "Minden".
public enum StationName {
    public static func tidy(_ name: String) -> String {
        var result = name
        result = replace(#"(?<=\S)[ ,/]*\b(Hauptbahnhof|Hbf\.?)(?=$|[ /(])"#, in: result, with: " Hbf")
        result = replace(#"(?<=\S)[ ,/]*\b(Bahnhof|Bhf\.?|Bf\.?)(?=$|[ /(])"#, in: result, with: " ")
        result = replace(#"\s{2,}"#, in: result, with: " ")
        result = result.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? name : result
    }

    /// Some feeds name a platform without its city, e.g. "Hauptbahnhof (oben)" for Stuttgart Hbf.
    public static func lacksCity(_ name: String) -> Bool {
        let first = name.split(whereSeparator: { $0 == " " || $0 == "(" || $0 == "," }).first.map(String.init) ?? name
        return ["Hauptbahnhof", "Hbf", "Hauptbf", "Hauptbf.", "Bahnhof", "Bf"].contains(first)
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template
        )
    }
}
