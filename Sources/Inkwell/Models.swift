import Foundation
import SwiftUI

/// How the user wants their writing to sound: one of the built-in tones or one the user made.
/// Stored as its id string, so settings saved before custom tones existed still load.
struct Tone: Hashable, Codable, Identifiable {
    let id: String

    init(id: String) { self.id = id }
    init(from decoder: Decoder) throws { id = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(id)
    }

    static let natural = Tone(id: "natural")
    static let casual = Tone(id: "casual")
    static let professional = Tone(id: "professional")
    static let friendly = Tone(id: "friendly")
    static let confident = Tone(id: "confident")
    static let academic = Tone(id: "academic")
    static let concise = Tone(id: "concise")

    static let builtIns: [Tone] = [.natural, .casual, .professional, .friendly, .confident, .academic, .concise]
    /// Built-in tones followed by the user's own.
    static var allCases: [Tone] { builtIns + ToneRegistry.custom.map { Tone(id: $0.id) } }

    var custom: CustomTone? { ToneRegistry.custom.first { $0.id == id } }
    var isCustom: Bool { id.hasPrefix("custom-") }
    /// False for a custom tone that was deleted.
    var exists: Bool { !isCustom || custom != nil }

    var label: String {
        switch id {
        case "natural": "Natural"
        case "casual": "Casual"
        case "professional": "Professional"
        case "friendly": "Friendly"
        case "confident": "Confident"
        case "academic": "Academic"
        case "concise": "Concise"
        default: custom?.name ?? "Natural"
        }
    }

    var symbol: String {
        switch id {
        case "natural": "leaf"
        case "casual": "cup.and.saucer"
        case "professional": "briefcase"
        case "friendly": "face.smiling"
        case "confident": "bolt"
        case "academic": "graduationcap"
        case "concise": "scissors"
        default: custom?.symbol ?? "leaf"
        }
    }

    var guidance: String {
        switch id {
        case "natural": "Keep the writer's own voice. Only fix what is wrong or unclear."
        case "casual": "Relaxed and conversational, like a message to a coworker you know well. Contractions are fine."
        case "professional": "Clear, polite and businesslike. No slang. Suitable for clients and managers."
        case "friendly": "Warm, positive and approachable, without being over the top."
        case "confident": "Direct and assured. Remove hedging like 'I think', 'just', 'maybe' where it weakens the message."
        case "academic": "Formal, precise and objective. Avoid contractions and casual phrasing."
        case "concise": "As short as possible while keeping the meaning. Cut filler words."
        default: custom.map { $0.guidance.isEmpty ? "Sound \($0.name.lowercased())." : $0.guidance } ?? Tone.natural.guidance
        }
    }
}

/// A tone the user defined: a name, an icon and a description of how it should sound.
struct CustomTone: Codable, Identifiable, Equatable {
    var id = "custom-" + UUID().uuidString
    var name: String
    var guidance: String
    var symbol: String = "paintbrush"

    static let symbols = ["paintbrush", "heart", "star", "flame", "sparkles", "megaphone", "hand.wave", "lightbulb",
                          "person.2", "crown", "theatermasks", "music.note", "wand.and.stars", "globe", "book", "pencil.and.scribble"]
}

/// Custom tones, readable from anywhere (kept in sync by AppSettings).
enum ToneRegistry {
    nonisolated(unsafe) static var custom: [CustomTone] = []
}

/// How many suggestions to show.
enum Strictness: String, CaseIterable, Codable, Identifiable {
    case relaxed, standard, picky
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var detail: String {
        switch self {
        case .relaxed: "Only clear mistakes"
        case .standard: "Mistakes and unclear sentences"
        case .picky: "Also style, word choice and punctuation"
        }
    }
    var guidance: String {
        switch self {
        case .relaxed: "Only flag definite spelling and grammar errors. Never flag style or word choice. Do not suggest sentence rewrites unless the sentence is broken."
        case .standard: "Flag spelling and grammar errors, and suggest a rewrite for sentences that are confusing, awkward or hard to read."
        case .picky: "Flag spelling and grammar errors, punctuation, weak or repeated word choice, passive voice and wordiness, and suggest rewrites for sentences that could be clearly better."
        }
    }
}

struct WritingLanguage: Hashable, Identifiable {
    let code: String        // BCP-47, sent to the AI
    let name: String
    let spellCode: String   // NSSpellChecker language
    var id: String { code }

    static let all: [WritingLanguage] = [
        .init(code: "en-US", name: "English (US)", spellCode: "en"),
        .init(code: "en-GB", name: "English (UK)", spellCode: "en_GB"),
        .init(code: "en-AU", name: "English (Australia)", spellCode: "en_AU"),
        .init(code: "en-CA", name: "English (Canada)", spellCode: "en_CA"),
        .init(code: "en-IN", name: "English (India)", spellCode: "en_IN"),
        .init(code: "es", name: "Spanish", spellCode: "es"),
        .init(code: "fr", name: "French", spellCode: "fr"),
        .init(code: "de", name: "German", spellCode: "de"),
        .init(code: "it", name: "Italian", spellCode: "it"),
        .init(code: "pt-BR", name: "Portuguese (Brazil)", spellCode: "pt_BR"),
        .init(code: "pt-PT", name: "Portuguese (Portugal)", spellCode: "pt_PT"),
        .init(code: "nl", name: "Dutch", spellCode: "nl"),
        .init(code: "sv", name: "Swedish", spellCode: "sv"),
        .init(code: "da", name: "Danish", spellCode: "da"),
        .init(code: "nb", name: "Norwegian", spellCode: "nb"),
        .init(code: "fi", name: "Finnish", spellCode: "fi"),
        .init(code: "pl", name: "Polish", spellCode: "pl"),
        .init(code: "tr", name: "Turkish", spellCode: "tr"),
        .init(code: "ru", name: "Russian", spellCode: "ru"),
    ]

    static func find(_ code: String) -> WritingLanguage { all.first { $0.code == code } ?? all[0] }
}

enum IssueKind: String, Codable, CaseIterable, Identifiable {
    case spelling, grammar, punctuation, capitalization, clarity, tone

    var id: String { rawValue }

    var label: String {
        switch self {
        case .spelling: "Spelling"
        case .grammar: "Grammar"
        case .punctuation: "Punctuation"
        case .capitalization: "Capitalization"
        case .clarity: "Clarity"
        case .tone: "Tone"
        }
    }

    var symbol: String {
        switch self {
        case .spelling: "textformat.abc"
        case .grammar: "text.badge.checkmark"
        case .punctuation: "ellipsis.curlybraces"
        case .capitalization: "textformat.size"
        case .clarity: "text.line.first.and.arrowtriangle.forward"
        case .tone: "theatermasks"
        }
    }

    /// Plain description, for settings.
    var detail: String {
        switch self {
        case .spelling: "Misspelled words"
        case .grammar: "Agreement, tense, articles and word forms"
        case .punctuation: "Missing full stops, question marks and commas"
        case .capitalization: "Capital letters at the start of sentences and for names"
        case .clarity: "Sentences that could be clearer or shorter"
        case .tone: "Sentences that don't fit your tone"
        }
    }

    var color: NSColor {
        switch self {
        case .spelling, .grammar, .punctuation, .capitalization: Theme.red
        case .clarity: Theme.blue
        case .tone: Theme.purple
        }
    }

    /// Word-level issues get a wavy line, sentence-level ones a straight or dashed line.
    var isSentenceLevel: Bool { self == .clarity || self == .tone }
}

/// One suggestion, located in the text of the field being checked (UTF-16 range).
struct Issue: Identifiable, Equatable {
    var range: NSRange
    var kind: IssueKind
    var original: String
    var replacement: String
    var explanation: String

    var id: String { "\(range.location):\(range.length):\(kind.rawValue):\(replacement)" }

    /// Key used to remember that the user dismissed this suggestion.
    var dismissKey: String { "\(original.lowercased())→\(replacement.lowercased())" }
}

enum Theme {
    static let red = NSColor(srgbRed: 0.94, green: 0.27, blue: 0.27, alpha: 1)
    static let blue = NSColor(srgbRed: 0.23, green: 0.51, blue: 0.96, alpha: 1)
    static let purple = NSColor(srgbRed: 0.62, green: 0.35, blue: 0.95, alpha: 1)
    static let accent = Color(nsColor: NSColor(srgbRed: 0.36, green: 0.36, blue: 0.95, alpha: 1))
}

import SwiftUI

/// Accent-filled button that stays colored in panels that never become key (system prominent buttons turn gray there).
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .fixedSize()
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .fixedSize()
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
    }
}
