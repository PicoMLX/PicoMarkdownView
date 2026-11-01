# Code

Explore syntax highlighting, selectable code, and source copying in a document with realistic examples. The examples below share a small weather-station dataset across several languages.

The practical examples are authored for PicoMarkdownView. The final section contains separate, pinned Prism grammar-test excerpts.

## Swift: decode and transform structured data

Decode a small payload, filter its values, and format the results. The same document can contain code, explanatory prose, and selectable output.

```swift
import Foundation

struct Reading: Decodable {
    let station: String
    let celsius: Double
}

let payload = #"""
[
  {"station": "Harbor", "celsius": 18.4},
  {"station": "Hilltop", "celsius": 21.0},
  {"station": "Forest", "celsius": 16.8}
]
"""#
let readings = try JSONDecoder().decode([Reading].self, from: Data(payload.utf8))
let warmest = readings.filter { $0.celsius >= 18 }.sorted { $0.celsius > $1.celsius }

for reading in warmest {
    print("\(reading.station): \(reading.celsius) °C")
}
```

## Python: summarize a data pipeline

Group readings by station, discard missing values, and calculate a rounded average with the standard library.

```python
from collections import defaultdict
from statistics import mean

rows = [("Harbor", 18.4), ("Hilltop", 21.0), ("Harbor", 19.2),
        ("Forest", None), ("Hilltop", 20.6)]

def summarize(readings):
    groups = defaultdict(list)
    for station, temperature in readings:
        if temperature is not None:
            groups[station].append(temperature)
    return {station: round(mean(values), 1)
            for station, values in sorted(groups.items())}

for station, average in summarize(rows).items():
    print(f"{station:8} {average:4.1f} °C")
```

## TypeScript: reusable generic grouping

Keep the item type and key type while grouping structured records into a map.

```typescript
type Reading = { station: string; celsius: number };

function groupBy<T, K>(items: readonly T[], key: (item: T) => K): Map<K, T[]> {
  const groups = new Map<K, T[]>();
  for (const item of items) {
    const bucket = groups.get(key(item)) ?? [];
    bucket.push(item);
    groups.set(key(item), bucket);
  }
  return groups;
}

const readings: Reading[] = [
  { station: "Harbor", celsius: 18.4 },
  { station: "Hilltop", celsius: 21.0 },
  { station: "Harbor", celsius: 19.2 },
];
for (const [station, values] of groupBy(readings, item => item.station)) {
  console.log(`${station}: ${values.length} readings`);
}
```

## Rust: handle valid and invalid input

A Result carries either the converted temperature or the original parse error; a match handles both outcomes.

```rust
use std::num::ParseFloatError;

fn fahrenheit(input: &str) -> Result<f64, ParseFloatError> {
    let celsius: f64 = input.trim().parse()?;
    Ok(celsius * 9.0 / 5.0 + 32.0)
}

fn main() {
    for input in ["18.4", "21.0", "offline"] {
        match fahrenheit(input) {
            Ok(value) => println!("{input} °C = {value:.1} °F"),
            Err(error) => eprintln!("Cannot convert {input:?}: {error}"),
        }
    }
}
```

## JSON: a nested configuration

Strings, numbers, arrays, booleans, and null values share one highlighted block.

```json
{
  "workspace": "Field Notes",
  "refreshSeconds": 30,
  "units": { "temperature": "celsius", "distance": "meters" },
  "stations": [
    { "id": "harbor", "enabled": true, "tags": ["coastal", "outdoor"] },
    { "id": "hilltop", "enabled": true, "tags": ["outdoor"] }
  ],
  "alert": { "above": 28.5, "notify": ["dashboard", "email"] },
  "lastSync": null
}
```

## SQL: aggregate the same readings

Create a small in-memory dataset, then group and filter it with a common table expression.

```sql
CREATE TABLE readings (station TEXT, celsius REAL);
INSERT INTO readings VALUES
  ('Harbor', 18.4), ('Harbor', 19.2),
  ('Hilltop', 21.0), ('Hilltop', 20.6);

WITH summary AS (
  SELECT station, COUNT(*) AS samples, ROUND(AVG(celsius), 1) AS average
  FROM readings
  GROUP BY station
)
SELECT station, samples, average
FROM summary WHERE average >= 19
ORDER BY average DESC;
```

## Shell: write and summarize a local file

A temporary file keeps this example self-contained. Quoted variables and a cleanup trap make the flow easy to follow.

```bash
#!/usr/bin/env bash
set -euo pipefail
workspace="$(mktemp -d)"
trap 'rm -rf "$workspace"' EXIT
cat > "$workspace/readings.csv" <<'CSV'
station,celsius
Harbor,18.4
Hilltop,21.0
Forest,16.8
CSV

awk -F, 'NR > 1 { printf "%-8s %4.1f °C\n", $1, $2 }' "$workspace/readings.csv"
```

## Upstream grammar reference

These compact excerpts come directly from Prism's tests. They exercise particular grammar rules; they are not standalone programs. The first two also place code inside a quote and a list.

### Swift

> A function can be quoted alongside its explanation.
>
> ```swift
> func greetAgain(person: String) -> String {
>     return "Hello again, " + person + "!"
> }
> print(greetAgain(person: "Anna"))
> ```

### Python

- A decorator and the function it wraps:

    ```python
    @some.decorator(foobar)
    def foo(bar):
        pass
    ```

### TypeScript

```typescript
function getProperty<T, K extends keyof T>(o: T, propertyName: K): T[K] { }

declare function f<T extends boolean>(x: T): T extends true ? string : number;

function assert(condition: any, msg?: string): asserts condition { }
```

### Rust

```rust
macro_rules! write_html {
	($w:expr, ) => (());

	($w:expr, $e:tt) => (write!($w, "{}", $e));

	($w:expr, $tag:ident [ $($inner:tt)* ] $($rest:tt)*) => {{
		write!($w, "<{}>", stringify!($tag));
		write_html!($w, $($inner)*);
		write!($w, "</{}>", stringify!($tag));
		write_html!($w, $($rest)*);
	}};
}
```

Reference source: selected [Prism 1.29.0 grammar tests](https://github.com/PrismJS/prism/tree/59e5a3471377057de1f401ba38337aca27b80e03/tests/languages), used under the MIT license. Practical examples and document composition are PicoMarkdownView additions.
