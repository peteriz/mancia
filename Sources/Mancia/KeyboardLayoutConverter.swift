/// Converts physical keys between English and Hebrew; unmapped characters survive.
enum KeyboardLayoutConverter {
    enum Language: String, Sendable {
        case english = "en", hebrew = "he"
    }

    struct Conversion: Equatable, Sendable {
        let text: String
        /// Destination layout, or nil when no conversion was needed.
        let language: Language?
    }

    // The US and Hebrew layouts, key by key.
    private static let englishKeys = "`qwertyuiop[]\\asdfghjkl;'zxcvbnm,./"
    private static let hebrewKeys = ";/׳קראטוןםפ][\\שדגכעיחלךף,זסבהנמצתץ."

    private static let englishToHebrew = Dictionary(
        uniqueKeysWithValues: zip(englishKeys, hebrewKeys))

    private static let hebrewToEnglish: [Character: Character] = {
        var mapping = Dictionary(uniqueKeysWithValues: zip(hebrewKeys, englishKeys))
        // Some apps produce an ASCII apostrophe for the Hebrew W key.
        mapping["'"] = "w"
        // Unambiguous output from Shift-modified keys in macOS's Hebrew layout.
        mapping["שׁ"] = "A"
        mapping["„"] = "D"
        mapping["וֹ"] = "U"
        mapping["״"] = "\""
        mapping["₪"] = "&"
        return mapping
    }()

    static func conversion(of text: String) -> Conversion {
        var hebrewScore = 0, englishScore = 0
        for character in text {
            if hebrewToEnglish[character] != nil {
                if englishToHebrew[character] == nil { hebrewScore += 1 }
            } else if englishToHebrew[lowercased(character)] != nil {
                englishScore += 1
            }
        }

        if hebrewScore == 0, englishScore == 0 {
            return Conversion(text: text, language: nil)
        }
        if hebrewScore > englishScore {
            return Conversion(
                text: String(text.map { hebrewToEnglish[$0] ?? $0 }),
                language: .english)
        }
        return Conversion(
            text: String(text.map { englishToHebrew[lowercased($0)] ?? $0 }),
            language: .hebrew)
    }

    private static func lowercased(_ character: Character) -> Character {
        Character(String(character).lowercased())
    }
}
