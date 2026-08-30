# Future publication checklist

The GitHub repository is intentionally private. Opening it to the public is a
separate decision, not an automatic consequence of completing the personal
display setup.

Before changing visibility:

- [ ] Finish the recorded 5K60, reconnect, sleep/wake, and one-hour resource
      acceptance on the exact installed commit.
- [ ] Replace the current arrangement evidence with a clean recapture if any
      unrelated window text remains visible, then update
      `docs/ASSET-PROVENANCE.md`.
- [ ] Audit the complete Git history for names, local-hostname email addresses,
      paths, hostnames, IP addresses, serial numbers, and old visual assets.
- [ ] Decide whether to rewrite the three private development commits whose
      author email contains a local hostname (`82561b4`, `c24be82`, `4ef54ee`).
      Do not rewrite shared history casually; make an explicit, backed-up
      publication copy if needed.
- [ ] Decide whether the public repository should preserve inherited history or
      use a clean-root export. Preserving history gives the strongest authorship
      record; a clean-root export avoids redistributing historical upstream
      branding assets that are no longer in the current tree.
- [ ] Re-run secret, binary, image-metadata, broken-link, license, and NOTICE
      checks against the exact publication commit.
- [ ] Keep GitHub Issues and Discussions disabled unless the owner deliberately
      chooses to accept community traffic; there is no support SLA.
- [ ] Add a manual, reviewed packaging workflow only after app naming, embedded
      license notices, signing, notarization, and checksums are final.
- [ ] Verify the repository is still MIT-licensed and that “personal project”
      describes maintenance posture rather than restricting the freedoms the
      MIT license grants.
- [ ] Re-read `README.md`, `NOTICE.md`, `SECURITY.md`, and `CONTRIBUTING.md` from
      a new user's perspective before making the visibility change.

No public release should contain raw logs, crash reports, dSYMs,
`system_profiler` output, unredacted screenshots, or live screen captures.
