# shellcheck shell=bash
# Stage-0 verification of a signed Tend panel channel manifest.
#
# This is the exact function install.sh (stage 0) embeds. It is kept here, next
# to the Go codec in internal/panelrelease, so the Go tests can prove that bash
# with OpenSSL 3 and Go accept and refuse the same bytes.
#
#   tend_verify_manifest <manifest> <sig> <channel> <platform> <now> <key>...
#
# <key> is a pinned public key as the one-line base64 of its DER
# SubjectPublicKeyInfo (the middle line of `openssl pkey -pubout`, 60
# characters, starting MCowBQYDK2VwAyEA). install.sh passes its embedded
# constants; nothing here reads a key from the environment.
#
# Order matters: the signature is checked over "tend-panel-release-v1\n" plus
# the raw file bytes before a single field is read. A manifest that verifies was
# written by the Go signer, which only writes the canonical layout (one field
# per line, quote-free values), so plain parameter expansion reads it safely.
# Every value is still checked against its pattern afterwards.
#
# On success it returns 0 and sets TEND_M_KEY_ID, TEND_M_VERSION,
# TEND_M_REVISION, TEND_M_IMAGE, TEND_M_IMAGE_DIGEST, TEND_M_INSTALLER_URL,
# TEND_M_INSTALLER_SHA256, TEND_M_MIN_UPGRADE_FROM, TEND_M_PUBLISHED_AT and
# TEND_M_EXPIRES_AT. On failure it prints one plain sentence on stderr and
# returns 1 (some TEND_M_* may then be set: callers must stop, not read them). Needs bash, coreutils (mktemp, wc, base64, tail, sha256sum, cut),
# grep and OpenSSL 3.

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
