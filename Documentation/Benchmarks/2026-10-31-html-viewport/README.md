# Recorded viewport and lazy-chat observations

Measured on 2026-10-31 in Release with macOS 27.0.1, Xcode 27.2, Swift 6.4.2, 18 logical processors and 128 GiB RAM. See [environment records](before-environment.txt) and the [validated report](comparison.md).

The faithful baseline is an isolated `949f2f0` archive plus the byte-identical macOS native-remount controller from commit `34f37c7`. The candidate is `34f37c7+working-tree`, identified by the exact [recorded source hashes](recorded-source-hashes.json). Benchmark Swift files and the common controller match across all eight result/failure records. Production source hashes were rechecked against both measured source directories after scoring.

Both builds finished before measurements. The build-and-functional-smoke logs show the reused binaries; scoring used `--skip-build` with the same scratch paths and frozen production/harness sources. No concurrent builds, UI automation or app interactions ran during the final scoring window. Native and HTML scenarios ran sequentially in fresh processes, requesting three passes each. The first pass is first-in-process; subsequent passes reuse framework/allocator caches.

The native controls completed three passes before and after. Both faithful baseline HTML workloads failed the stricter real-readiness guard and are recorded as `.failure.json` plus test logs, without invented timing/memory scores. The candidate completed all three passes in both HTML workloads, with every one of 80 previews visited in both directions, correct native/attachment geometry, source export and offscreen resize/reflow.

[workload.md](workload.md) is the exact generated input: 156,689 UTF-8 bytes, SHA-256 `0fa35d94ee54c60042f83d1cf1b388d340f1606be051f3da60873c6fbc7a4608`. The long message uses 307 chunks of up to 512 bytes with 1 ms cooperative pacing. The chat uses 79 completed public views plus one streamed public view with 512-byte chunks every 50 ms; factory attempts and delivered chunks include cancelled partial replay on lazy reappearance.

Memory is sampled host footprint/RSS from public `task_info`, excluding WebKit helper processes. Weak counts are observed instances, not global allocation hooks. Short-lived peaks can be missed; fixed-delay retained containers do not establish a leak. The lack of a valid full-corpus baseline HTML score prevents a paired HTML latency or memory-saving claim.

Reproduce with the commands in [HTMLViewportBenchmarks.md](../../HTMLViewportBenchmarks.md). Validate these recorded files from this directory with:

```bash
shasum -a 256 -c artifacts.sha256
```
