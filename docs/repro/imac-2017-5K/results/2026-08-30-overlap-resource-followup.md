# Bounded-overlap resource follow-up — 2026-08-30

This 20-minute run is a focused follow-up to the earlier one-hour qualified
failure. It exercised the installed two-slot, whole-frame lossless DPCM
receiver continuously on the exact 2017 27-inch iMac. It is useful evidence,
but its shorter duration does **not** replace the final one-hour release soak.

The privacy-scrubbed source samples are in
[`2026-08-30-overlap-resource-followup.tsv`](2026-08-30-overlap-resource-followup.tsv).
The collector ran for 1,200 seconds at 30-second intervals. The summary below
excludes the first 360 seconds, including a one-time diagnostic-induced
resident-memory step, and uses 29 samples over 839 seconds.

| Endpoint | Mean CPU | Max CPU | First → last RSS | Linear RSS slope | Threads | FDs |
|---|---:|---:|---:|---:|---:|---:|
| MacBook sender | 40.04% | 53.20% | 261,872 → 269,536 KiB | -64.296 MiB/hour | 12–16 | 19 |
| iMac receiver | 47.67% | 55.60% | 150,024 → 150,376 KiB | +1.172 MiB/hour | 8 | 15 |

Both processes remained present in every sample. The installed application,
Application Support, and log sizes stayed exactly flat. Neither machine
reported thermal or performance pressure. The MacBook was connected to AC and
fully charged, so this run does not claim battery energy consumption.

The iMac receiver passed the project's ≤2 MiB/hour short-follow-up RSS gate in
this selected post-warm-up window, but later subwindows are too short and noisy
to establish a bound. A fresh one-hour run on the final binary is still
required. The sender's negative whole-window regression coexisted with ordinary
resident-page steps and is evidence against monotonic growth, not proof of a
precise reclamation rate.

Immediately after the run, macOS `leaks` reported zero leaked allocations and
zero leaked bytes in the receiver. On the sender it reported 14,400 bytes in
288 Foundation/AppIntents `LNDaemonApplicationInterface` XPC reference cycles;
none were a TargetBridge frame, packet, or queue allocation. Because macOS also
marked that process restricted, this result is recorded rather than promoted
to an application-level zero-leak proof. The bounded RSS/FD/thread and storage
measurements remain the primary long-lived-process evidence.

This run used the pre-0.5 presentation counter. Its resource measurements are
valid, but its cadence figures are not used: that build treated
`MTLDrawable.presentedTime == 0` as a successful presentation. Version 0.5
removes that substitution and must supply the final cadence and resource
record.
