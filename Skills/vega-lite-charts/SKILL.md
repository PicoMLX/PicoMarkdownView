---
name: vega-lite-charts
description: >-
  Write static Vega-Lite charts in Pico answers when verified numerical data is
  clearer as bars, a time series, or a scatter plot. Use the exact vega-lite
  fence and Pico's bounded inline-data profile. Not for relationship diagrams,
  interactive dashboards, maps, or code the user wants to read verbatim.
---

# Static charts with Vega-Lite

Use one chart for a numerical comparison, trend, distribution, or relationship
that is easier to see than to describe. Prefer a table for a few exact values,
Mermaid/Pele for connected entities, and prose for a single number.

## Output contract

- Put one complete JSON specification in a fenced block whose info string is
  exactly `vega-lite`. A `json` or `vega` fence stays code.
- macOS 27 renders supported, completed fences as native vector charts, enabled
  by default. iOS displays the source as code. Keep the surrounding explanation
  and important values useful in either presentation.
- Charts compile only when their fence closes or the stream finishes normally.
  While source streams, the viewer shows a compact loading row, not partial
  data marks. Invalid or unsupported final specifications remain code.
- The result is static. Native zoom/pan changes the viewing scale inside its
  frame; it does not provide data tooltips, brushing, filtering, live updates,
  or click actions. Do not promise those interactions.
- Selecting across a chart includes it as one block; copying exports its fenced
  JSON source. Ordinary Markdown before and after it stays native text.

## Supported profile

Use ordinary Vega-Lite v6 JSON with `data.values`, or named data backed by inline
`datasets`. The optional `$schema` URL identifies the format; it is not fetched.
Prefer a few dozen records. Total inline data is limited to 4,096 rows; faceted
specifications are limited to 128. The JSON source limit is 2 MiB, and additional
composition, expression, geometry, and output limits can reject smaller specs.
Use `width: "container"` for a simple responsive chart, a modest height, or
numeric dimensions from 1 to 2,048. Wide faceted/repeated charts still need to
fit the reading context.

Simple `filter`, `calculate`, and conditional `test` expressions are supported
through a bounded interpreter: field access such as `datum.durationMs`, scalar
arithmetic/comparisons, logical operators, and a restricted set of scalar
helpers such as `abs`, `min`, `max`, and `round`. Prefer declarative field
predicates for filtering. Compute complicated derived data upstream and include
its results inline. Expressions must return bounded scalar values; arbitrary
JavaScript, method calls, computed property names, regexes, and generated arrays
are not supported.

Leave out:

- Remote/local data URLs, `href` links, external assets, image/geoshape marks,
  and geographic projections. Describe places with text/links, or use a
  host-provided map when one is available.
- Interactive selections/bindings and `signal`, `expr`, or `labelExpr` hooks.
- Data generators and transforms outside the profile, including sequence,
  density, loess, regression, lookup, impute, pivot, and flatten. Supply already
  computed data instead; bounded aggregate/bin/window/fold transforms are
  available when they remain within the renderer's limits.
- HTML/browser features, scripts, animation, and unsupported SVG effects.

## Communicate the data faithfully

- Preserve verified values, units, dates, time zones, denominators, and missing
  data. Do not invent observations. Clearly label demonstrations as illustrative.
- Choose bars for magnitude comparisons, lines for ordered time, and points for
  relationships. Sort nominal bars by a useful order; preserve chronological
  order for time. Do not imply continuity across missing periods without saying so.
- Give axes meaningful titles and units. Use a zero baseline for bar lengths.
  If a line/scatter plot needs a restricted domain, disclose it. Avoid dual axes;
  use separate charts for quantities with different units.
- Let the surrounding theme supply text and default mark colors when possible.
  Keep a single series one color. For multiple series, use stable identities,
  readable contrast in light/dark themes, a legend, and an additional distinction
  such as shape or dash; color alone must not carry the meaning.
- Add a short takeaway and important exact values in prose or a compact table.
  Do not rely on hovering to reveal values. Keep titles/labels short enough for
  narrow chat widths; split crowded compositions into separate charts.

## Examples

These small datasets are illustrative, not measurements. Replace them with
verified data for a real answer. All three fences are exercised by the bundled
compiler and native SVG drawing tests.

### Compare category counts

Interactive requests outnumber either other queue in this illustrative sample.

| Queue | Requests (count) |
| --- | ---: |
| Interactive | 42 |
| Batch | 28 |
| Background | 16 |

```vega-lite
{
  "$schema": "https://vega.github.io/schema/vega-lite/v6.json",
  "description": "Illustrative request counts by queue.",
  "title": "Illustrative request counts",
  "width": "container", "height": 160,
  "data": {"values": [
    {"queue": "Interactive", "requests": 42},
    {"queue": "Batch", "requests": 28},
    {"queue": "Background", "requests": 16}
  ]},
  "mark": "bar",
  "encoding": {
    "y": {"field": "queue", "type": "nominal", "sort": "-x", "title": "Queue"},
    "x": {"field": "requests", "type": "quantitative", "title": "Requests (count)", "scale": {"zero": true}}
  }
}
```

### Show a time trend

The illustrative median latency declines across these four UTC dates.

| Date (UTC) | Median latency (ms) |
| --- | ---: |
| 2026-01-01 | 120 |
| 2026-01-02 | 110 |
| 2026-01-03 | 115 |
| 2026-01-04 | 95 |

```vega-lite
{
  "$schema": "https://vega.github.io/schema/vega-lite/v6.json",
  "description": "Illustrative median latency on four consecutive UTC dates.",
  "title": "Illustrative latency trend",
  "width": "container", "height": 180,
  "data": {"values": [
    {"date": "2026-01-01T00:00:00Z", "latencyMs": 120},
    {"date": "2026-01-02T00:00:00Z", "latencyMs": 110},
    {"date": "2026-01-03T00:00:00Z", "latencyMs": 115},
    {"date": "2026-01-04T00:00:00Z", "latencyMs": 95}
  ]},
  "mark": {"type": "line", "point": true, "strokeWidth": 2},
  "encoding": {
    "x": {"field": "date", "type": "temporal", "title": "Date (UTC)", "scale": {"type": "utc"}, "axis": {"format": "%b %d", "tickCount": 4}},
    "y": {"field": "latencyMs", "type": "quantitative", "title": "Median latency (ms)", "scale": {"zero": true}}
  }
}
```

### Derive a bounded quantity

Here throughput is batch size divided by elapsed seconds. The invalid zero-time
record is omitted explicitly, rather than drawn as zero throughput.

| Batch size (items) | Duration (ms) | Throughput (items/s) |
| ---: | ---: | ---: |
| 1 | 8 | 125 |
| 4 | 20 | 200 |
| 8 | 32 | 250 |
| 16 | 40 | 400 |
| 32 | 0 | Invalid; omitted |

```vega-lite
{
  "$schema": "https://vega.github.io/schema/vega-lite/v6.json",
  "description": "Illustrative batch throughput; zero-duration observations are omitted.",
  "title": "Illustrative throughput",
  "padding": {"top": 12, "right": 5, "bottom": 5, "left": 5},
  "width": "container", "height": 180,
  "data": {"values": [
    {"batchSize": 1, "durationMs": 8},
    {"batchSize": 4, "durationMs": 20},
    {"batchSize": 8, "durationMs": 32},
    {"batchSize": 16, "durationMs": 40},
    {"batchSize": 32, "durationMs": 0}
  ]},
  "transform": [
    {"filter": {"field": "durationMs", "gt": 0}},
    {"calculate": "datum.batchSize * 1000 / datum.durationMs", "as": "itemsPerSecond"}
  ],
  "mark": {"type": "point", "filled": true, "size": 64, "opacity": 1},
  "encoding": {
    "x": {"field": "batchSize", "type": "quantitative", "title": "Batch size (items)", "scale": {"zero": true}},
    "y": {"field": "itemsPerSecond", "type": "quantitative", "title": "Throughput (items/s)", "scale": {"zero": true}}
  }
}
```
