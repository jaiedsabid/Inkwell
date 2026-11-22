import Foundation
import SwiftUI

/// How the user wants their writing to sound.
enum Tone: String, CaseIterable, Codable, Identifiable {
    case natural, casual, professional, friendly, confident, academic, concise

    var id: String { rawValue }

    var label: String {
        switch self {
        case .natural: "Natural"
        case .casual: "Casual"
        case .professional: "Professional"
        case .friendly: "Friendly"
        case .confident: "Confident"
        case .academic: "Academic"
        case .concise: "Concise"
        }
    }

    var symbol: String {
        switch self {
        case .natural: "leaf"
        case .casual: "cup.and.saucer"
        case .professional: "briefcase"
        case .friendly: "face.smiling"
        case .confident: "bolt"
        case .academic: "graduationcap"
        case .concise: "scissors"
        }
    }

    var guidance: String {
        switch self {
        case .natural: "Keep the writer's own voice. Only fix what is wrong or unclear."
        case .casual: "Relaxed and conversational, like a message to a coworker you know well. Contractions are fine."
        case .professional: "Clear, polite and businesslike. No slang. Suitable for clients and managers."
        case .friendly: "Warm, positive and approachable, without being over the top."
        case .confident: "Direct and assured. Remove hedging like 'I think', 'just', 'maybe' where it weakens the message."
        case .academic: "Formal, precise and objective. Avoid contractions and casual phrasing."
        case .concise: "As short as possible while keeping the meaning. Cut filler words."
        }
    }
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

enum IssueKind: String, Codable, CaseIterable {
    case spelling, grammar, clarity, tone

    var label: String {
        switch self {
        case .spelling: "Spelling"
        case .grammar: "Grammar"
        case .clarity: "Clarity"
        case .tone: "Tone"
        }
    }

    var color: NSColor {
        switch self {
        case .spelling, .grammar: Theme.red
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
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
    }
}
