# Contributing and forking

This repository is maintained for one personal hardware setup. There is no
support, review, merge, release, or compatibility SLA. Please do not interpret
the existence of the source as a promise that a feature request or hardware
report will be investigated.

The MIT license allows you to fork, modify, and redistribute the code. A fork
is the most reliable way to adapt it to another iMac, GPU, macOS version, cable,
or performance target.

If this repository becomes public and accepts pull requests later, useful
changes should:

1. identify the exact sender and receiver hardware and macOS versions;
2. preserve [LICENSE](LICENSE), [NOTICE.md](NOTICE.md), and code provenance;
3. include bounded tests or reproducible hardware evidence;
4. report point geometry, backing pixels, codec, frame rate, duration, and
   resource trends rather than relying on a “looks good” claim;
5. avoid unbounded queues, frame dumps, growing logs, or silent fidelity
   downgrades;
6. remove names, paths, hostnames, addresses, identifiers, and private screen
   contents from evidence;
7. use original visuals and update [docs/ASSET-PROVENANCE.md](docs/ASSET-PROVENANCE.md);
8. avoid sending derivative-specific issues to TargetBridge's upstream
   maintainers.

Fork maintainers should choose their own project identity, signing credentials,
release process, disclosure policy, and support posture. They remain free to
credit this derivative in addition to the required upstream notices.
