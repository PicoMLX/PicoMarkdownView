# Vega-Lite gallery measurements

## Current provider classification — October 31, 2026

The current bounded profile was measured against all 189 distinct official specifications at both **336 and 480 points**, using provider-only mode. It permits sources up to 2 MiB, at most 400,000 JSON nodes, bounded filter/calculate expressions, and standard repeat references. Both widths produced the same outcomes, with real SVG data marks, native parsing and CoreGraphics drawing for every successful result. No complete preview or full-corpus Markdown pipeline was run for this update.

| Outcome | Distinct examples | Gallery placements |
| --- | ---: | ---: |
| Successful native chart | 115 | 128 |
| Source exceeds 2 MiB | 4 | 4 |
| Other policy rejection | 68 | 69 |
| Expression/runtime or native SVG rejection after Swift preflight | 2 | 2 |
| Total | 189 | 203 |

All original 51 successful distinct examples remain, and 64 additional distinct examples now render. The regenerated preview retains all 203 headings and official links, **128 exact chart fence bodies and 75 notices**. It is 32,080,820 bytes uncompressed (30.59 MiB), stored in a 4,047,784-byte resource (3.86 MiB). Its normalized classification report preserves outcomes at both tested widths, the source byte limit, benchmark report digests and the original successful IDs. The complete 67,025,394-byte corpus and its original manifest remain byte-identical.

The two remaining expression/runtime/SVG fallbacks are `isotype_bar_chart_emoji` and `point_offset_random`. Maps and interactive bindings remain outside the static profile. The preview is a measured compatibility inventory, not a claim of browser visual equivalence.

All ten user-reported missing examples render at both widths. The scoped gallery regressions feed each exact source as one completed fence and verify these native data-mark counts, finite SVG output, original source retention and native rasterization:

| Official example ID | Data marks |
| --- | ---: |
| `bar_aggregate` | 19 |
| `bar_aggregate_sort_by_encoding` | 19 |
| `bar_grouped_repeated` | 26 |
| `stacked_bar_weather` | 54 |
| `stacked_bar_count_corner_radius_mark` | 54 |
| `stacked_bar_normalize` | 38 |
| `stacked_bar_h_normalized_labeled` | 76 |
| `bar_layered_transparent` | 38 |
| `bar_diverging_stack_population_pyramid` | 38 |
| `bar_diverging_stack_transform` | 40 |

The separate barley geometry regression verifies 120 dispersed points and numeric aggregate-axis ticks. This catches the compiler clone defect that a nonzero mark count alone did not detect.

| Provider-only run | Fresh-cache median | Process lifetime peak RSS |
| --- | ---: | ---: |
| 336 points | 22.610 ms | 323.8 MiB |
| 480 points | 22.086 ms | 317.9 MiB |

These debug measurements include the shared JavaScriptCore runtime; the peak includes fixture loading and earlier operations in the same process. They do not measure TextKit layout, frame rate or on-screen streaming performance. Evidence: `/private/tmp/pico-vega-gallery-providers-336.json` and `/private/tmp/pico-vega-gallery-providers-480.json`, with sibling `.log` files. The two complete provider-only tests passed in 13.943 s and 14.784 s respectively.

The example app's existing nominal 30-word/s stream is unchanged. Dense JSON also passes through that word stream: this larger preview contains 1,572,555 words and therefore about **14.56 hours of simulated delay**, before scheduling/rendering overhead. The first five chart fences close by approximately 31.5 s; `bar_grouped_repeated` alone contains 72,270 words and closes around 40.7 minutes from the start. Open fences intentionally remain code until closure. The immediate completed-fence regressions above establish rendering independently of that simulation delay; no long word-stream run was performed for this update.

Run the current bounded coverage and provider-only measurements without the heavy whole-document benchmark:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH=/private/tmp/pico-vega-module-cache
swift test --scratch-path /private/tmp/pico-vega-tests --jobs 8 \
  --filter VegaLiteGalleryTests
for gallery_width in 336 480; do
  PICO_RUN_VEGA_GALLERY_BENCHMARKS=1 \
  PICO_VEGA_GALLERY_PROVIDER_ONLY=1 \
  PICO_VEGA_GALLERY_TARGET_WIDTH="$gallery_width" \
  PICO_VEGA_GALLERY_BENCHMARK_REPORT="/private/tmp/pico-vega-gallery-providers-$gallery_width.json" \
  swift test --scratch-path /private/tmp/pico-vega-tests --skip-build \
    --filter VegaLiteGalleryBenchmarks
done
```

Regenerate this measured preview offline with the checked-in `preview-rendering-report.json`; the exporter verifies all distinct IDs and source byte counts and refuses to drop original successes.

## Archived baseline — October 30, 2026, 128 KiB profile

The following records the earlier profile and full-pipeline experiment. Its 51/53 successful counts and old preview inventory are historical; the current inventory is above. The complete archived corpus and its hashes remain unchanged. These earlier pipeline/UI stress measurements were not repeated after the runtime fixes.

Measured on October 30, 2026, using a **debug** SwiftPM build on macOS 27.0.1 (26A434), Apple M5 Max (Mac17,14, 18 CPU cores, 128 GiB memory). This is one local run, with no timing thresholds. The fixture contains 203 gallery placements of 189 distinct official examples, pinned by `Tests/Fixtures/VegaLiteGallery/manifest.json`. Its exported Markdown is 67,025,394 bytes (63.92 MiB), stored in a 9,658,735-byte compressed resource.

The normal CI tests verify all 203 exported fence hashes and preflight outcomes, and render three bounded examples (`bar`, `bar_gantt`, `arc_pie`) plus one source fallback (`scatter_image`). A separate CI check verifies the rendering preview against all original headings, links and manifest entries, including the 53 exact chart fences and 150 notices. The opt-in benchmark below exercises all distinct examples through the real provider and the full document through the Markdown pipeline.

| Outcome | Distinct examples | Gallery placements |
| --- | ---: | ---: |
| Successful native chart | 51 | 53 |
| Source exceeds 128 KiB policy limit | 60 | 66 |
| Other policy rejection | 78 | 84 |
| Runtime or native SVG rejection after policy acceptance | 0 | 0 |
| Total | 189 | 203 |

Every successful provider result contained data marks and completed native SVG parsing and CoreGraphics drawing. These checks establish rendered content, not visual equivalence with the browser gallery. The examples rejected by the current static profile remain source code. The complete gallery export is not a claim of full Vega-Lite feature support.

All 203 completed fence snapshots retained their exact exported JSON bodies in both pipeline modes. Rendered charts retained the same source; fallback code blocks retained the same code. This assertion covers source retention in the pipeline, rather than manually exercising native copy/paste for every gallery placement.

| Successful chart operation | Median | P95 | Maximum |
| --- | ---: | ---: | ---: |
| Fresh provider cache | 17.386 ms | 40.970 ms | 43.853 ms |
| Repeated provider cache hit | 0.280 ms | 1.809 ms | 2.752 ms |
| Additional native SVG parse | 0.530 ms | 2.360 ms | 2.693 ms |
| Additional native CoreGraphics draw | 2.292 ms | 157.590 ms | 162.655 ms |

The first row contains 51 successful chart calls; cache hits contain five repetitions per chart (255 calls). Both use the default theme and request a provider width of 480 points. “Fresh” refers to the individual provider's cache: the JavaScriptCore runtime is a shared singleton, and the first call may include its initialization. Provider timings include policy inspection, official compiler/runtime SVG generation, and the runtime's native SVG compatibility validation. The additional parse and draw measurements perform those operations again in isolation; they are not subtractions from the provider time. Drawing uses the hosted canvas's `strokesAsFills: true` mode in a bitmap CoreGraphics context. Fallback timings are recorded separately in the JSON report and are excluded from this table.

The slowest isolated native draws were `point_bubble` (162.655 ms, 392 data marks), `point_2d` (158.134 ms, 392), `layer_scatter_errorband_1D_stdev_global_mean` (157.590 ms, 394), `circle` (155.485 ms, 392), and `point_color_with_shape` (139.063 ms, 342).

| Complete Markdown pipeline | Chunks | Elapsed | Process lifetime peak resident memory |
| --- | ---: | ---: | ---: |
| Whole document in one feed | 1 | 12.183 s | 553.5 MiB |
| Streamed, at most 8 KiB UTF-8 per feed | 8,182 | 272.475 s | 640.7 MiB |

These pipeline measurements use `MarkdownStreamingPipeline()` with its default theme and no runtime width constraint. They include tokenization, assembly, rendered block updates and `finish()`, with the shared runtime already used by the provider phase. They exclude fixture loading, TextKit layout, on-screen presentation, scrolling and animation; they are **not FPS measurements or a WebKit comparison**. Fixture decompression, manifest decoding and fence indexing took 1.122 s separately. Peak resident memory is a process lifetime high-water mark, including earlier benchmark phases, rather than incremental memory allocated by the named phase.

A separate native example-app check of the full 63.92 MiB document became unresponsive and was stopped. About 138 s after launch, the UI sample was captured at 22:58:49. The process had been observed at roughly 7 GiB RSS; the sample separately reported physical footprint 3.3G and peak physical footprint 9.2G. These are different memory measurements from the pipeline benchmark's process-lifetime RSS, and the sample does not identify which allocation category owns the memory.

The sampled main thread had 950 observations. One dominant path contained 509 observations (53.6%): `StreamingTextKit2View.intrinsicContentSize` → `measuredContentSize()` at `MacStreamingTextView.swift:180` → `NSTextLayoutManager.ensureLayout(for: content.documentRange)` → TextKit/CoreText paragraph layout and line breaking. Only 13 observations appeared in the native attributed-string conversion path `TextKitStreamingBackend.attributedString(for:)` → `NSAttributedString.picoConverted`; no main-thread `VegaLiteRuntime.render` frame appeared. A background renderer thread also performed attributed-string work. This sample supports full-document TextKit measurement and line layout as the dominant observed main-thread cost; it does not establish total-run percentages or blame chart compilation. Local evidence: `/private/tmp/pico-vega-gallery-ui-hang-sample.txt`.

At that baseline, the Gallery UI used a separate rendering preview containing all 203 headings and official links, the 53 exact chart fence bodies that rendered, and 150 brief policy or size fallback notices. The full 203-fence source resource and its benchmark remain unchanged. The preview avoids laying out tens of megabytes of unsupported JSON as code; it does not expand the native chart feature profile.

Most corpus bytes belong to source fallbacks: the 189 distinct exported specifications contain 1.24 MB of successful-chart source, 2.57 MB of other policy-rejected source, and 56.34 MB of size-rejected source. The full-document streaming result therefore includes repeated updates to large native code blocks; it should not be presented as chart compilation throughput.

Run the bounded coverage first, then opt into the heavy benchmark. These are the commands used for this debug measurement; the report path is optional:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH=/private/tmp/pico-vega-module-cache
swift test --scratch-path /private/tmp/pico-vega-tests --jobs 8 \
  --filter VegaLiteGalleryTests
PICO_RUN_VEGA_GALLERY_BENCHMARKS=1 \
PICO_VEGA_GALLERY_BENCHMARK_REPORT=/private/tmp/pico-vega-gallery-benchmark.json \
swift test --scratch-path /private/tmp/pico-vega-tests --skip-build \
  --filter VegaLiteGalleryBenchmarks
```

The heavy benchmark passed after 288.137 s. Its local evidence is `/private/tmp/pico-vega-gallery-benchmark.json` and `/private/tmp/pico-vega-gallery-benchmark.log`; only this scoped summary is checked into the repository. Future runs write `buildConfiguration` and `providerChartTargetWidth` metadata and checkpoint completed phases so an interrupted streamed run does not discard provider or whole-document measurements. Normal CI does not enable this benchmark.
