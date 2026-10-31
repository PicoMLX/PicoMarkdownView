# Vega-Lite Charts

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
