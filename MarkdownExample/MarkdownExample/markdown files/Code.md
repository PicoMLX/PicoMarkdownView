# Code

Language labels select syntax highlighting. Select code alongside the surrounding text, or copy a code block.

## Swift

```swift
func greetAgain(person: String) -> String {
    return "Hello again, " + person + "!"
}
print(greetAgain(person: "Anna"))
```

## Python

```python
@some.decorator(foobar)
def foo(bar):
	pass
```

## TypeScript

```typescript
function getProperty<T, K extends keyof T>(o: T, propertyName: K): T[K] { }

declare function f<T extends boolean>(x: T): T extends true ? string : number;

function assert(condition: any, msg?: string): asserts condition { }
```

## Rust

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

Source: selected [Prism 1.29.0 grammar tests](https://github.com/PrismJS/prism/tree/59e5a3471377057de1f401ba38337aca27b80e03/tests/languages), used under the MIT license.
