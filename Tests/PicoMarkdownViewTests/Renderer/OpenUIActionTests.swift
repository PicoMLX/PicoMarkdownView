import Foundation
import Testing
@testable import PicoMarkdownView

@Suite("OpenUI semantic action values")
struct OpenUIActionTests {
    @Test("Action decoding preserves nested JSON types and form values")
    func typedActionRoundTrip() throws {
        let json = #"{"type":"continue_conversation","params":{"reportID":42,"enabled":true,"context":{"tags":["macOS",null],"ratio":0.75}},"humanFriendlyMessage":"Explain this report","formState":{"trip":{"traveler":{"value":"Ada 🧭"},"email":{"value":"ada@example.com"}}},"formName":"trip"}"#
        let event = try JSONDecoder().decode(PicoOpenUIActionEvent.self, from: Data(json.utf8))
        #expect(event.type == "continue_conversation")
        #expect(event.params["reportID"] == .number(42))
        #expect(event.params["enabled"] == .bool(true))
        #expect(event.params["context"] == .object([
            "tags": .array([.string("macOS"), .null]), "ratio": .number(0.75)
        ]))
        #expect(event.humanFriendlyMessage == "Explain this report")
        #expect(event.formState?["trip"] == .object([
            "traveler": .object(["value": .string("Ada 🧭")]),
            "email": .object(["value": .string("ada@example.com")])
        ]))
        #expect(event.formName == "trip")
        let encoded = try JSONEncoder().encode(event)
        #expect(try JSONDecoder().decode(PicoOpenUIActionEvent.self, from: encoded) == event)
    }

    @Test("An action outside a form does not synthesize form state")
    func actionWithoutForm() throws {
        let json = #"{"type":"open_url","params":{"url":"https://example.com"},"humanFriendlyMessage":"Open documentation"}"#
        let event = try JSONDecoder().decode(PicoOpenUIActionEvent.self, from: Data(json.utf8))
        #expect(event.formName == nil)
        #expect(event.formState == nil)
        #expect(event.params["url"] == .string("https://example.com"))
    }
}
