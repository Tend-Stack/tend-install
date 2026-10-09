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

1. A panel release tag is built for `linux/amd64` and `linux/arm64`. The image is
   copied by digest to the public `ghcr.io/tend-stack/tend-host`.
2. Every hour, `publish.yml` reads that package anonymously. Stable takes the
   highest version without a prerelease part, and beta takes the highest version
   of all. A beta tag therefore never changes `stable.json`, and a channel never
   moves to a lower version.
3. The version, the revision, stage 1, `install.sh` and the public key are all
   read from the image at that digest.
4. Signing happens only in the `release` environment, after a maintainer approves
   it. Manifests are re-signed every week, so a valid one is never more than
   about seven days old.
