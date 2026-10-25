# Diagrams

Mermaid fences are laid out by [Pele](https://pele.run) and drawn natively. Every diagram type Mermaid 12.1 knows is available; a few of them:

## Flowchart

```mermaid
flowchart TD
  A([Mermaid text]) --> B{Supported?}
  B -- Yes --> C[Parse]
  B -- No --> H[Fall back to a code block]
  subgraph Pele
    C --> D[Layout]
    D --> E[Render]
  end
  E --> F[(SVG)]
  F -.-> G[Rasterize with CoreGraphics]
  style G fill:#ffe9b3,stroke:#b07d00
```

## Sequence

```mermaid
sequenceDiagram
  participant App
  participant View as PicoMarkdownView
  participant Pele
  App->>View: stream chunks
  View->>View: tokenize incrementally
  View->>Pele: closed mermaid fence
  Pele-->>View: SVG
  View-->>App: text attachment
  Note over View,Pele: rendered off the main actor
```

## Class

```mermaid
classDiagram
  class MarkdownTokenizer {
    +feed(chunk) ChunkResult
    +finish() ChunkResult
  }
  class MarkdownAssembler {
    +apply(ChunkResult) AssemblerDiff
  }
  class MarkdownRenderer {
    +apply(AssemblerDiff)
  }
  MarkdownTokenizer --> MarkdownAssembler : events
  MarkdownAssembler --> MarkdownRenderer : diffs
```

## State

```mermaid
stateDiagram-v2
  [*] --> Streaming
  Streaming --> Streaming : chunk
  Streaming --> Closed : closing fence
  Closed --> Rendered : Pele
  Rendered --> [*]
```

## Pie

```mermaid
pie title Where the time goes
  "Tokenizer" : 12
  "Layout" : 28
  "Rasterizing" : 10
  "Waiting for the model" : 50
```

## Gantt

```mermaid
gantt
  title Release plan
  dateFormat YYYY-MM-DD
  section Engine
  Pele in JavaScriptCore :done, a1, 2026-10-20, 2d
  Native rasterizer      :done, a2, after a1, 2d
  section Product
  Ship                   :active, a3, after a2, 1d
```

## ER

```mermaid
erDiagram
  CONVERSATION ||--o{ MESSAGE : contains
  MESSAGE ||--o{ BLOCK : renders
  BLOCK {
    string kind
    bool closed
  }
```

## Git graph

```mermaid
gitGraph
  commit
  branch pele
  commit
  commit
  checkout main
  merge pele
  commit
```

## Mindmap

```mermaid
mindmap
  root((PicoMarkdownView))
    Streaming
      Incremental tokenizer
      TextKit edits
    Rendering
      Prism
      KaTeX
      Pele
```

## XY chart

```mermaid
xychart-beta
  title "Tokens per second"
  x-axis [1k, 2k, 4k, 8k]
  y-axis "tok/s" 0 --> 120
  bar [110, 104, 96, 80]
  line [110, 104, 96, 80]
```

## Not a diagram

A fence Pele cannot parse stays a code block:

```mermaid
this is not mermaid
```
