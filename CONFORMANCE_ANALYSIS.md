# PicoMarkdownView CommonMark/GFM/KaTeX Conformance Analysis

## Executive Summary

PicoMarkdownView implements a **streaming-optimized** Markdown parser and renderer targeting CommonMark with GitHub Flavored Markdown (GFM) extensions and KaTeX math rendering. The implementation demonstrates strong **O(n) streaming performance** with incremental parsing and delta-based rendering.

---

## ✅ **SUPPORTED FEATURES**

### CommonMark Core (Well Implemented)
- **Paragraphs** with soft line breaks (converts newlines to spaces)
- **Headings** (levels 1-6) via `#` syntax
- **Emphasis**: `*italic*`, `_italic_`, `**bold**`, `__bold__`
- **Code spans**: `` `inline code` `` with multi-backtick support
- **Links**: `[text](url)` with nested emphasis support
- **Images**: `![alt](url)` (parsed as inline runs with metadata)
- **Blockquotes**: `>` with continuation lines
- **Lists**:
  - Unordered: `- `, `* `, `+ `
  - Ordered: `1. `, `2. `, etc.
  - List continuation (indentation-based)
- **Fenced code blocks**: ` ```language ` with language hints
- **Hard line breaks**: Two trailing spaces + newline → `\n` in output
- **Backslash escapes**: `\*`, `\[`, etc.

### GFM Extensions (Well Implemented)
- **Strikethrough**: `~~text~~` (streaming-aware, waits for closing delimiter)
- **Tables**: Pipe tables with alignment (`:---`, `:---:`, `---:`)
  - Header row + separator row + data rows
  - Rendered using `NSTextTable` / `NSTextTableBlock`
- **Task lists**: `- [ ]` unchecked, `- [x]` checked
- **Autolinks**: Bare URLs (`https://example.com`, `www.example.com`) converted to clickable links
  - Includes `<https://...>` angle-bracket syntax
  - Smart boundary detection (no punctuation suffix)

### KaTeX Math Support (SwiftMath Integration)
- **Inline math**: `$...$` or `\(...\)`
- **Display math**: `$$...$$` or `\[...\]`
  - Block-level: Fenced code blocks with `math` or `latex` language
- **Rendering**: Via SwiftMath library (`MTMathImage`) with baseline alignment
- **Streaming**: Math blocks remain open until closing delimiter confirmed

### Streaming & Performance Optimizations (Excellent)
- **Incremental tokenizer**: O(k) per chunk (k = chunk length)
- **Bounded look-behind**: Configurable buffer (default 1024 chars) prevents O(n²)
- **Delta events**: Only emit new content (`blockAppendInline`, `blockAppendFencedCode`)
- **Coalescing**: Adjacent plain text runs merged in assembler
- **Character offsets**: Cached to avoid recalculating string positions
- **Actor-based concurrency**: Tokenizer and renderer are Swift actors

---

## ❌ **MISSING FEATURES** (Per AGENTS.md Requirements)

### 1. **Horizontal Rules / Thematic Breaks**
**Location**: `Sources/PicoMarkdownView/Tokenizer/BlockStateMachine.swift:~580-600` (detectHorizontalRule)
**Status**: **PARTIALLY IMPLEMENTED** but **INCORRECTLY HANDLED**

**Problem**:
- Function `detectHorizontalRule()` exists and detects `---`, `***`, `___`
- BUT: Horizontal rules are rendered as **paragraph blocks** with the literal text (`---`)
- Expected: Should be a distinct `.horizontalRule` block kind or rendered as visual separator

**Fix Required**:
```swift
// In Sources/PicoMarkdownView/Tokenizer/MarkdownTokenizer.swift
public enum BlockKind {
    case horizontalRule  // ADD THIS
    // ...existing cases
}

// In Sources/PicoMarkdownView/Tokenizer/BlockStateMachine.swift ~line 580
if isLineComplete, detectHorizontalRule(lineBuffer, indent: 0) {
    // Don't open paragraph + close
    // Instead:
    emitSingleLineHorizontalRule()
    emittedCount = lineBuffer.count
    lineAnalyzed = true
    return
}

// In Sources/PicoMarkdownView/Renderer/MarkdownAttributeBuilder.swift
case .horizontalRule:
    let separator = NSAttributedString(string: "\n───────\n\n", attributes: ...)
    return RenderedContentResult(attributed: AttributedString(separator), ...)
```

**Why It Matters**: ChatGPT supports `---` as visual separators; PicoMarkdownView should too.

---

### 2. **Footnotes** (GFM Extension)
**Location**: **NOT IMPLEMENTED**
**Status**: ❌ **MISSING**

**Problem**:
- No support for `[^1]` inline references or `[^1]: footnote text` definitions
- This is a GFM extension ChatGPT supports

**Fix Required**:
- Extend `Sources/PicoMarkdownView/Tokenizer/InlineParser.swift` to detect `[^identifier]` syntax
- Add `BlockKind.footnoteDefinition(identifier: String)`
- Renderer must collect footnotes and append them at document end

**Why It Matters**: ChatGPT uses footnotes; required for parity.

---

### 3. **Reference-Style Links**
**Location**: `Sources/PicoMarkdownView/Tokenizer/InlineParser.swift:~parseNestedRuns()`, `~parseBracketSequence()`
**Status**: ❌ **MISSING**

**Problem**:
- Only inline links `[text](url)` are supported
- Reference links `[text][ref]` or `[text]` with `[ref]: url` definitions are **not parsed**
- No link reference storage/resolution

**Fix Required**:
```swift
// 1. Add reference storage to StreamingParser in BlockStateMachine.swift
private var linkReferences: [String: (url: String, title: String?)] = [:]

// 2. Detect link definition lines in BlockStateMachine
// [ref]: https://example.com "optional title"
if detectLinkDefinition(line) {
    storeLinkReference()
    continue  // Don't emit as paragraph
}

// 3. Update InlineParser.parseBracketSequence() to handle [text][ref]
if text[afterBracket] == "[" {
    // Parse reference key
    // Lookup in linkReferences
}
```

**Why It Matters**: ChatGPT supports reference links; common in long documents.

---

### 4. **HTML Tag Passthrough (Safe Subset)**
**Location**: `Sources/PicoMarkdownView/Tokenizer/InlineParser.swift:~parseLineBreakTag()`
**Status**: ⚠️ **PARTIAL** (only `<br>` supported)

**Problem**:
- Only `<br>` (and `<br/>`, `<br />`) is recognized and converted to hard line break
- No support for:
  - `<kbd>` (keyboard keys) → map to monospace style
  - `<sup>`, `<sub>` (superscript/subscript) → map to baseline offset attributes
  - `<mark>` (highlight) → map to background color
- Raw HTML is otherwise **ignored** (safe, but limits ChatGPT parity)

**Fix Required**:
```swift
// In Sources/PicoMarkdownView/Tokenizer/InlineParser.swift
// Add parseInlineHTMLTag() similar to parseLineBreakTag()
// Detect: <kbd>...</kbd>, <sup>...</sup>, <sub>...</sub>
// Emit runs with .keyboard, .superscript, .subscript styles

// In Sources/PicoMarkdownView/Tokenizer/MarkdownTokenizer.swift
public struct InlineStyle: OptionSet {
    public static let keyboard    = InlineStyle(rawValue: 1 << 7)
    public static let superscript = InlineStyle(rawValue: 1 << 8)
    public static let subscript   = InlineStyle(rawValue: 1 << 9)
}
```

**Why It Matters**: ChatGPT allows `<kbd>`, `<sup>`, `<sub>` for semantic markup.

---

### 5. **Multiline Paragraph Bug (Trailing Punctuation)**
**Location**: `Sources/PicoMarkdownView/Tokenizer/InlineParser.swift:~consume()` + `Sources/PicoMarkdownView/Tokenizer/StreamingReplacementEngine.swift:~finish()`
**Status**: 🐛 **REGRESSION BUG** (documented in test)

**Problem**:
- Test `singleMultilineParagraphRetainsPunctuation()` in `Tests/PicoMarkdownViewTests/MarkdownTokenizerGoldenTests.swift:~73`
- **Final period `.` is missing** from last paragraph when text ends mid-sentence
- Comment in test: "FIXME: !!!!! REGRESSION. FINAL . IS STILL MISSING in last paragraph"

**Root Cause**:
- `StreamingReplacementEngine` buffers characters for emoji/literal replacements
- On `finish()`, if the tail contains a potential pattern prefix (e.g., `.` before `..`), it may not flush correctly

**Fix Required**:
```swift
// In Sources/PicoMarkdownView/Tokenizer/StreamingReplacementEngine.swift:~finish()
mutating func finish() -> String {
    var output = String()
    if colonState != .idle {
        flushColonBuffer(into: &output)
        colonState = .idle
    }
    // CRITICAL: Force flush ALL literal patterns with lookahead=true
    while let replacement = matchLiteralPattern(allowLookahead: true) {
        output.append(replacement)
    }
    // FORCE FLUSH REMAINING TAIL (don't hold back for lookahead)
    if !literalTail.isEmpty {
        output.append(String(literalTail))
        literalTail.removeAll(keepingCapacity: true)
    }
    return output
}
```

**Why It Matters**: Data loss bug; breaks semantic integrity of streamed content.

---

## 🔧 **ARCHITECTURAL RECOMMENDATIONS**

### 1. **Horizontal Rule Block Kind**
Add `BlockKind.horizontalRule` to avoid overloading paragraphs.

### 2. **Link Reference Store**
Add document-level state to `StreamingParser` for link definitions.

### 3. **Inline HTML Whitelist**
Extend `InlineParser` with safe tag handlers (`<kbd>`, `<sup>`, `<sub>`).

### 4. **Footnote Registry**
Add footnote accumulator actor; renderer appends footnote section at end.

### 5. **Streaming Replacement Engine Fix**
Audit `finish()` method to ensure **all buffered content** is flushed.

---

## 📊 **PERFORMANCE GUARANTEES** (Validated)

✅ **O(n) tokenization**: Each chunk processed once; no backtracking beyond look-behind buffer  
✅ **O(1) delta rendering**: Only changed blocks re-rendered (via `AssemblerDiff.Change`)  
✅ **Bounded memory**: Old closed blocks discarded via `maxClosedBlocks` / `maxBytesApprox`  
✅ **Actor isolation**: No main-thread blocking; SwiftUI views observe async updates  

---

## 🎯 **PRIORITY FIXES FOR CHATGPT PARITY**

| Feature | Priority | Complexity | Impact on Streaming |
|---------|----------|------------|---------------------|
| Fix `.` truncation bug | **CRITICAL** | Low | None (bug fix) |
| Horizontal rules | **HIGH** | Low | None (new block kind) |
| Reference links | **HIGH** | Medium | None (document-level state) |
| Footnotes | **MEDIUM** | High | Minor (requires post-processing) |
| Safe HTML tags | **LOW** | Medium | None (inline parsing) |

---

## 📝 **CONCLUSION**

PicoMarkdownView is a **high-quality streaming Markdown implementation** optimized for LLM chat use cases. Core CommonMark + GFM features are well-supported with excellent O(n) performance.

**Key Gaps**:
1. Horizontal rules mishandled as paragraphs
2. Reference links not implemented
3. Footnotes missing
4. Safe HTML subset incomplete
5. Punctuation truncation bug in streaming edge case

**All gaps are fixable without compromising streaming performance**. Recommended approach: Fix critical bug first, then add missing block/inline types incrementally.

---

**Document Generated**: 2025-10-27  
**Reviewed Codebase**: PicoMarkdownView @ commit `36f37e4`
