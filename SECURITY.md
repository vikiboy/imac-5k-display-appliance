# Security policy

## Support status

This is a personal, hardware-specific derivative with no public release,
support contract, response-time promise, or compatibility commitment. The
owner is not offering general troubleshooting or feature development for other
setups.

Do not send issues introduced by this derivative to the TargetBridge upstream
maintainers. Upstream remains responsible only for its own repository and
releases.

## Current security boundary

The experimental display protocol on TCP port 54321 is not authenticated or
encrypted and carries screen contents. Run it only across a trusted direct
Thunderbolt Bridge link. Do not bind, forward, or expose that port to an
untrusted Wi-Fi, Ethernet, VPN, or public network.

Do not attach raw logs, crash reports, `system_profiler` output, screenshots, or
diagnostic bundles to a public report without redaction. They may contain screen
contents, account names, local paths, hostnames, addresses, serial numbers, and
other device identifiers.

## Reporting a vulnerability

The repository is currently private and is not accepting reports from the
public. If it is made public later, use GitHub's private vulnerability-reporting
channel if that feature is enabled. Do not publish exploit details or private
screen data in a normal issue.

Anyone who forks the project is free to fix and redistribute it under the MIT
license, but should establish their own support and disclosure policy.
