import Foundation

public struct TranslationShortcut: Codable, Equatable, Hashable, Identifiable {
    public var id: String { "\(keyCode)_\(modifiers)" }
    public var label: String
    public var keyCode: Int64
    public var modifiers: String // "none", "alt", "ctrl", "cmd", "cmd+alt", "right_double"

    public init(label: String, keyCode: Int64, modifiers: String) {
        self.label = label
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let defaultShortcut = TranslationShortcut(label: "Space", keyCode: 49, modifiers: "none")

    public static let presets: [TranslationShortcut] = [
        TranslationShortcut(label: "Space", keyCode: 49, modifiers: "none"),
        TranslationShortcut(label: "Down Arrow ↓", keyCode: 125, modifiers: "none"),
        TranslationShortcut(label: "Right Double Click", keyCode: -2, modifiers: "right_double"),
        TranslationShortcut(label: "⌥ D (Option + D)", keyCode: 2, modifiers: "alt"),
        TranslationShortcut(label: "⌥ T (Option + T)", keyCode: 17, modifiers: "alt"),
        TranslationShortcut(label: "⌥ Space (Option + Space)", keyCode: 49, modifiers: "alt"),
        TranslationShortcut(label: "⌃ Space (Control + Space)", keyCode: 49, modifiers: "ctrl"),
        TranslationShortcut(label: "⌘ ⌥ D (Cmd + Option + D)", keyCode: 2, modifiers: "cmd+alt"),
        TranslationShortcut(label: "F1", keyCode: 122, modifiers: "none"),
        TranslationShortcut(label: "F2", keyCode: 120, modifiers: "none"),
        TranslationShortcut(label: "F4", keyCode: 118, modifiers: "none"),
        TranslationShortcut(label: "F5", keyCode: 96, modifiers: "none"),
        TranslationShortcut(label: "F6", keyCode: 97, modifiers: "none")
    ]
}
