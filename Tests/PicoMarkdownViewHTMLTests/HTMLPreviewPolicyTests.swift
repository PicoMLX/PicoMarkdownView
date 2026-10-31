#if os(macOS)
import Foundation
import Testing
@testable import PicoMarkdownViewHTML

@Suite("Static HTML preview policy")
struct HTMLPreviewPolicyTests {
    @Test("Static reports retain HTML5 containers, CSS, tables and Unicode")
    func preparesReport() throws {
        let document = try HTMLPreviewPolicy.prepare(source: """
        <!doctype html><html><head><meta charset="windows-1252">
        <style>.card { display: grid; gap: 12px; background: linear-gradient(red, blue); }</style>
        </head><body class="report"><section class="card"><h3>Résumé 🧭</h3>
        <p>こんにちは <strong>world</strong><br>Next line</p>
        <table><tr><th scope="col">Item</th><th>Total</th></tr><tr><td colspan="2">42</td></tr></table>
        </section></body></html>
        """)
        #expect(document.html.contains("<section class=\"card\">"))
        #expect(document.html.contains("<body class=\"report\""))
        #expect(document.html.contains("display: grid"))
        #expect(document.html.contains("linear-gradient(red, blue)"))
        #expect(document.html.contains("colspan=\"2\""))
        #expect(document.plainText.contains("Résumé 🧭"))
        #expect(document.plainText.contains("こんにちは world"))
        #expect(document.plainText.contains("42"))
        #expect(!document.plainText.contains("display: grid"))
        #expect(!document.html.contains("windows-1252"))
    }

    @Test("Author navigation, active elements and event attributes are removed")
    func removesActiveContent() throws {
        let document = try HTMLPreviewPolicy.prepare(source: """
        <html><head><meta http-equiv="refresh" content="0;url=https://example.invalid">
        <base href="https://example.invalid"><link rel="stylesheet" href="https://example.invalid/a.css"></head>
        <body onload="alert(1)"><div onclick="alert(2)" contenteditable="true" tabindex="0">Report
        <a href="javascript:alert(3)" target="_blank" ping="https://example.invalid" download>Readable link</a>
        <script src="https://example.invalid/script.js">alert(4)</script>
        <iframe srcdoc="<script>alert(5)</script>">frame</iframe>
        <object data="file:///private/etc/passwd">object</object><embed src="https://example.invalid">
        <form action="https://example.invalid"><input value="private"><button>Submit</button><textarea>edit</textarea></form>
        <svg onload="alert(6)"><text>foreign</text></svg><math><mi>x</mi></math>
        </div></body></html>
        """)
        try expectInert(document)
        #expect(document.plainText.contains("Report"))
        #expect(document.plainText.contains("Readable link"))
        #expect(!document.html.contains("example.invalid"))
        #expect(!document.plainText.contains("alert("))
        #expect(!document.plainText.contains("Submit"))
        #expect(!document.html.contains("contenteditable="))
        #expect(!document.html.contains("tabindex="))
    }

    @Test("Malformed and foreign-content payloads are inert or rejected", arguments: [
        "<svg><style><a id='</style><img src=x onerror=alert(1)>'>x</a></style></svg><p>Safe report</p>",
        "<noscript><p title='</noscript><img src=x onerror=alert(1)>'>x</p></noscript><p>Safe report</p>",
        "<math><mtext><table><mglyph><style><!--</style><img title='--><img src=x onerror=alert(1)>'></table></mtext></math><p>Safe report</p>",
        "<div><ScRiPt src='data:text/javascript,alert(1)'>x</sCrIpT><p ONMOUSEOVER='alert(2)'>Safe report",
        "<iframe srcdoc='&lt;script&gt;alert(1)&lt;/script&gt;'></iframe><p title='&quot; onclick=&quot;alert(2)'>Safe report</p>"
    ])
    func repairsOrRejectsAdversarialMarkup(source: String) throws {
        do {
            let document = try HTMLPreviewPolicy.prepare(source: source)
            try expectInert(document)
        } catch let error as HTMLPreviewPolicyError {
            #expect(error == .invalidHTML || error == .emptyContent)
        }
    }

    @Test("The app owns the first CSP and the unique measurement root")
    func ownsDocumentShell() throws {
        let document = try HTMLPreviewPolicy.prepare(source: """
        <html><head><meta http-equiv="Content-Security-Policy" content="default-src *"></head>
        <body id="pico-html-content" style="margin:50px;overflow:auto"><div id="pico-html-content">Report</div></body></html>
        """)
        #expect(document.html.contains("<head><meta http-equiv=\"Content-Security-Policy\""))
        #expect(document.html.components(separatedBy: "http-equiv=\"Content-Security-Policy\"").count == 2)
        #expect(document.html.components(separatedBy: "id=\"pico-html-content\"").count == 2)
        #expect(!document.html.contains("default-src *"))
        for directive in ["default-src 'none'", "script-src 'none'", "img-src 'none'", "connect-src 'none'", "form-action 'none'", "base-uri 'none'"] {
            #expect(HTMLPreviewPolicy.contentSecurityPolicy.contains(directive))
        }
        #expect(HTMLPreviewPolicy.contentSecurityPolicy.contains("style-src 'unsafe-inline'"))
        #expect(document.html.contains("display:flow-root!important;width:100%!important"))
        #expect(document.html.contains("margin:50px;overflow:auto;margin:0!important;overflow:hidden!important"))
    }

    @Test("Images have a visible escaped alt fallback and never retain resources")
    func omitsImages() throws {
        let document = try HTMLPreviewPolicy.prepare(source: """
        <p>Report<img src="https://example.invalid/image.png" srcset="file:///secret 2x" alt="Chart &amp; totals">
        <img src="data:image/svg+xml,&lt;svg onload='alert(1)'&gt;"></p>
        """)
        #expect(document.plainText.contains("[Image: Chart & totals]"))
        #expect(document.plainText.contains("[Image omitted]"))
        #expect(!document.html.contains("<img"))
        #expect(!document.html.contains("src="))
        #expect(!document.html.contains("example.invalid"))
        #expect(!document.html.contains("data:image"))
    }

    @Test("External DTDs cannot load local entities, and internal declarations are refused")
    func doesNotResolveEntities() throws {
        let marker = "pico-html-entity-" + UUID().uuidString
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dtd")
        try "<!ENTITY leak '\(marker)'>".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let document = try HTMLPreviewPolicy.prepare(source: "<!DOCTYPE html SYSTEM '\(file.absoluteString)'><html><body><p>Report &leak;</p></body></html>")
        #expect(!document.html.contains(marker))
        #expect(!document.html.contains(file.absoluteString))
        #expect(document.plainText.contains("Report"))
        #expect(throws: HTMLPreviewPolicyError.unsupportedDeclaration) {
            try HTMLPreviewPolicy.prepare(source: "<!DOCTYPE html [<!ENTITY secret 'expanded'>]><p>&secret;</p>")
        }
        #expect(throws: HTMLPreviewPolicyError.unsupportedDeclaration) {
            try HTMLPreviewPolicy.prepare(source: "<p>Report\0</p>")
        }
    }

    @Test("Source bytes, node count and nesting are bounded before presentation")
    func rejectsUnboundedDocuments() throws {
        #expect(throws: HTMLPreviewPolicyError.sourceTooLarge) {
            try HTMLPreviewPolicy.prepare(source: String(repeating: "🧭", count: HTMLPreviewPolicy.maximumSourceBytes / 4 + 1))
        }
        #expect(throws: HTMLPreviewPolicyError.documentTooComplex) {
            try HTMLPreviewPolicy.prepare(source: String(repeating: "<span>x</span>", count: HTMLPreviewPolicy.maximumNodeCount))
        }
        #expect(throws: HTMLPreviewPolicyError.documentTooComplex) {
            try HTMLPreviewPolicy.prepare(source: String(repeating: "<div>", count: HTMLPreviewPolicy.maximumDepth + 1) + "Report" + String(repeating: "</div>", count: HTMLPreviewPolicy.maximumDepth + 1))
        }
        #expect(HTMLPreviewPolicy.minimumHeight == 1)
        #expect(HTMLPreviewPolicy.maximumHeight == 4_096)
    }

    @Test("Style parameters cannot break the generated document shell")
    func rejectsShellInjectionThroughTheme() throws {
        var style = HTMLPreviewStyle.default
        style.fontFamily = "</style><script>alert(1)</script>"
        style.foregroundCSS = "red;} </style><iframe src='https://example.invalid'>"
        style.backgroundCSS = "url(file:///secret)"
        style.fontSize = .nan
        let document = try HTMLPreviewPolicy.prepare(source: "<p>Report</p>", style: style)
        try expectInert(document)
        #expect(!document.html.contains("example.invalid"))
        #expect(!document.html.contains("file:///secret"))
        #expect(!document.html.contains("nanpx"))
    }

    private func expectInert(_ document: HTMLPreviewDocument) throws {
        let parsed = try XMLDocument(xmlString: document.html, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
        for name in ["script", "iframe", "object", "embed", "form", "input", "textarea", "select", "button", "base", "link", "svg", "math"] {
            #expect(try parsed.nodes(forXPath: "//*[local-name()='\(name)']").isEmpty, "Unexpected active element: \(name)")
        }
        for attribute in ["href", "src", "srcset", "srcdoc", "action", "formaction", "target", "download", "ping", "onload", "onclick", "onerror", "onmouseover"] {
            #expect(try parsed.nodes(forXPath: "//*[@\(attribute)]").isEmpty, "Unexpected resource or event attribute: \(attribute)")
        }
    }
}
#endif
