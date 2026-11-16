# Charts

Start with a narrated comparison, a time series, and a scatter plot, then explore official examples of grouping, ranges, transformations, annotations, and small multiples.

These examples use inline data and the explicit `vega-lite` fence. On macOS,
charts render as vectors after the fence closes. Text remains selectable
across each chart, and copying includes the original fenced JSON.

## Comparing categories

North had the largest output in this illustrative dataset. The bars start at zero.

```vega-lite
{
  "$schema": "https://vega.github.io/schema/vega-lite/v6.json",
  "title": "Output by region",
  "description": "Illustrative output: North 28, South 19, West 23 units.",
  "data": {"values": [
    {"region": "North", "units": 28},
    {"region": "South", "units": 19},
    {"region": "West", "units": 23}
  ]},
  "mark": {"type": "bar", "cornerRadiusEnd": 4},
  "encoding": {
    "x": {"field": "region", "type": "nominal", "axis": {"title": null}},
    "y": {"field": "units", "type": "quantitative", "title": "Units"}
  }
}
```

This paragraph follows the chart in the same TextKit 2 document.

## Change over time

The illustrative series rises overall, with a dip in March.

```vega-lite
{
  "$schema": "https://vega.github.io/schema/vega-lite/v6.json",
  "title": "Monthly output",
  "data": {"values": [
    {"month": "2026-01-01", "units": 10},
    {"month": "2026-02-01", "units": 14},
    {"month": "2026-03-01", "units": 12},
    {"month": "2026-04-01", "units": 19}
  ]},
  "mark": {"type": "line", "point": {"size": 64}, "strokeWidth": 2},
  "encoding": {
    "x": {"field": "month", "type": "temporal", "title": "Month", "scale": {"type": "utc"}, "axis": {"format": "%b", "tickCount": 4}},
    "y": {"field": "units", "type": "quantitative", "title": "Units", "scale": {"zero": true}}
  }
}
```

## Relationship between measurements

Each dot is one illustrative observation. Both position and labels describe the data.

```vega-lite
{
  "$schema": "https://vega.github.io/schema/vega-lite/v6.json",
  "title": "Input and output",
  "data": {"values": [
    {"input": 2, "output": 7}, {"input": 4, "output": 12},
    {"input": 6, "output": 11}, {"input": 8, "output": 20},
    {"input": 10, "output": 23}
  ]},
  "mark": {"type": "point", "filled": true, "size": 64},
  "encoding": {
    "x": {"field": "input", "type": "quantitative", "title": "Input"},
    "y": {"field": "output", "type": "quantitative", "title": "Output"}
  }
}
```

## Charts inside Markdown containers

- A chart can be the first content of a list item:

  ```vega-lite
  {"data":{"values":[{"label":"One","value":3},{"label":"Two","value":5}]},"mark":"bar","encoding":{"x":{"field":"label","type":"nominal"},"y":{"field":"value","type":"quantitative"}}}
  ```

> Charts also respect the width and native bar of a blockquote.
>
> ```vega-lite
> {"data":{"values":[{"x":0,"y":1},{"x":1,"y":4},{"x":2,"y":2}]},"mark":"line","encoding":{"x":{"field":"x","type":"quantitative"},"y":{"field":"y","type":"quantitative"}}}
> ```

## Ordinary JSON stays code

The same JSON with a `json` fence remains a code sample:

```json
{"data":{"values":[{"x":1,"y":2}]},"mark":"point"}
```

## Official Vega-Lite examples

The following six specifications are copied exactly from the pinned Vega-Lite 6.5.0 gallery, including their complete inline data. Accompanying Markdown explanations and data tables are additions for this example app. These are static native plots; the full Gallery contains the broader compatibility corpus.

## Grouped comparisons

Compare three groups side by side within each category. Group identity uses both the horizontal offset and the legend; the underlying nine observations appear below the plot.

```vega-lite
{"$schema":"https://vega.github.io/schema/vega-lite/v6.json","data":{"values":[{"category":"A","group":"x","value":0.1},{"category":"A","group":"y","value":0.6},{"category":"A","group":"z","value":0.9},{"category":"B","group":"x","value":0.7},{"category":"B","group":"y","value":0.2},{"category":"B","group":"z","value":1.1},{"category":"C","group":"x","value":0.6},{"category":"C","group":"y","value":0.1},{"category":"C","group":"z","value":0.2}]},"mark":"bar","encoding":{"x":{"field":"category"},"y":{"field":"value","type":"quantitative"},"xOffset":{"field":"group"},"color":{"field":"group"}}}
```

[Official example](https://github.com/vega/vega-lite/blob/e415f441845e198629f2049b46849ddcfdbf6596/examples/specs/bar_grouped.vl.json)

### Data

| category | group | value |
| --- | --- | --- |
| A | x | 0.1 |
| A | y | 0.6 |
| A | z | 0.9 |
| B | x | 0.7 |
| B | y | 0.2 |
| B | z | 1.1 |
| C | x | 0.6 |
| C | y | 0.1 |
| C | z | 0.2 |

## Values on both sides of zero

Bars extend above and below a shared zero baseline. The conditional axis styling emphasizes zero while keeping a single quantitative scale.

```vega-lite
{"$schema":"https://vega.github.io/schema/vega-lite/v6.json","description":"A bar chart with negative values. We can hide the axis domain line, and instead use a conditional grid color to draw a zero baseline.","data":{"values":[{"a":"A","b":-28},{"a":"B","b":55},{"a":"C","b":-33},{"a":"D","b":91},{"a":"E","b":81},{"a":"F","b":53},{"a":"G","b":-19},{"a":"H","b":87},{"a":"I","b":52}]},"mark":"bar","encoding":{"x":{"field":"a","type":"nominal","axis":{"domain":false,"ticks":false,"labelAngle":0,"labelPadding":4}},"y":{"field":"b","type":"quantitative","axis":{"gridColor":{"condition":{"test":"datum.value === 0","value":"black"},"value":"#ddd"}}}}}
```

[Official example](https://github.com/vega/vega-lite/blob/e415f441845e198629f2049b46849ddcfdbf6596/examples/specs/bar_negative.vl.json)

### Data

| a | b |
| --- | --- |
| A | -28 |
| B | 55 |
| C | -33 |
| D | 91 |
| E | 81 |
| F | 53 |
| G | -19 |
| H | 87 |
| I | 52 |

## Transformations and logarithmic bins

This official example calculates logarithms, bins the transformed values, and converts the bin boundaries back to the original units. It exercises a data transformation pipeline as well as a logarithmic axis.

```vega-lite
{"$schema":"https://vega.github.io/schema/vega-lite/v6.json","description":"Log-scaled Histogram.  We may improve the support of this. See https://github.com/vega/vega-lite/issues/4792.","data":{"values":[{"x":0.01},{"x":0.1},{"x":1},{"x":1},{"x":1},{"x":1},{"x":10},{"x":10},{"x":100},{"x":500},{"x":800}]},"transform":[{"calculate":"log(datum.x)/log(10)","as":"log_x"},{"bin":true,"field":"log_x","as":"bin_log_x"},{"calculate":"pow(10, datum.bin_log_x)","as":"x1"},{"calculate":"pow(10, datum.bin_log_x_end)","as":"x2"}],"mark":"bar","encoding":{"x":{"field":"x1","scale":{"type":"log","base":10},"axis":{"tickCount":5}},"x2":{"field":"x2"},"y":{"aggregate":"count"}}}
```

[Official example](https://github.com/vega/vega-lite/blob/e415f441845e198629f2049b46849ddcfdbf6596/examples/specs/histogram_log.vl.json)

### Data

| x |
| --- |
| 0.01 |
| 0.1 |
| 1 |
| 1 |
| 1 |
| 1 |
| 10 |
| 10 |
| 100 |
| 500 |
| 800 |

## Ranges and schedules

A ranged bar has a start and an end rather than a shared zero baseline. The three sample tasks form a short sequence, making this a useful layout for schedules and intervals.

```vega-lite
{"$schema":"https://vega.github.io/schema/vega-lite/v6.json","description":"A simple bar chart with ranged data (aka Gantt Chart).","data":{"values":[{"task":"A","start":1,"end":3},{"task":"B","start":3,"end":8},{"task":"C","start":8,"end":10}]},"mark":"bar","encoding":{"y":{"field":"task","type":"ordinal"},"x":{"field":"start","type":"quantitative"},"x2":{"field":"end"}}}
```

[Official example](https://github.com/vega/vega-lite/blob/e415f441845e198629f2049b46849ddcfdbf6596/examples/specs/bar_gantt.vl.json)

### Data

| task | start | end |
| --- | --- | --- |
| A | 1 | 3 |
| B | 3 | 8 |
| C | 8 | 10 |

## Layered annotations

The original example layers an emphasized part of a bar, a horizontal threshold rule, and a text annotation over its base plot. Its historical air-quality data and threshold are retained as an upstream rendering fixture.

```vega-lite
{"$schema":"https://vega.github.io/schema/vega-lite/v6.json","description":"The PM2.5 value of Beijing observed 15 days, highlighting the days when PM2.5 level is hazardous to human health. Data source https://chartaccent.github.io/chartaccent.html","layer":[{"data":{"values":[{"Day":1,"Value":54.8},{"Day":2,"Value":112.1},{"Day":3,"Value":63.6},{"Day":4,"Value":37.6},{"Day":5,"Value":79.7},{"Day":6,"Value":137.9},{"Day":7,"Value":120.1},{"Day":8,"Value":103.3},{"Day":9,"Value":394.8},{"Day":10,"Value":199.5},{"Day":11,"Value":72.3},{"Day":12,"Value":51.1},{"Day":13,"Value":112.0},{"Day":14,"Value":174.5},{"Day":15,"Value":130.5}]},"layer":[{"mark":"bar","encoding":{"x":{"field":"Day","type":"ordinal","axis":{"labelAngle":0}},"y":{"field":"Value","type":"quantitative"}}},{"mark":"bar","transform":[{"filter":"datum.Value >= 300"},{"calculate":"300","as":"baseline"}],"encoding":{"x":{"field":"Day","type":"ordinal"},"y":{"field":"baseline","type":"quantitative","title":"PM2.5 Value"},"y2":{"field":"Value"},"color":{"value":"#e45755"}}}]},{"data":{"values":[{}]},"encoding":{"y":{"datum":300}},"layer":[{"mark":"rule"},{"mark":{"type":"text","align":"right","baseline":"bottom","dx":-2,"dy":-2,"x":"width","text":"hazardous"}}]}]}
```

[Official example](https://github.com/vega/vega-lite/blob/e415f441845e198629f2049b46849ddcfdbf6596/examples/specs/layer_bar_annotations.vl.json)

### Data

| Day | Value |
| --- | --- |
| 1 | 54.8 |
| 2 | 112.1 |
| 3 | 63.6 |
| 4 | 37.6 |
| 5 | 79.7 |
| 6 | 137.9 |
| 7 | 120.1 |
| 8 | 103.3 |
| 9 | 394.8 |
| 10 | 199.5 |
| 11 | 72.3 |
| 12 | 51.1 |
| 13 | 112.0 |
| 14 | 174.5 |
| 15 | 130.5 |

## Small multiples

Four scatter plots share a consistent structure while revealing different distributions. The complete Anscombe data stays in the specification; resizing the window also exercises the layout of multiple plot panels.

```vega-lite
{"$schema":"https://vega.github.io/schema/vega-lite/v6.json","description":"Anscombe's Quartet","data":{"values":[{"Series":"I","X":10.0,"Y":8.04},{"Series":"I","X":8.0,"Y":6.95},{"Series":"I","X":13.0,"Y":7.58},{"Series":"I","X":9.0,"Y":8.81},{"Series":"I","X":11.0,"Y":8.33},{"Series":"I","X":14.0,"Y":9.96},{"Series":"I","X":6.0,"Y":7.24},{"Series":"I","X":4.0,"Y":4.26},{"Series":"I","X":12.0,"Y":10.84},{"Series":"I","X":7.0,"Y":4.81},{"Series":"I","X":5.0,"Y":5.68},{"Series":"II","X":10.0,"Y":9.14},{"Series":"II","X":8.0,"Y":8.14},{"Series":"II","X":13.0,"Y":8.74},{"Series":"II","X":9.0,"Y":8.77},{"Series":"II","X":11.0,"Y":9.26},{"Series":"II","X":14.0,"Y":8.1},{"Series":"II","X":6.0,"Y":6.13},{"Series":"II","X":4.0,"Y":3.1},{"Series":"II","X":12.0,"Y":9.13},{"Series":"II","X":7.0,"Y":7.26},{"Series":"II","X":5.0,"Y":4.74},{"Series":"III","X":10.0,"Y":7.46},{"Series":"III","X":8.0,"Y":6.77},{"Series":"III","X":13.0,"Y":12.74},{"Series":"III","X":9.0,"Y":7.11},{"Series":"III","X":11.0,"Y":7.81},{"Series":"III","X":14.0,"Y":8.84},{"Series":"III","X":6.0,"Y":6.08},{"Series":"III","X":4.0,"Y":5.39},{"Series":"III","X":12.0,"Y":8.15},{"Series":"III","X":7.0,"Y":6.42},{"Series":"III","X":5.0,"Y":5.73},{"Series":"IV","X":8.0,"Y":6.58},{"Series":"IV","X":8.0,"Y":5.76},{"Series":"IV","X":8.0,"Y":7.71},{"Series":"IV","X":8.0,"Y":8.84},{"Series":"IV","X":8.0,"Y":8.47},{"Series":"IV","X":8.0,"Y":7.04},{"Series":"IV","X":8.0,"Y":5.25},{"Series":"IV","X":19.0,"Y":12.5},{"Series":"IV","X":8.0,"Y":5.56},{"Series":"IV","X":8.0,"Y":7.91},{"Series":"IV","X":8.0,"Y":6.89}]},"mark":"circle","encoding":{"column":{"field":"Series"},"x":{"field":"X","type":"quantitative","scale":{"zero":false}},"y":{"field":"Y","type":"quantitative","scale":{"zero":false}},"opacity":{"value":1}}}
```

[Official example](https://github.com/vega/vega-lite/blob/e415f441845e198629f2049b46849ddcfdbf6596/examples/specs/trellis_anscombe.vl.json)

### Data

| Series | X | Y |
| --- | --- | --- |
| I | 10.0 | 8.04 |
| I | 8.0 | 6.95 |
| I | 13.0 | 7.58 |
| I | 9.0 | 8.81 |
| I | 11.0 | 8.33 |
| I | 14.0 | 9.96 |
| I | 6.0 | 7.24 |
| I | 4.0 | 4.26 |
| I | 12.0 | 10.84 |
| I | 7.0 | 4.81 |
| I | 5.0 | 5.68 |
| II | 10.0 | 9.14 |
| II | 8.0 | 8.14 |
| II | 13.0 | 8.74 |
| II | 9.0 | 8.77 |
| II | 11.0 | 9.26 |
| II | 14.0 | 8.1 |
| II | 6.0 | 6.13 |
| II | 4.0 | 3.1 |
| II | 12.0 | 9.13 |
| II | 7.0 | 7.26 |
| II | 5.0 | 4.74 |
| III | 10.0 | 7.46 |
| III | 8.0 | 6.77 |
| III | 13.0 | 12.74 |
| III | 9.0 | 7.11 |
| III | 11.0 | 7.81 |
| III | 14.0 | 8.84 |
| III | 6.0 | 6.08 |
| III | 4.0 | 5.39 |
| III | 12.0 | 8.15 |
| III | 7.0 | 6.42 |
| III | 5.0 | 5.73 |
| IV | 8.0 | 6.58 |
| IV | 8.0 | 5.76 |
| IV | 8.0 | 7.71 |
| IV | 8.0 | 8.84 |
| IV | 8.0 | 8.47 |
| IV | 8.0 | 7.04 |
| IV | 8.0 | 5.25 |
| IV | 19.0 | 12.5 |
| IV | 8.0 | 5.56 |
| IV | 8.0 | 7.91 |
| IV | 8.0 | 6.89 |

## Explore further

Use the Example selector to open the complete offline Gallery. Select Source to inspect every encoding and observation, or choose Stream and Replay to watch each closed fence become a chart. The published specifications retain their upstream appearance rather than applying a new example-app chart theme.
