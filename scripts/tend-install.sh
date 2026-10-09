#!/usr/bin/env bash
# Tend-Stack/tend-install release tool: discovers panel releases in the public
# image package, signs the channel manifests, and lays out what get.tend.host
# serves. Source of truth: deploy/tend-install/ in the panel repository
# (docs/agent/installer.md, "Publishing a release"); this repository's copy is
# replaced from there, never edited here.
#
#   tend-install.sh plan    --site site --out plan [--now <unix>] [--force-resign]
#   tend-install.sh sign    --site site --plan plan [--now <unix>]      # needs TEND_PANEL_RELEASE_KEY
#   tend-install.sh publish --site site --plan plan                      # git + gh, GITHUB_TOKEN
#
# Everything a release contains is derived from one public image digest: the
# version is its tag, the revision is its label, and stage 1, install.sh, the
# public key and min-upgrade-from are read from /srv/scripts/install/ inside
# its linux/amd64 image. Nothing here needs a credential except `sign`.
#
# Rules: stable takes the highest version without a prerelease part; beta takes
# the highest version of all, so a beta tag can never move stable.json. A
# channel never goes back to a lower version, and a version tag that now names
# another digest is refused. A manifest older than seven days is re-signed with
# the same fields (manifests live 30 days).
set -euo pipefail

IMAGE="${TEND_INSTALL_IMAGE:-ghcr.io/tend-stack/tend-host}"
SCHEME="${TEND_REGISTRY_SCHEME:-https}"
BASE_URL="${TEND_INSTALL_URL:-https://get.tend.host}"
# The release key pinned in install.sh (docs/agent/panel-release-keys.md).
RELEASE_SPKI="MCowBQYDK2VwAyEA6mqh9euEIZV1KSTZzWBJ8xaluXkPBt5GGg+CuNLbuBM="
# A dry run signs with a throwaway key and says so; it never publishes.
SIGNING_SPKI="${TEND_INSTALL_DRY_RUN_SPKI:-$RELEASE_SPKI}"
LIFETIME=$((30 * 24 * 3600))
RESIGN_AFTER=$((7 * 24 * 3600))
PLATFORMS=(linux/amd64 linux/arm64)
CHANNELS=(stable beta)
WANT=(install.sh install-panel.sh tend-panel-release-1.pub.pem min-upgrade-from)
SCRIPT_DOMAIN="tend-install-script-v1"
RE_VERSION='^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})(-(alpha|beta|rc)\.(0|[1-9][0-9]{0,5}))?$'
RE_HEX40='^[0-9a-f]{40}$'
RE_HEX64='^[0-9a-f]{64}$'
RE_DIGEST='^sha256:[0-9a-f]{64}$'

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=verify-manifest.sh
. "$here/verify-manifest.sh"

die() { echo "tend-install: $*" >&2; exit 1; }
say() { echo "$*" >&2; }

# ---- registry (anonymous reads of the public package) ----
REG_HOST="${IMAGE%%/*}"
REG_PATH="${IMAGE#*/}"
REG_TOKEN=""

# reg_get <path after /v2/<repo>/> <output file> [accept]: GET with one bearer challenge answered anonymously.
reg_get() {
  local url="$SCHEME://$REG_HOST/v2/$REG_PATH/$1" out="$2" accept="${3:-}" hdr code challenge realm service scope
  local args=(-sS -L --retry 2 --connect-timeout 10 --max-time 600 -o "$out" -w '%{http_code}')
  [[ -n $accept ]] && args+=(-H "Accept: $accept")
  hdr="$(mktemp)"
  if [[ -n $REG_TOKEN ]]; then
    code="$(curl "${args[@]}" -D "$hdr" -H "Authorization: Bearer $REG_TOKEN" "$url")"
  else
    code="$(curl "${args[@]}" -D "$hdr" "$url")"
  fi
  if [[ $code == 401 ]]; then
    challenge="$(tr -d '\r' < "$hdr" | sed -n 's/^[Ww][Ww][Ww]-[Aa]uthenticate: *[Bb]earer //p' | head -n 1)"
    realm="$(sed -n 's/.*realm="\([^"]*\)".*/\1/p' <<< "$challenge")"
    service="$(sed -n 's/.*service="\([^"]*\)".*/\1/p' <<< "$challenge")"
    scope="repository:$REG_PATH:pull"
    [[ -n $realm ]] || { rm -f "$hdr"; die "the registry asked for authentication this tool cannot answer ($url)."; }
    REG_TOKEN="$(curl -fsS --max-time 30 -G "$realm" --data-urlencode "service=$service" --data-urlencode "scope=$scope" |
      jq -r '.token // .access_token // empty')" || true
    [[ -n $REG_TOKEN ]] || { rm -f "$hdr"; die "no anonymous token for $IMAGE: is the package public?"; }
    code="$(curl "${args[@]}" -D "$hdr" -H "Authorization: Bearer $REG_TOKEN" "$url")"
  fi
  rm -f "$hdr"
  [[ $code == 200 ]] || { say "GET $url answered $code"; return 1; }
}

ACCEPT_INDEX="application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json"
ACCEPT_IMAGE="application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json"

sha256_of() { sha256sum < "$1" | cut -d' ' -f1; }

# version_key <version>: a string that sorts like the version (prereleases below their release).
version_key() {
  [[ $1 =~ $RE_VERSION ]] || return 1
  local rank=3
  case "${BASH_REMATCH[5]}" in alpha) rank=0 ;; beta) rank=1 ;; rc) rank=2 ;; esac
  printf '%06d.%06d.%06d.%d.%06d\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "$rank" "${BASH_REMATCH[6]:-0}"
}
version_lt() { [[ "$(version_key "$1")" < "$(version_key "$2")" ]]; }

# highest <stable|beta> < tags: the channel's candidate version, or nothing.
highest() {
  local tag best="" key bestkey=""
  while IFS= read -r tag; do
    key="$(version_key "$tag")" || continue
    [[ $1 == stable && $tag == *-* ]] && continue
    if [[ -z $best || $key > $bestkey ]]; then best="$tag" bestkey="$key"; fi
  done
  printf '%s' "$best"
}

# inspect_release <version> <dir>: resolves the tag, checks the index, and
# extracts the install files from the linux/amd64 image into <dir>. Sets
# R_DIGEST and R_REVISION.
inspect_release() {
  local version="$1" dir="$2" work p child config layer mt i found rev
  work="$(mktemp -d)"
  reg_get "manifests/$version" "$work/index.json" "$ACCEPT_INDEX" || die "cannot read $IMAGE:$version."
  R_DIGEST="sha256:$(sha256_of "$work/index.json")"
  jq -e '.manifests | type == "array"' "$work/index.json" > /dev/null 2>&1 || die "$IMAGE:$version is not a multi-platform index."
  for p in "${PLATFORMS[@]}"; do
    jq -e --arg os "${p%/*}" --arg arch "${p#*/}" \
      'any(.manifests[]; .platform.os == $os and .platform.architecture == $arch)' "$work/index.json" > /dev/null ||
      die "$IMAGE:$version has no $p image."
  done
  # Every platform's image config must carry the revision and version labels the
  # manifest will name: an installed panel refuses an image whose labels differ,
  # on whichever architecture it runs, so a mismatch is caught here, before signing.
  R_REVISION=""
  for p in "${PLATFORMS[@]}"; do
    child="$(jq -r --arg os "${p%/*}" --arg arch "${p#*/}" 'first(.manifests[] | select(.platform.os == $os and .platform.architecture == $arch) | .digest)' "$work/index.json")"
    [[ $child =~ $RE_DIGEST ]] || die "bad child digest for $p in $IMAGE:$version."
    reg_get "manifests/$child" "$work/image.json" "$ACCEPT_IMAGE" || die "cannot read the $p image of $version."
    [[ "sha256:$(sha256_of "$work/image.json")" == "$child" ]] || die "the registry returned another $p manifest."
    config="$(jq -r '.config.digest' "$work/image.json")"
    [[ $config =~ $RE_DIGEST ]] || die "bad config digest in the $p image of $version."
    reg_get "blobs/$config" "$work/config.json" || die "cannot read the $p image config of $version."
    [[ "sha256:$(sha256_of "$work/config.json")" == "$config" ]] || die "the registry returned another $p image config."
    rev="$(jq -r '.config.Labels["org.opencontainers.image.revision"] // empty' "$work/config.json")"
    [[ $rev =~ $RE_HEX40 ]] || die "$IMAGE:$version ($p) has no revision label."
    [[ -n $R_REVISION && $rev != "$R_REVISION" ]] && die "$IMAGE:$version carries different revision labels on its platforms."
    R_REVISION="$rev"
    [[ "$(jq -r '.config.Labels["org.opencontainers.image.version"] // empty' "$work/config.json")" == "$version" ]] ||
      die "$IMAGE:$version ($p) has a version label other than $version; installed panels would refuse it."
    # The install files are read from the linux/amd64 image.
    if [[ $p == linux/amd64 ]]; then cp "$work/image.json" "$work/image.amd64.json"; fi
  done
  cp "$work/image.amd64.json" "$work/image.json"
  mkdir -p "$dir"
  # Top layer first: the first copy found is the one the image shows.
  found=0
  for ((i = $(jq '.layers | length' "$work/image.json") - 1; i >= 0 && found < ${#WANT[@]}; i--)); do
    layer="$(jq -r ".layers[$i].digest" "$work/image.json")"
    mt="$(jq -r ".layers[$i].mediaType" "$work/image.json")"
    [[ $layer =~ $RE_DIGEST ]] || die "bad layer digest in $version."
    reg_get "blobs/$layer" "$work/layer" || die "cannot read layer $layer."
    [[ "sha256:$(sha256_of "$work/layer")" == "$layer" ]] || die "the registry returned another layer $layer."
    rm -rf "$work/x" && mkdir "$work/x"
    case "$mt" in
      *gzip) tar -xzf "$work/layer" -C "$work/x" --wildcards --no-same-owner 'srv/scripts/install/*' 2> /dev/null || true ;;
      *zstd) tar --zstd -xf "$work/layer" -C "$work/x" --wildcards --no-same-owner 'srv/scripts/install/*' 2> /dev/null || true ;;
      *tar) tar -xf "$work/layer" -C "$work/x" --wildcards --no-same-owner 'srv/scripts/install/*' 2> /dev/null || true ;;
      *) die "unsupported layer type $mt." ;;
    esac
    for f in "${WANT[@]}"; do
      if [[ ! -e $dir/$f && -f $work/x/srv/scripts/install/$f && ! -L $work/x/srv/scripts/install/$f ]]; then
        cp "$work/x/srv/scripts/install/$f" "$dir/$f"
        found=$((found + 1))
      fi
    done
  done
  rm -rf "$work"
  for f in "${WANT[@]}"; do [[ -f $dir/$f ]] || die "$IMAGE:$version has no /srv/scripts/install/$f."; done
}

# current_fields <site> <channel>: verifies the published manifest with the
# signing key and sets C_* (C_VERSION empty when there is none). Judged at its
# own published_at, so an expired manifest still tells us what was released.
current_fields() {
  local m="$1/v1/$2.json" at
  C_VERSION=""
  [[ -f $m && -f $m.sig ]] || return 0
  at="$(sed -n 's/^  "published_at": \([0-9]*\),$/\1/p' "$m")"
  [[ -n $at ]] || die "$m has no published_at."
  local p
  for p in "${PLATFORMS[@]}"; do
    tend_verify_manifest "$m" "$m.sig" "$2" "$p" "$at" "$SIGNING_SPKI" ||
      die "the published $2.json does not verify with the signing key; fix it by hand before signing again."
  done
  C_VERSION="$TEND_M_VERSION" C_DIGEST="$TEND_M_IMAGE_DIGEST" C_REVISION="$TEND_M_REVISION"
  C_PUBLISHED="$TEND_M_PUBLISHED_AT" C_SHA="$TEND_M_INSTALLER_SHA256" C_MIN="$TEND_M_MIN_UPGRADE_FROM"
}

cmd_plan() {
  local site="" out="" now force=0 tags ch cand any=0
  now="$(date +%s)"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --site) site="$2"; shift 2 ;; --out) out="$2"; shift 2 ;;
      --now) now="$2"; shift 2 ;; --force-resign) force=1; shift ;;
      *) die "unknown option $1" ;;
    esac
  done
  [[ -n $site && -n $out ]] || die "plan needs --site and --out."
  rm -rf "$out" && mkdir -p "$out"
  tags="$(mktemp)"
  reg_get "tags/list?n=10000" "$tags" || die "cannot list the tags of $IMAGE."
  {
    echo "now=$now"
    for ch in "${CHANNELS[@]}"; do
      cand="$(jq -r '.tags[]?' "$tags" | highest "$ch")"
      current_fields "$site" "$ch"
      if [[ -n $cand ]] && { [[ -z $C_VERSION ]] || version_lt "$C_VERSION" "$cand"; }; then
        inspect_release "$cand" "$out/$ch"
        local min
        min="$(tr -d '[:space:]' < "$out/$ch/min-upgrade-from")"
        echo "${ch}_action=release"
        echo "${ch}_version=$cand" "${ch}_digest=$R_DIGEST" "${ch}_revision=$R_REVISION" "${ch}_min=$min"
        say "$ch: release $cand ($R_DIGEST, revision $R_REVISION)${C_VERSION:+, replacing $C_VERSION}"
        any=1
      elif [[ -n $C_VERSION ]]; then
        if [[ -n $cand && $cand == "$C_VERSION" ]]; then
          inspect_digest_only "$cand"
          [[ $R_DIGEST == "$C_DIGEST" ]] || die "$IMAGE:$cand now names $R_DIGEST, but $ch.json pins $C_DIGEST; a version tag must never move."
        fi
        if ((force || now - C_PUBLISHED >= RESIGN_AFTER)); then
          mkdir -p "$out/$ch"
          cp "$site/v1/install-panel-$C_VERSION.sh" "$out/$ch/install-panel.sh" ||
            die "$site/v1/install-panel-$C_VERSION.sh is missing."
          [[ "$(sha256_of "$out/$ch/install-panel.sh")" == "$C_SHA" ]] || die "install-panel-$C_VERSION.sh does not match $ch.json."
          echo "${ch}_action=resign"
          echo "${ch}_version=$C_VERSION" "${ch}_digest=$C_DIGEST" "${ch}_revision=$C_REVISION" "${ch}_min=$C_MIN"
          say "$ch: re-sign $C_VERSION (signed $(((now - C_PUBLISHED) / 86400)) days ago)"
          any=1
        else
          echo "${ch}_action=none"
          say "$ch: $C_VERSION is current (signed $(((now - C_PUBLISHED) / 3600)) hours ago)"
        fi
      else
        echo "${ch}_action=none"
        say "$ch: nothing published and no release tag"
      fi
    done
    echo "sign=$any"
  } > "$out/plan.env"
  rm -f "$tags"
}

inspect_digest_only() {
  local f
  f="$(mktemp)"
  reg_get "manifests/$1" "$f" "$ACCEPT_INDEX" || die "cannot read $IMAGE:$1."
  R_DIGEST="sha256:$(sha256_of "$f")"
  rm -f "$f"
}

# plan_get <plan dir> <key>: one value from plan.env, never evaluated.
plan_get() { tr ' ' '\n' < "$1/plan.env" | sed -n "s/^$2=//p" | tail -n 1; }

# write_manifest: the canonical layout internal/panelrelease.Encode writes.
write_manifest() { # <out> channel expires image digest installer_sha installer_url key_id min published revision version
  printf '{\n  "channel": "%s",\n  "expires_at": %s,\n  "image": "%s",\n  "image_digest": "%s",\n  "installer_sha256": "%s",\n  "installer_url": "%s",\n  "key_id": "%s",\n  "min_upgrade_from": "%s",\n  "platforms": ["linux/amd64", "linux/arm64"],\n  "published_at": %s,\n  "revision": "%s",\n  "schema": 1,\n  "version": "%s"\n}\n' \
    "${@:2}" > "$1"
}

# sign_file <key> <domain> <file> <sig out>: Ed25519 over "<domain>\n" + bytes, base64 + newline.
sign_file() {
  local msg
  msg="$(mktemp)"
  { printf '%s\n' "$2"; cat "$3"; } > "$msg"
  openssl pkeyutl -sign -inkey "$1" -rawin -in "$msg" | base64 -w0 > "$4"
  echo >> "$4"
  rm -f "$msg"
}

cmd_sign() {
  local site="" plan="" now key spki keyid ch action version digest revision min sha url published expires
  now="$(date +%s)"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --site) site="$2"; shift 2 ;; --plan) plan="$2"; shift 2 ;; --now) now="$2"; shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
  [[ -n $site && -n $plan && -f $plan/plan.env ]] || die "sign needs --site and --plan <dir with plan.env>."
  [[ -n ${TEND_PANEL_RELEASE_KEY:-} ]] || die "TEND_PANEL_RELEASE_KEY is not set (the release environment's secret)."
  [[ $SIGNING_SPKI == "$RELEASE_SPKI" ]] || say "DRY RUN: signing with a throwaway key, not the Tend release key."
  KEYDIR="$(mktemp -d)"
  trap 'rm -rf "${KEYDIR:-}"' EXIT
  key="$KEYDIR/release.key"
  (umask 077 && printf '%s\n' "$TEND_PANEL_RELEASE_KEY" > "$key")
  spki="$(openssl pkey -in "$key" -pubout -outform DER 2> /dev/null | base64 -w0)" || die "the signing secret is not a PEM private key."
  [[ $spki == "$SIGNING_SPKI" ]] || die "the signing secret is not the key install.sh pins ($SIGNING_SPKI)."
  keyid="$(openssl pkey -in "$key" -pubout -outform DER | tail -c 32 | sha256sum | cut -c1-16)"
  published="$now" expires=$((now + LIFETIME))
  mkdir -p "$site/v1"
  for ch in "${CHANNELS[@]}"; do
    action="$(plan_get "$plan" "${ch}_action")"
    [[ $action == release || $action == resign ]] || continue
    version="$(plan_get "$plan" "${ch}_version")" digest="$(plan_get "$plan" "${ch}_digest")"
    revision="$(plan_get "$plan" "${ch}_revision")" min="$(plan_get "$plan" "${ch}_min")"
    [[ $version =~ $RE_VERSION && $min =~ $RE_VERSION ]] || die "$ch: bad version in the plan."
    [[ $ch == beta || $version != *-* ]] || die "stable never carries a prerelease ($version)."
    [[ $digest =~ $RE_DIGEST && $revision =~ $RE_HEX40 ]] || die "$ch: bad digest or revision in the plan."
    ! version_lt "$version" "$min" || die "$ch: min-upgrade-from $min is above $version."
    [[ -f $plan/$ch/install-panel.sh ]] || die "$ch: the plan has no stage 1."
    sha="$(sha256_of "$plan/$ch/install-panel.sh")"
    [[ $sha =~ $RE_HEX64 ]] || die "$ch: cannot hash stage 1."
    url="$BASE_URL/v1/install-panel-$version.sh"
    cp "$plan/$ch/install-panel.sh" "$site/v1/install-panel-$version.sh"
    write_manifest "$site/v1/$ch.json.new" "$ch" "$expires" "$IMAGE" "$digest" "$sha" "$url" "$keyid" "$min" "$published" "$revision" "$version"
    sign_file "$key" "tend-panel-release-v1" "$site/v1/$ch.json.new" "$site/v1/$ch.json.sig.new"
    for p in "${PLATFORMS[@]}"; do
      tend_verify_manifest "$site/v1/$ch.json.new" "$site/v1/$ch.json.sig.new" "$ch" "$p" "$now" "$SIGNING_SPKI" ||
        die "$ch: the manifest just signed does not verify."
    done
    mv "$site/v1/$ch.json.new" "$site/v1/$ch.json"
    mv "$site/v1/$ch.json.sig.new" "$site/v1/$ch.json.sig"
    if [[ -f $plan/$ch/install.sh && ($ch == stable || ! -f $site/install.sh) ]]; then
      grep -qF "\"$RELEASE_SPKI\"" "$plan/$ch/install.sh" || die "$ch: the image's install.sh does not pin the release key."
      cp "$plan/$ch/install.sh" "$site/install.sh"
      cp "$plan/$ch/tend-panel-release-1.pub.pem" "$site/tend-panel-release-1.pub.pem"
    fi
    say "$ch: signed $version ($action), expires $(date -u -d "@$expires" +%Y-%m-%dT%H:%MZ)"
  done
  [[ -f $site/install.sh ]] || die "no install.sh to publish yet."
  [[ "$(openssl pkey -pubin -in "$site/tend-panel-release-1.pub.pem" -outform DER | base64 -w0)" == "$RELEASE_SPKI" ]] ||
    die "tend-panel-release-1.pub.pem is not the release key."
  printf '%s  install.sh\n' "$(sha256_of "$site/install.sh")" > "$site/install.sh.sha256"
  sign_file "$key" "$SCRIPT_DOMAIN" "$site/install.sh" "$site/install.sh.sig"
  rm -f "$key"
  # Only the stage 1 files a channel names stay on the site; releases keep the rest.
  local keep f
  keep=" "
  for ch in "${CHANNELS[@]}"; do
    [[ -f $site/v1/$ch.json ]] && keep+="install-panel-$(sed -n 's/^  "version": "\(.*\)"$/\1/p' "$site/v1/$ch.json").sh "
  done
  for f in "$site"/v1/install-panel-*.sh; do
    [[ -e $f && $keep != *" ${f##*/} "* ]] && rm -f "$f"
  done
  (cd "$site" && find . -type f ! -name SHA256SUMS ! -name '.*' -printf '%P\n' | LC_ALL=C sort | xargs sha256sum) > "$KEYDIR/SHA256SUMS"
  mv "$KEYDIR/SHA256SUMS" "$site/SHA256SUMS"
}

cmd_publish() {
  local site="" plan="" ch action version files=() f g
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --site) site="$2"; shift 2 ;; --plan) plan="$2"; shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
  [[ $SIGNING_SPKI == "$RELEASE_SPKI" ]] || die "a dry run never publishes."
  git add -A -- "$site"
  if git diff --cached --quiet; then say "nothing changed on the site."; else
    git -c user.name="tend-install" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
      commit -q -m "release: $(tr '\n' ' ' < "$plan/plan.env" | sed 's/now=[0-9]* //')"
    git push -q origin HEAD:main
  fi
  for ch in "${CHANNELS[@]}"; do
    action="$(plan_get "$plan" "${ch}_action")" version="$(plan_get "$plan" "${ch}_version")"
    [[ $action == release ]] || continue
    if ! gh release view "panel-v$version" > /dev/null 2>&1; then
      local pre=()
      [[ $ch == beta && $version == *-* ]] && pre=(--prerelease)
      gh release create "panel-v$version" "${pre[@]}" --latest=false --title "Tend panel $version installer" \
        --notes "Stage 1 installer for panel $version (image $IMAGE@$(plan_get "$plan" "${ch}_digest")). Install with https://get.tend.host/install.sh." \
        "$site/v1/install-panel-$version.sh"
    fi
  done
  # The rolling release is what stage 0 falls back to (releases/latest/download/<file>).
  for f in install.sh install.sh.sha256 install.sh.sig tend-panel-release-1.pub.pem SHA256SUMS v1/*.json v1/*.json.sig v1/install-panel-*.sh; do
    for g in "$site"/$f; do [[ -f $g ]] && files+=("$g"); done
  done
  gh release view channels > /dev/null 2>&1 ||
    gh release create channels --latest --title "Install channels" \
      --notes "The files https://get.tend.host serves, for when it is unreachable. Verify with tend-panel-release-1.pub.pem."
  gh release upload channels --clobber "${files[@]}"
  gh release edit channels --latest
  local keep=" " asset
  for f in "${files[@]}"; do keep+="${f##*/} "; done
  while IFS= read -r asset; do
    [[ $keep == *" $asset "* ]] || gh release delete-asset channels "$asset" --yes
  done < <(gh release view channels --json assets --jq '.assets[].name')
}

case "${1:-}" in
  plan) shift; cmd_plan "$@" ;;
  sign) shift; cmd_sign "$@" ;;
  publish) shift; cmd_publish "$@" ;;
  *) die "usage: tend-install.sh plan|sign|publish ..." ;;
esac
