Below are very small, self‑contained examples of a **bubble‑sort** implementation in each of the requested languages.
All examples sort an array (or slice/Vector) of integers in ascending order and print the sorted result.

```basic
' BASIC – using simple array and loops (QBASIC‑style)

DECLARE SUB BubbleSort (A() AS INTEGER, N AS INTEGER)

SUB BubbleSort (A() AS INTEGER, N AS INTEGER)
    DIM i AS INTEGER, j AS INTEGER, temp AS INTEGER
    FOR i = 1 TO N - 1
        FOR j = 1 TO N - i
            IF A(j) > A(j + 1) THEN
                temp = A(j)
                A(j) = A(j + 1)
                A(j + 1) = temp
            END IF
        NEXT j
    NEXT i
END SUB

' Example usage
DIM arr(5) AS INTEGER
arr(1) = 5: arr(2) = 3: arr(3) = 8: arr(4) = 1: arr(5) = 9
CALL BubbleSort(arr(), 5)

FOR i = 1 TO 5
    PRINT arr(i);
NEXT i
PRINT
```

```pascal
{ Pascal – bubble sort }
program SimpleSort;

uses SysUtils;

procedure BubbleSort(var A: array of Integer);
var
  i, j, temp: Integer;
begin
  for i := Low(A) to High(A)-1 do
    for j := Low(A) to High(A)-i do
      if A[j] > A[j+1] then
      begin
        temp := A[j];
        A[j] := A[j+1];
        A[j+1] := temp;
      end;
end;

var
  arr: array[1..5] of Integer = (5, 3, 8, 1, 9);
  i: Integer;
begin
  BubbleSort(arr);
  for i := Low(arr) to High(arr) do
    WriteLn(arr[i]);
end.
```

```c
/* C – bubble sort */
#include <stdio.h>

void bubbleSort(int *arr, int n) {
    int i, j, temp;
    for (i = 0; i < n-1; i++)
        for (j = 0; j < n-i-1; j++)
            if (arr[j] > arr[j+1]) {
                temp = arr[j];
                arr[j] = arr[j+1];
                arr[j+1] = temp;
            }
}

int main(void) {
    int arr[] = {5, 3, 8, 1, 9};
    int n = sizeof arr / sizeof arr[0];
    bubbleSort(arr, n);
    for (int i = 0; i < n; i++)
        printf("%d ", arr[i]);
    printf("\n");
    return 0;
}
```

```cpp
// C++ – bubble sort
#include <iostream>
#include <vector>

void bubbleSort(std::vector<int>& v) {
    for (size_t i = 0; i < v.size()-1; ++i)
        for (size_t j = 0; j < v.size()-i-1; ++j)
            if (v[j] > v[j+1])
                std::swap(v[j], v[j+1]);
}

int main() {
    std::vector<int> vec = {5, 3, 8, 1, 9};
    bubbleSort(vec);
    for (int x : vec) std::cout << x << ' ';
    std::cout << '\n';
}
```

```typescript
// TypeScript – bubble sort
function bubbleSort(arr: number[]): number[] {
    const n = arr.length;
    for (let i = 0; i < n - 1; i++) {
        for (let j = 0; j < n - i - 1; j++) {
            if (arr[j] > arr[j + 1]) {
                [arr[j], arr[j + 1]] = [arr[j + 1], arr[j]];
            }
        }
    }
    return arr;
}

const data = [5, 3, 8, 1, 9];
console.log(bubbleSort(data));  // [1,3,5,8,9]
```

```rust
// Rust – bubble sort
fn bubble_sort(arr: &mut [i32]) {
    let n = arr.len();
    for i in 0..n-1 {
        for j in 0..n-i-1 {
            if arr[j] > arr[j+1] {
                arr.swap(j, j+1);
            }
        }
    }
}

fn main() {
    let mut v = vec![5, 3, 8, 1, 9];
    bubble_sort(&mut v);
    println!("{:?}", v);  // [1,3,5,8,9]
}
```

```swift
// Swift – bubble sort
import Foundation

func bubbleSort(_ arr: inout [Int]) {
    let n = arr.count
    for i in 0..<n-1 {
        for j in 0..<n-i-1 {
            if arr[j] > arr[j+1] {
                arr.swapAt(j, j+1)
            }
        }
    }
}

var numbers = [5, 3, 8, 1, 9]
bubbleSort(&numbers)
print(numbers)  // [1, 3, 5, 8, 9]
```

```python
# Python – bubble sort
def bubble_sort(arr):
    n = len(arr)
    for i in range(n-1):
        for j in range(n-i-1):
            if arr[j] > arr[j+1]:
                arr[j], arr[j+1] = arr[j+1], arr[j]
    return arr

data = [5, 3, 8, 1, 9]
print(bubble_sort(data))  # [1, 3, 5, 8, 9]
```
