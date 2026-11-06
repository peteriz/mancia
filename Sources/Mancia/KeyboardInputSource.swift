@preconcurrency import Carbon
import Foundation

/// Selects the keyboard layout Oops converted the text into.
@MainActor
enum KeyboardInputSource {
    @discardableResult
    static func select(language: KeyboardLayoutConverter.Language) -> Bool {
        let properties: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource!,
            kTISPropertyInputSourceIsEnabled: true,
        ]
        guard let sources = TISCreateInputSourceList(properties as CFDictionary, false)?
            .takeRetainedValue() as? [TISInputSource]
        else { return false }

        let preferredIDs: [String] = switch language {
        case .english: ["com.apple.keylayout.ABC", "com.apple.keylayout.US"]
        case .hebrew: ["com.apple.keylayout.Hebrew"]
        }
        let source = sources.first { preferredIDs.contains(identifier(of: $0)) }
            ?? sources.first { languages(of: $0).contains(language.rawValue) }
        guard let source else { return false }
        return TISSelectInputSource(source) == noErr
    }

    private static func identifier(of source: TISInputSource) -> String {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return "" }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func languages(of source: TISInputSource) -> [String] {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages)
        else { return [] }
        return Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String] ?? []
    }
}
