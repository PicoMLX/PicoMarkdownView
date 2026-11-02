# Progressive image previews

The first progressive image implementation is deliberately limited to macOS standalone image blocks and progressive JPEG downloads. Apps opt in by supplying `URLSessionMarkdownImageProvider(progressiveJPEGPreviews: true)`. The default provider remains final-only; the macOS example opts in.

## Delivery and rendering

- The existing capped, shared URL download supplies accumulated byte prefixes to Image I/O. It still produces and caches the final image through the existing decoder.
- Preview decoding runs on one shared serial utility queue. Each image accepts at most eight geometric byte checkpoints, starting at 4 KiB, and retains only its latest pending prefix. Preview thumbnails are at most 1024 pixels per side. Sources above 40 megapixels receive no previews.
- Baseline JPEG and other formats retain final-only presentation. Preview availability also depends on network chunking and Image I/O; a quickly completed response may have no useful intermediate frame.
- Only closed paragraphs, list items or blockquotes containing one image and no prose can install a preview host. Native container styling and markers remain in the text view. Inline, heading and table-cell images do not change.
- The first preview replaces the image's alternative-text presentation with the existing hosted image attachment. Native size invalidation uses the existing deferred block-layout queue so it is not absorbed by a parent layout pass. Later previews update the attachment's image model directly, without passing through SwiftUI observation, reparsing Markdown, editing text storage, or requesting layout. Logical source dimensions keep the viewport steady as thumbnail quality changes.
- Final delivery uses the same host. Failure withdraws the preview and restores the normal alternative-text fallback. Request generations, monotonic preview sequences and terminal state reject callbacks arriving after replacement, cancellation, failure or completion. Paused presentation retains only the latest pending frame.

No chart, SVG, HTML, OpenUI or Mermaid rendering behavior changes. There is no new loading label, spinner or toolbar.

## Verification

Generated Image I/O JPEG fixtures exercise partial delivery before completion, shared downloads, cancellation, cache identity, baseline/PNG behavior, orientation, source and thumbnail limits, and checkpoint coalescing. Native-view tests cover selection and raw Markdown copying, retained attachment/model/canvas identity, no character edits for later preview frames, natural mounting without scrolling, container markers, failure, stale callbacks, lazy sizing and pause/resume.

The optional benchmark can be run locally without introducing a CI timing gate:

```bash
PICO_RUN_IMAGE_PREVIEW_BENCHMARKS=1 swift test --filter ProgressiveImageBenchmarks
```

It writes `/private/tmp/pico-progressive-image-benchmark.json`; set `PICO_IMAGE_PREVIEW_BENCHMARK_REPORT` to choose another path.

One [recorded local debug run](Benchmarks/2026-11-01-progressive-jpeg/report.json) on macOS 27.0.1, with 18 logical processors, used a generated 1,042,512-byte progressive JPEG (1536 × 768) alongside 84,998 bytes of Markdown in 48 chunks. Four measured rounds reversed configuration order after warm-up; each configuration contributed 192 feed measurements.

| Concurrent preview decoders | Median Markdown feed | 95th percentile feed | Total feed time across four rounds |
| --- | ---: | ---: | ---: |
| 0 | 9.765 ms | 9.928 ms | 1875.703 ms |
| 1 | 9.814 ms | 9.985 ms | 1884.445 ms |
| 4 | 9.841 ms | 10.078 ms | 1894.169 ms |

All runs produced 48 updates and 912 final blocks. Every decoder performed eight attempts; all snapshots were 1024 × 512 or smaller. Isolated elapsed time for all eight checkpoints was 47.426 ms for one decoder and 122.504 ms for four decoders sharing the serial queue. Decoder starts overlapped Markdown feeds in the concurrent cases.

These measurements describe this machine and fixture. They include Markdown pipeline work and concurrent thumbnail decoding, but exclude network transfer, final-image decoding, SwiftUI, TextKit layout, canvas painting and frame rate. They support a bounded first implementation, not a guarantee of unchanged scrolling performance on every device or transcript.
