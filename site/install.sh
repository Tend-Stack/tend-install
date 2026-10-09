#!/usr/bin/env bash
# Tend installer, stage 0: the only part of the installer you have to trust.
#   curl -fsSL https://get.tend.host/install.sh | sudo bash
# It changes nothing here. It downloads the signed release manifest, checks its Ed25519
# signature against the key pinned below, downloads the full installer (stage 1) the manifest
# names, checks its SHA-256, and runs it. Stage 1 pulls the panel image by the digest the
# manifest pins, so everything after this script is covered by the signature, whichever
# mirror served it. Options pass through: ... | sudo bash -s -- --local   (or --public).
# TEND_CHANNEL=stable|beta picks the channel. Verify by hand: https://tend.host/docs/install
set -euo pipefail
# Release signing keys (base64 DER SubjectPublicKeyInfo); rotation adds a second line.
# Key 1, key_id a11d1c3fe5f86c14 (docs/agent/panel-release-keys.md).
TEND_RELEASE_KEYS=("MCowBQYDK2VwAyEA6mqh9euEIZV1KSTZzWBJ8xaluXkPBt5GGg+CuNLbuBM=")
CHANNEL="${TEND_CHANNEL:-stable}"
BASE="${TEND_INSTALL_BASE:-https://get.tend.host}"
FALLBACK="https://github.com/Tend-Stack/tend-install/releases/latest/download"
die() { echo "Tend install: $*" >&2; echo "Nothing was changed on this machine." >&2; exit 1; }
# --- begin verifier: identical to internal/panelrelease/testdata/verify-manifest.sh ---
tend_verify_manifest() {
  local work rc
  work="$(mktemp -d)" || { echo "Could not create a temporary directory." >&2; return 1; }
  _tend_verify_manifest_in "$work" "$@"
  rc=$?
  rm -rf -- "$work"
  return "$rc"
}
# _tend_manifest_field <manifest> <name> <pattern>: prints the value of the one
# line `  "<name>": <value>[,]` with its quotes removed, if it matches <pattern>.
_tend_manifest_field() {
  local line value
  [ "$(grep -c -E "^  \"$2\": " "$1")" -eq 1 ] || return 1
  line="$(grep -E "^  \"$2\": " "$1")"
  value="${line#  \""$2"\": }"
  value="${value%,}"
  value="${value#\"}"
  value="${value%\"}"
  [[ $value =~ $3 ]] || return 1
  printf '%s' "$value"
}
_tend_verify_manifest_in() {
  local work="$1" manifest="$2" sig="$3" channel="$4" platform="$5" now="$6"
  shift 6
  local key matched="" id size
  local re_int='^(0|[1-9][0-9]{0,11})$'
  local re_version='^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})(-(alpha|beta|rc)\.(0|[1-9][0-9]{0,5}))?$'
  local re_hex16='^[0-9a-f]{16}$' re_hex40='^[0-9a-f]{40}$' re_hex64='^[0-9a-f]{64}$'
  local re_digest='^sha256:[0-9a-f]{64}$'
  local re_image='^[a-z0-9]+([.-][a-z0-9]+)*(:[0-9]{1,5})?(/[a-z0-9]+([._-][a-z0-9]+)*)+$'
  local re_url='^https://[a-z0-9]+([.-][a-z0-9]+)*(:[0-9]{1,5})?(/[A-Za-z0-9._~-]+)+$'
  local schema got_channel platforms
  case "$channel" in stable | beta) ;; *) echo "Unknown release channel." >&2; return 1 ;; esac
  case "$platform" in linux/amd64 | linux/arm64) ;; *) echo "This processor type is not supported." >&2; return 1 ;; esac
  [[ $now =~ $re_int ]] || { echo "Could not read the system clock." >&2; return 1; }
  # 1. Shape of the two files, then the signature over the raw bytes.
  size="$(wc -c < "$manifest")" || { echo "Could not read the release manifest." >&2; return 1; }
  { [ "$size" -ge 1 ] && [ "$size" -le 4096 ]; } || { echo "The release manifest has an impossible size." >&2; return 1; }
  if [ "$(wc -c < "$sig")" -ne 89 ] || ! base64 -d < "$sig" > "$work/sig.bin" 2>/dev/null ||
    [ "$(wc -c < "$work/sig.bin")" -ne 64 ]; then
    echo "The release signature is malformed." >&2; return 1
  fi
  { printf 'tend-panel-release-v1\n'; cat -- "$manifest"; } > "$work/message" ||
    { echo "Could not read the release manifest." >&2; return 1; }
  for key in "$@"; do
    [[ $key =~ ^MCowBQYDK2VwAyEA[A-Za-z0-9+/]{43}=$ ]] || continue
    printf -- '-----BEGIN PUBLIC KEY-----\n%s\n-----END PUBLIC KEY-----\n' "$key" > "$work/key.pem"
    if openssl pkeyutl -verify -pubin -inkey "$work/key.pem" -rawin \
      -in "$work/message" -sigfile "$work/sig.bin" > /dev/null 2>&1; then
      matched="$key"
      break
    fi
  done
  [ -n "$matched" ] || { echo "The release manifest is not signed by a Tend release key." >&2; return 1; }
  id="$(printf '%s' "$matched" | base64 -d | tail -c 32 | sha256sum | cut -c1-16)"
  # 2. Only now read the fields of the signed, canonical layout.
  [ "$(wc -l < "$manifest")" -eq 15 ] || { echo "The release manifest has an unexpected layout." >&2; return 1; }
  # shellcheck disable=SC2015,SC2034
  schema="$(_tend_manifest_field "$manifest" schema '^1$')" &&
    TEND_M_KEY_ID="$(_tend_manifest_field "$manifest" key_id "$re_hex16")" &&
    got_channel="$(_tend_manifest_field "$manifest" channel '^(stable|beta)$')" &&
    TEND_M_VERSION="$(_tend_manifest_field "$manifest" version "$re_version")" &&
    TEND_M_REVISION="$(_tend_manifest_field "$manifest" revision "$re_hex40")" &&
    TEND_M_IMAGE="$(_tend_manifest_field "$manifest" image "$re_image")" &&
    TEND_M_IMAGE_DIGEST="$(_tend_manifest_field "$manifest" image_digest "$re_digest")" &&
    TEND_M_INSTALLER_URL="$(_tend_manifest_field "$manifest" installer_url "$re_url")" &&
    TEND_M_INSTALLER_SHA256="$(_tend_manifest_field "$manifest" installer_sha256 "$re_hex64")" &&
    TEND_M_MIN_UPGRADE_FROM="$(_tend_manifest_field "$manifest" min_upgrade_from "$re_version")" &&
    TEND_M_PUBLISHED_AT="$(_tend_manifest_field "$manifest" published_at "$re_int")" &&
    TEND_M_EXPIRES_AT="$(_tend_manifest_field "$manifest" expires_at "$re_int")" &&
    platforms="$(_tend_manifest_field "$manifest" platforms '^\[("linux/amd64"|"linux/arm64"|"linux/amd64", "linux/arm64")\]$')" ||
    { echo "The release manifest has an invalid field." >&2; return 1; }
  [ "$schema" = 1 ] || { echo "The release manifest uses an unknown format." >&2; return 1; }
  [ "$TEND_M_KEY_ID" = "$id" ] || { echo "The release manifest names a different signing key." >&2; return 1; }
  [ "$got_channel" = "$channel" ] || { echo "The release manifest is for another channel." >&2; return 1; }
  if [ "$channel" = stable ] && [[ $TEND_M_VERSION == *-* ]]; then echo "The stable channel cannot carry a prerelease." >&2; return 1; fi
  if [ "$TEND_M_EXPIRES_AT" -le "$TEND_M_PUBLISHED_AT" ] || [ $((TEND_M_EXPIRES_AT - TEND_M_PUBLISHED_AT)) -gt 2592000 ]; then
    echo "The release manifest claims an impossible validity window." >&2; return 1
  fi
  if [ "$now" -lt $((TEND_M_PUBLISHED_AT - 600)) ] || [ "$now" -ge "$TEND_M_EXPIRES_AT" ]; then
    echo "The release manifest has expired or is not valid yet (check this machine's clock)." >&2; return 1
  fi
  [[ $platforms == *"\"$platform\""* ]] || { echo "This release has no image for this processor type." >&2; return 1; }
  return 0
}
# --- end verifier ---
fetch() { # fetch <file> <destination>: the first source that answers wins
  local src
  for src in "${SOURCES[@]}"; do
    curl -fsSL --retry 2 --connect-timeout 10 --max-time 120 "$src/$1" -o "$2" 2> /dev/null && return 0
  done
  return 1
}
[ "$(uname -s)" = Linux ] || die "Tend installs on Linux only."
for tool in curl openssl sha256sum base64; do command -v "$tool" > /dev/null || die "$tool is required."; done
[[ "$(openssl version)" == "OpenSSL 3"* ]] || die "OpenSSL 3 is required (this has: $(openssl version | cut -d' ' -f1-2))."
case "$(uname -m)" in
  x86_64) PLATFORM=linux/amd64 ;;
  aarch64 | arm64) PLATFORM=linux/arm64 ;;
  *) die "this processor type is not supported." ;;
esac
SOURCES=("$BASE/v1")
if [ -n "${TEND_INSTALL_BASE:-}" ]; then
  echo "Using the install source $BASE (not the public one)." >&2
else
  SOURCES+=("$FALLBACK")
fi
if [ -n "${TEND_INSTALL_DEV_KEY:-}" ]; then # a test key is accepted only behind an explicit development switch
  [ "${TEND_INSTALL_DEV:-}" = 1 ] || die "TEND_INSTALL_DEV_KEY is for development only; it needs TEND_INSTALL_DEV=1."
  echo "DEVELOPMENT: trusting the test key from TEND_INSTALL_DEV_KEY, not the Tend release key." >&2
  TEND_RELEASE_KEYS=("$TEND_INSTALL_DEV_KEY")
fi
[[ "${TEND_RELEASE_KEYS[*]}" == *MCowBQYDK2VwAyEA* ]] ||
  die "this copy has no release key pinned; get the installer from https://tend.host/docs/install."
[ "$(id -u)" -eq 0 ] || die "this needs root. Run: curl -fsSL https://get.tend.host/install.sh | sudo bash"
WORK="$(mktemp -d)"
trap '[ -n "${TEND_STAGE_KEEP:-}" ] || rm -rf "$WORK"' EXIT
for f in "$CHANNEL.json" "$CHANNEL.json.sig"; do
  fetch "$f" "$WORK/$f" || die "could not download $f; check the internet connection."
done
tend_verify_manifest "$WORK/$CHANNEL.json" "$WORK/$CHANNEL.json.sig" "$CHANNEL" "$PLATFORM" "$(date +%s)" \
  "${TEND_RELEASE_KEYS[@]}" || die "the release manifest did not verify, so nothing was installed."
# Stage 1: the signed URL first, then the sources above. Only the SHA-256 decides what runs.
[ -n "${TEND_INSTALL_BASE:-}" ] || SOURCES=("${TEND_M_INSTALLER_URL%/*}" "${SOURCES[@]}")
fetch "${TEND_M_INSTALLER_URL##*/}" "$WORK/install-panel.sh" || die "could not download the installer for version $TEND_M_VERSION."
[ "$(sha256sum < "$WORK/install-panel.sh" | cut -d' ' -f1)" = "$TEND_M_INSTALLER_SHA256" ] ||
  die "the downloaded installer does not match the signed release (checksum mismatch)."
export TEND_CHANNEL="$CHANNEL" TEND_M_PLATFORM="$PLATFORM" TEND_STAGE_DIR="$WORK" TEND_M_KEY_ID TEND_M_VERSION TEND_M_REVISION \
  TEND_M_IMAGE TEND_M_IMAGE_DIGEST TEND_M_MIN_UPGRADE_FROM TEND_M_PUBLISHED_AT TEND_M_EXPIRES_AT
TEND_STAGE_KEEP=1 exec bash "$WORK/install-panel.sh" "$@"
