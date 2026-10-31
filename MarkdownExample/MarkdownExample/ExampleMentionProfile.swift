import Foundation
import PicoMarkdownView

struct ExampleMentionProfile: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let handle: String
    let role: String
    let bio: String
    let status: String
    let statusSymbol: String
    let avatarInitials: String
    let isBot: Bool

    static func profile(for tag: TagReference) -> Self? {
        guard tag.prefix == "@" else { return nil }
        switch tag.identifier {
        case "maya":
            return Self(id: "maya", name: "Maya Chen", handle: "@maya",
                        role: "Product designer",
                        bio: "Designing thoughtful tools for the Pico workspace.",
                        status: "Available", statusSymbol: "checkmark.circle.fill",
                        avatarInitials: "MC", isBot: false)
        case "pico-bot":
            return Self(id: "pico-bot", name: "Pico Bot", handle: "@pico-bot",
                        role: "Workspace assistant",
                        bio: "A friendly demo bot for summaries, quick answers, and shared context.",
                        status: "Ready to help", statusSymbol: "bolt.circle.fill",
                        avatarInitials: "PB", isBot: true)
        default:
            return nil
        }
    }
}
