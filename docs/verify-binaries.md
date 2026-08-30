# GitHub Build Provenance Attestation

> **Inherited upstream reference — not a verification procedure for this
> derivative.** The text below describes binaries published by
> [`swellweb/targetBridge`](https://github.com/swellweb/targetBridge). This
> private personal derivative has no public release, official artifact
> attestation, or published binary channel. Verify its locally built appliance
> binaries with the source revision and SHA-256 procedure in the
> [2017-iMac reproduction guide](repro/imac-2017-5K/README.md), not with the
> upstream command below.

TargetBridge release binaries are cryptographically signed using **GitHub
Artifact Attestations** (built on Sigstore). This provides a secure,
tamper-proof software supply chain by enabling anyone to verify that the
distributed release ZIP archives were built directly inside our official
GitHub Actions pipeline from the authentic source code.

---

## How It Works

During the release build process, GitHub Actions dynamically requests a
short-lived cryptographic identity token from the GitHub OIDC provider and
signs the build artifacts. The signed attestations are stored in Sigstore's
public transparency log, creating a cryptographically verifiable link between
the source code and the compiled release binaries.

---

## Verifying Release Binaries

To verify that a downloaded TargetBridge release binary is authentic and has
not been tampered with or built from a malicious fork, you can use the
**GitHub CLI (`gh`)**.

### Prerequisites

1. Install the GitHub CLI: `brew install gh`

2. Log in to your GitHub account (optional but recommended):
   ```bash
   gh auth login
   ```

### Verification Command

Run the `gh attestation verify` command on the downloaded ZIP file, specifying
the official repository owner and name:

```bash
gh attestation verify "/path/to/TargetBridge-arm64.app.zip" --repo "swellweb/targetBridge"
```

### Expected Successful Output

If the binary is authentic and was built by the official TargetBridge
pipeline, the command will output a confirmation similar to the following:

```text
Loaded 1 attestation for TargetBridge-arm64.app.zip
✓ Verified 1 attestation
✓ Deposited in public transparency log
✓ Signed by GitHub Actions
✓ Originated from swellweb/targetBridge (ref: refs/tags/v1.0.0)
```

> [!IMPORTANT]
> If verification fails, it indicates that the file was either modified after
> compilation, generated outside the official GitHub Action runners, or
> uploaded from an unauthorized fork. Do not run unverified binaries.
