# tend-install

The one-line installer for [Tend](https://tend.host) and the signed release
channels it reads.

```bash
curl -fsSL https://get.tend.host/install.sh | sudo bash
```

## What is here

- `site/` is exactly what `https://get.tend.host` serves:
  - `install.sh`: stage 0, about 150 readable lines. It downloads the channel
    manifest, checks its Ed25519 signature against the key written inside it,
    downloads the full installer the manifest names, checks its SHA-256, and runs it.
  - `install.sh.sha256`, `install.sh.sig`: its checksum and its signature.
  - `tend-panel-release-1.pub.pem`: the release public key.
  - `v1/stable.json`, `v1/beta.json` and their `.sig`: the signed channel manifests.
    Each pins the panel image `ghcr.io/tend-stack/tend-host` by digest and the
    stage 1 installer by SHA-256, and expires after 30 days.
  - `v1/install-panel-<version>.sh`: stage 1 for each version a channel names.
  - `SHA256SUMS`: checksums of all of the above.
- The `channels` release carries the same files. `install.sh` falls back to it
  when get.tend.host does not answer.
- `panel-v<version>` releases keep every stage 1 that was ever published.

Everything in `site/` is written by `.github/workflows/publish.yml`. Nobody edits
it by hand. The code in this repository is maintained in the Tend panel
repository and copied here.

## Verify before you run

```bash
curl -fsSLO https://get.tend.host/install.sh
curl -fsSLO https://get.tend.host/install.sh.sig
curl -fsSLO https://get.tend.host/tend-panel-release-1.pub.pem
{ printf 'tend-install-script-v1\n'; cat install.sh; } > message
base64 -d install.sh.sig > signature.bin
openssl pkeyutl -verify -pubin -inkey tend-panel-release-1.pub.pem -rawin -in message -sigfile signature.bin
less install.sh
sudo bash install.sh
```

A manifest is checked the same way, using the prefix `tend-panel-release-v1`
instead of `tend-install-script-v1`. Also check its `expires_at` and its
`channel`, as `install.sh` does.

## How a release gets here

1. A panel release tag, signed with the maintainer's SSH key, is built for `linux/amd64`
   and `linux/arm64` by the panel's GitHub workflow, which also publishes a proof: the
   signed tag object and a Sigstore signature, made by that workflow run, over the
   statement {version, revision, image digest}.
2. Every 15 minutes, `publish.yml` copies a version and its proof to the public
   `ghcr.io/tend-stack/tend-host` by digest, but only if the proof verifies: the tag
   signature checks against `release-tag-signers` (the maintainer's pinned key), and
   the Sigstore certificate names the panel's release workflow, that tag and that
   commit. Then it reads that package anonymously. Stable takes the highest version
   without a prerelease part, and beta takes the highest version of all. A beta tag
   therefore never changes `stable.json`, and a channel never moves to a lower version.
3. The version, the revision, stage 1, `install.sh` and the public key are all
   read from the image at that digest.
4. Nobody approves a run; the signed tag is the approval. The `sign` job checks the
   proof again and signs only in the `release` environment. Manifests are re-signed
   every week, so a valid one is never more than about seven days old. A release
   whose proof does not verify is refused and never blocks that re-sign.
5. A refusal, a failed run, or a change to the code on `main` opens a GitHub issue
   in this repository (one per title; no repeat comments). `site/` is the only part
   of `main` the workflow changes, and it pushes with a deploy key.
