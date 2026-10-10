#!/usr/bin/env bash
# Tend-Stack/tend-install release tool: discovers panel releases in the public
# image package, signs the channel manifests, and lays out what get.tend.host
# serves. Source of truth: deploy/tend-install/ in the panel repository
# (docs/agent/installer.md, "Publishing a release"); this repository's copy is
# replaced from there, never edited here.
#
#   tend-install.sh copy    --out copy                                   # oras; GITHUB_TOKEN (packages: write)
#   tend-install.sh plan    --site site --out plan [--now <unix>] [--force-resign]
#   tend-install.sh sign    --site site --plan plan [--now <unix>]      # needs TEND_PANEL_RELEASE_KEY
#   tend-install.sh publish --site site --plan plan                      # git + gh, GITHUB_TOKEN
#   tend-install.sh alert   --plan plan [--failed] [--code-change <sha>] # gh issues, GITHUB_TOKEN
#
# Everything a release contains is derived from one public image digest: the
# version is its tag, the revision is its label, and stage 1, install.sh, the
# public key and min-upgrade-from are read from /srv/scripts/install/ inside
# its linux/amd64 image. Nothing here needs a credential except `sign`.
#
# compose.yml (docs/strategy/compose-install-plan.md): when a new stable image
# carries /srv/scripts/install/compose.yml.tmpl, `sign` renders it with the image
# reference and digest, signs it under its own domain (tend-install-compose-v1)
# into compose.yml.sig, and verifies it. Beta never touches it; a re-sign keeps the published
# pair, which must verify; a new stable release without the template removes the pair.
#
# Rules: stable takes the highest version without a prerelease part; beta takes
# the highest version of all, so a beta tag can never move stable.json. A
# channel never goes back to a lower version, and a version tag that now names
# another digest is refused. A manifest older than seven days is re-signed with
# the same fields (manifests live 30 days).
#
# The operator's SSH-signed vX.Y.Z tag is the only approval. A new version is
# signed only with its proof (docs/strategy/auto-channel-signing-plan.md): the
# public package's `proof-<version>` artifact holds the signed tag object, the
# statement {version, revision, image digest} and the Sigstore bundle of
# release.yml's run on that tag. `plan` verifies it and `sign` verifies it
# again. A release without a valid proof is refused (refusals.tsv, then an
# issue by `alert`); a refusal never blocks the re-sign of what is published.
set -euo pipefail

IMAGE="${TEND_INSTALL_IMAGE:-ghcr.io/tend-stack/tend-host}"
SCHEME="${TEND_REGISTRY_SCHEME:-https}"
BASE_URL="${TEND_INSTALL_URL:-https://get.tend.host}"
# The release key pinned in install.sh (docs/agent/panel-release-keys.md).
RELEASE_SPKI="MCowBQYDK2VwAyEA6mqh9euEIZV1KSTZzWBJ8xaluXkPBt5GGg+CuNLbuBM="
# A dry run signs with a throwaway key and says so; it never publishes.
SIGNING_SPKI="${TEND_INSTALL_DRY_RUN_SPKI:-$RELEASE_SPKI}"
# Keys an already published manifest or install.sh may be signed with: the
# release key, and in a dry run also the throwaway one.
ACCEPT_SPKIS=("$SIGNING_SPKI")
[[ $SIGNING_SPKI == "$RELEASE_SPKI" ]] || ACCEPT_SPKIS+=("$RELEASE_SPKI")
# What a release must be proven by (plan, "Data shapes").
TAG_SIGNER_PRINCIPAL="tend-release-tag"
TAG_SIGNER_FPR="SHA256:N4c7qT2SWLc3+pgt+E6VLh3n2oFSJKcOwiXepOAIyfk"
BUILDER_REPO="wilkinsantana/tend.host"
BUILDER_WORKFLOW=".github/workflows/release.yml"
OIDC_ISSUER="https://token.actions.githubusercontent.com"
PROOF_TYPE="application/vnd.tend.release-proof.v1"
PROOF_FILES=(tag.txt statement.json statement.sigstore.json)
PROOF_MAX=65536
LIFETIME=$((30 * 24 * 3600))
RESIGN_AFTER=$((7 * 24 * 3600))
PLATFORMS=(linux/amd64 linux/arm64)
CHANNELS=(stable beta)
WANT=(install.sh install-panel.sh tend-panel-release-1.pub.pem min-upgrade-from)
OPTIONAL=(compose.yml.tmpl)
SCRIPT_DOMAIN="tend-install-script-v1"
COMPOSE_DOMAIN="tend-install-compose-v1"
COMPOSE_MARKER="# tend-compose-install: v1"
COMPOSE_MAX=16384
RE_VERSION='^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})(-(alpha|beta|rc)\.(0|[1-9][0-9]{0,5}))?$'
RE_HEX40='^[0-9a-f]{40}$'
RE_HEX64='^[0-9a-f]{64}$'
RE_DIGEST='^sha256:[0-9a-f]{64}$'

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=verify-manifest.sh
. "$here/verify-manifest.sh"

# Production always uses the pinned signers file and the cosign on PATH. Only a
# dry run (a throwaway signing key) may swap them, so a test can prove the
# verification logic without Sigstore or the operator's key.
TAG_SIGNERS="$here/../release-tag-signers"
TAG_SIGNERS_PINNED=1
COSIGN=cosign
SOURCE_IMAGE="ghcr.io/wilkinsantana/tend-host"
if [[ -n ${TEND_INSTALL_DRY_RUN_SPKI:-} && $SIGNING_SPKI != "$RELEASE_SPKI" ]]; then
  SOURCE_IMAGE="${TEND_INSTALL_SOURCE_IMAGE:-$SOURCE_IMAGE}"
  if [[ -n ${TEND_INSTALL_DRY_RUN_TAG_SIGNERS:-} ]]; then TAG_SIGNERS="$TEND_INSTALL_DRY_RUN_TAG_SIGNERS" TAG_SIGNERS_PINNED=0; fi
  COSIGN="${TEND_INSTALL_COSIGN:-cosign}"
fi

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
  for ((i = $(jq '.layers | length' "$work/image.json") - 1; i >= 0 && found < ${#WANT[@]} + ${#OPTIONAL[@]}; i--)); do
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
    for f in "${WANT[@]}" "${OPTIONAL[@]}"; do
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
    tend_verify_manifest "$m" "$m.sig" "$2" "$p" "$at" "${ACCEPT_SPKIS[@]}" ||
      die "the published $2.json does not verify with the signing key; fix it by hand before signing again."
  done
  C_VERSION="$TEND_M_VERSION" C_DIGEST="$TEND_M_IMAGE_DIGEST" C_REVISION="$TEND_M_REVISION"
  C_PUBLISHED="$TEND_M_PUBLISHED_AT" C_SHA="$TEND_M_INSTALLER_SHA256" C_MIN="$TEND_M_MIN_UPGRADE_FROM"
}

# ---- the proof of a release (plan, invariant 1) ----
# These helpers `die` on the first failed check. cmd_plan runs them in a
# subshell so a refusal cannot stop the run; cmd_sign runs them bare.

# load_tag_signers: the pinned file holds one line naming the principal and
# one ed25519 key whose fingerprint is TAG_SIGNER_FPR.
load_tag_signers() {
  local lines=() line key fpr
  [[ -f $TAG_SIGNERS && ! -L $TAG_SIGNERS ]] || die "the pinned release-tag-signers file is missing."
  mapfile -t lines < "$TAG_SIGNERS"
  [[ ${#lines[@]} -eq 1 ]] || die "release-tag-signers must hold exactly one line."
  line="${lines[0]}"
  [[ $line =~ ^${TAG_SIGNER_PRINCIPAL}\ namespaces=\"git\"\ (ssh-ed25519\ [A-Za-z0-9+/]+=*)$ ]] ||
    die "release-tag-signers is not one '$TAG_SIGNER_PRINCIPAL namespaces=\"git\" ssh-ed25519 <key>' line."
  ((TAG_SIGNERS_PINNED)) || return 0
  key="$(mktemp)"
  printf '%s\n' "${BASH_REMATCH[1]}" > "$key"
  fpr="$(ssh-keygen -lf "$key" 2> /dev/null | cut -d' ' -f2)" || fpr=""
  rm -f "$key"
  [[ $fpr == "$TAG_SIGNER_FPR" ]] || die "release-tag-signers does not hold the pinned key $TAG_SIGNER_FPR."
}

# verify_tag_object <file> <version> <revision>: <file> is `git cat-file tag v<version>`
# and was signed by the pinned operator key (ssh-keygen -Y verify -n git), and its
# headers say `object <revision>`, `type commit`, `tag v<version>`, `tagger …`.
verify_tag_object() {
  local file="$1" v="$2" r="$3" work n head=()
  [[ $v =~ $RE_VERSION && $r =~ $RE_HEX40 ]] || die "bad version or revision for the tag check."
  [[ -f $file && ! -L $file ]] || die "the proof has no tag.txt."
  load_tag_signers
  n="$(grep -cxF -- '-----BEGIN SSH SIGNATURE-----' "$file" || true)"
  [[ $n == 1 ]] || die "tag.txt must hold exactly one SSH signature."
  [[ "$(tail -n 1 "$file")" == "-----END SSH SIGNATURE-----" ]] || die "tag.txt has text after the SSH signature."
  mapfile -t head < <(head -n 4 "$file")
  [[ ${#head[@]} -eq 4 && ${head[0]} == "object $r" && ${head[1]} == "type commit" && ${head[2]} == "tag v$v" && ${head[3]} == "tagger "* ]] ||
    die "the signed tag does not say 'tag v$v' on commit $r."
  work="$(mktemp -d)"
  awk -v p="$work/payload" -v s="$work/sig" '
    $0 == "-----BEGIN SSH SIGNATURE-----" { in_sig = 1 }
    { if (in_sig) print > s; else print > p }' "$file"
  if ! ssh-keygen -Y verify -f "$TAG_SIGNERS" -I "$TAG_SIGNER_PRINCIPAL" -n git -s "$work/sig" < "$work/payload" > /dev/null 2>&1; then
    rm -rf "$work"
    die "the tag v$v is not signed by the pinned release-tag key."
  fi
  rm -rf "$work"
}

# proof_manifest_ok <manifest.json> <version>: the artifact type, exactly three layers.
proof_manifest_ok() {
  jq -e --arg t "$PROOF_TYPE" '.artifactType == $t and (.layers | type == "array") and (.layers | length) == 3' "$1" > /dev/null 2>&1 ||
    die "proof-$2 is not a $PROOF_TYPE artifact with three layers."
}

# proof_layer <manifest.json> <version> <title>: sets P_SIZE and P_DIGEST of the one layer with that
# title, within the size cap.
proof_layer() {
  local row
  row="$(jq -r --arg t "$3" '[.layers[] | select((.annotations // {})["org.opencontainers.image.title"] == $t)] |
    if length == 1 then "\(.[0].size) \(.[0].digest)" else "bad" end' "$1" 2> /dev/null)" || row="bad"
  [[ $row != bad ]] || die "proof-$2 does not carry exactly one $3."
  P_SIZE="${row%% *}" P_DIGEST="${row#* }"
  [[ $P_SIZE =~ ^[0-9]+$ && $P_SIZE -le $PROOF_MAX && $P_DIGEST =~ $RE_DIGEST ]] || die "proof-$2: $3 has a bad size or digest."
}

# fetch_proof <version> <dir>: the OCI artifact proof-<version> of the public
# package into <dir>: artifactType, exactly three titled layers, size cap, blob digests.
fetch_proof() {
  local v="$1" dir="$2" work title
  work="$(mktemp -d)"
  reg_get "manifests/proof-$v" "$work/manifest.json" "application/vnd.oci.image.manifest.v1+json" ||
    { rm -rf "$work"; die "$IMAGE has no proof-$v artifact; nothing proves release $v."; }
  proof_manifest_ok "$work/manifest.json" "$v"
  mkdir -p "$dir"
  for title in "${PROOF_FILES[@]}"; do
    proof_layer "$work/manifest.json" "$v" "$title"
    reg_get "blobs/$P_DIGEST" "$dir/$title" || die "cannot read $title of proof-$v."
    [[ "$(stat -c %s "$dir/$title")" == "$P_SIZE" && "sha256:$(sha256_of "$dir/$title")" == "$P_DIGEST" ]] ||
      die "the registry returned another $title for proof-$v."
  done
  rm -rf "$work"
}

# verify_proof <dir> <version> <revision> <index digest>: invariant 1 (a) and (b).
verify_proof() {
  local dir="$1" v="$2" r="$3" d="$4" f want err
  [[ $v =~ $RE_VERSION && $r =~ $RE_HEX40 && $d =~ $RE_DIGEST ]] || die "bad version, revision or digest for the proof check."
  for f in "${PROOF_FILES[@]}"; do
    [[ -f $dir/$f && ! -L $dir/$f ]] || die "the proof has no $f."
  done
  verify_tag_object "$dir/tag.txt" "$v" "$r"
  want="$(mktemp)"
  printf '{"schema":1,"version":"%s","revision":"%s","image_digest":"%s"}\n' "$v" "$r" "$d" > "$want"
  cmp -s "$want" "$dir/statement.json" || { rm -f "$want"; die "statement.json does not say version $v, revision $r and digest $d."; }
  rm -f "$want"
  command -v "$COSIGN" > /dev/null 2>&1 || die "cosign is not installed."
  err="$(mktemp)"
  if ! "$COSIGN" verify-blob "$dir/statement.json" --bundle "$dir/statement.sigstore.json" \
    --certificate-identity "https://github.com/$BUILDER_REPO/$BUILDER_WORKFLOW@refs/tags/v$v" \
    --certificate-oidc-issuer "$OIDC_ISSUER" \
    --certificate-github-workflow-repository "$BUILDER_REPO" \
    --certificate-github-workflow-ref "refs/tags/v$v" \
    --certificate-github-workflow-sha "$r" \
    --certificate-github-workflow-trigger push > /dev/null 2> "$err"; then
    tail -n 3 "$err" >&2
    rm -f "$err"
    die "the Sigstore proof does not show $BUILDER_REPO's release workflow building $v from $r."
  fi
  rm -f "$err"
}

# refuse <phase> <channel|-> <version> <reason>: a line for `alert` in $REFUSALS (phase plan or copy); nothing else changes.
refuse() {
  local reason
  reason="$(printf '%s' "$4" | tr -d '\t\r\n' | cut -c1-200)"
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$reason" >> "$REFUSALS"
  say "$1 $2 $3: REFUSED: $reason"
}

# try_release <channel> <version> <out>: the whole release path (inspect, fetch the
# proof, verify it) in a subshell. TRY_OK=1 and <out>/<channel>/candidate.env on
# success; TRY_OK=0 and a refusal otherwise. Called as a plain statement: bash
# ignores `set -e` in anything run from an `if` or `||` condition, subshells included.
try_release() {
  local ch="$1" cand="$2" out="$3" errf rc reason min
  errf="$(mktemp)"
  set +e
  (
    set -e
    inspect_release "$cand" "$out/$ch"
    min="$(tr -d '[:space:]' < "$out/$ch/min-upgrade-from")"
    [[ $min =~ $RE_VERSION ]] || die "min-upgrade-from of $cand is not a version."
    ! version_lt "$cand" "$min" || die "min-upgrade-from $min of $cand is above the release itself."
    fetch_proof "$cand" "$out/$ch/proof"
    verify_proof "$out/$ch/proof" "$cand" "$R_REVISION" "$R_DIGEST"
    printf 'digest=%s\nrevision=%s\nmin=%s\n' "$R_DIGEST" "$R_REVISION" "$min" > "$out/$ch/candidate.env"
  ) > "$errf" 2>&1
  rc=$?
  set -e
  cat "$errf" >&2
  if ((rc == 0)); then
    TRY_OK=1
    say "$ch: proof verified"
  else
    TRY_OK=0
    reason="$(grep -v '^[[:space:]]*$' "$errf" | tail -n 1 | sed 's/^tend-install: //')"
    refuse plan "$ch" "$cand" "${reason:-the release check failed (exit $rc)}"
    rm -rf "${out:?}/$ch"
  fi
  rm -f "$errf"
}

cmd_plan() {
  local site="" out="" now force=0 tags ch cand any=0 refused=0 listed=1 released
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
  REFUSALS="$out/refusals.tsv"
  : > "$REFUSALS"
  tags="$(mktemp)"
  # A tag list that cannot be read refuses the new releases; published channels still re-sign.
  if ! reg_get "tags/list?n=10000" "$tags"; then listed=0 && echo '{}' > "$tags"; fi
  {
    echo "now=$now"
    for ch in "${CHANNELS[@]}"; do
      cand="$(jq -r '.tags[]?' "$tags" | highest "$ch")"
      ((listed)) || refuse plan "$ch" unknown "cannot list the tags of $IMAGE."
      current_fields "$site" "$ch"
      released=0
      if [[ -n $cand ]] && { [[ -z $C_VERSION ]] || version_lt "$C_VERSION" "$cand"; }; then
        try_release "$ch" "$cand" "$out"
        if ((TRY_OK)); then
          echo "${ch}_action=release"
          echo "${ch}_version=$cand" "${ch}_digest=$(candidate_get "$out/$ch" digest)" "${ch}_revision=$(candidate_get "$out/$ch" revision)" "${ch}_min=$(candidate_get "$out/$ch" min)"
          say "$ch: release $cand ($(candidate_get "$out/$ch" digest), revision $(candidate_get "$out/$ch" revision))${C_VERSION:+, replacing $C_VERSION}"
          if [[ -f $out/$ch/compose.yml.tmpl ]]; then say "$ch: compose template present"; else say "$ch: compose template absent"; fi
          released=1 any=1
        fi
      elif [[ -n $cand && $cand == "$C_VERSION" ]]; then
        # The published version's tag must still name the pinned digest; if not (or if it
        # cannot be read) alert, and keep re-signing the pinned digest: installs pull by digest.
        if ! inspect_digest_only "$cand"; then
          refuse plan "$ch" "$cand" "cannot read $IMAGE:$cand; $ch.json keeps pinning $C_DIGEST."
        elif [[ $R_DIGEST != "$C_DIGEST" ]]; then
          refuse plan "$ch" "$cand" "a version tag must never move: $IMAGE:$cand now names ${R_DIGEST:0:19}, but $ch.json pins ${C_DIGEST:0:19}."
        fi
      fi
      if ((released)); then
        continue
      elif [[ -n $C_VERSION ]]; then
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
    [[ -s $REFUSALS ]] && refused=1
    echo "refused=$refused"
    echo "sign=$any"
  } > "$out/plan.env"
  rm -f "$tags"
}

# candidate_get <channel dir> <key>: one value of candidate.env, never evaluated.
candidate_get() { sed -n "s/^$2=//p" "$1/candidate.env" | tail -n 1; }

# inspect_digest_only <version>: sets R_DIGEST; returns 1 when the tag cannot be read.
inspect_digest_only() {
  local f
  f="$(mktemp)"
  if ! reg_get "manifests/$1" "$f" "$ACCEPT_INDEX"; then rm -f "$f"; return 1; fi
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

# script_signature_ok <site> <scratch dir>: site/install.sh.sig is a valid signature (by the
# release key; in a dry run also the throwaway one) over "$SCRIPT_DOMAIN\n" + install.sh.
script_signature_ok() {
  local site="$1" tmp="$2" spki
  [[ -f $site/install.sh && -f $site/install.sh.sig ]] || return 1
  { printf '%s\n' "$SCRIPT_DOMAIN"; cat "$site/install.sh"; } > "$tmp/script.msg"
  base64 -d "$site/install.sh.sig" > "$tmp/script.sig" 2> /dev/null || return 1
  for spki in "${ACCEPT_SPKIS[@]}"; do
    printf -- '-----BEGIN PUBLIC KEY-----\n%s\n-----END PUBLIC KEY-----\n' "$spki" > "$tmp/script.pub"
    if openssl pkeyutl -verify -pubin -inkey "$tmp/script.pub" -rawin -in "$tmp/script.msg" -sigfile "$tmp/script.sig" > /dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

# render_compose <tmpl> <version> <digest> <out>: the compose.yml of one release. The version and
# digest were checked against RE_VERSION and RE_DIGEST by the caller.
render_compose() {
  local tmpl="$1" version="$2" digest="$3" out="$4" ref
  [[ $version =~ $RE_VERSION && $digest =~ $RE_DIGEST ]] || die "compose: bad version or digest."
  ref="$IMAGE:$version@$digest"
  sed -e "s|@TEND_IMAGE_REF@|$ref|g" -e "s|@TEND_VERSION@|$version|g" "$tmpl" > "$out"
  ! grep -q '@TEND_' "$out" || die "compose.yml.tmpl has a placeholder this tool does not know."
  [[ "$(head -n 1 "$out")" == "$COMPOSE_MARKER" ]] || die "compose.yml.tmpl does not start with '$COMPOSE_MARKER'."
  (($(wc -c < "$out") <= COMPOSE_MAX)) || die "compose.yml is larger than $COMPOSE_MAX bytes."
}

# compose_signature_ok <site> <scratch dir>: site/compose.yml.sig is a valid signature (by the
# release key; in a dry run also the throwaway one) over "$COMPOSE_DOMAIN\n" + compose.yml.
compose_signature_ok() {
  local site="$1" tmp="$2" spki
  [[ -f $site/compose.yml && -f $site/compose.yml.sig ]] || return 1
  { printf '%s\n' "$COMPOSE_DOMAIN"; cat "$site/compose.yml"; } > "$tmp/compose.msg"
  base64 -d "$site/compose.yml.sig" > "$tmp/compose.sig" 2> /dev/null || return 1
  for spki in "${ACCEPT_SPKIS[@]}"; do
    printf -- '-----BEGIN PUBLIC KEY-----\n%s\n-----END PUBLIC KEY-----\n' "$spki" > "$tmp/compose.pub"
    if openssl pkeyutl -verify -pubin -inkey "$tmp/compose.pub" -rawin -in "$tmp/compose.msg" -sigfile "$tmp/compose.sig" > /dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

cmd_sign() {
  local site="" plan="" now key spki keyid ch action version digest revision min sha url published expires replaced=0 composed=0
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
    # The plan is only a claim: judge it again against the published manifest and the proof.
    current_fields "$site" "$ch"
    if [[ $action == release ]]; then
      [[ -z $C_VERSION ]] || version_lt "$C_VERSION" "$version" || die "$ch: $version is not above the published $C_VERSION."
      verify_proof "$plan/$ch/proof" "$version" "$revision" "$digest"
    else
      [[ -n $C_VERSION && $version == "$C_VERSION" && $digest == "$C_DIGEST" && $revision == "$C_REVISION" && $min == "$C_MIN" && $sha == "$C_SHA" ]] ||
        die "$ch: the re-sign plan differs from the published $ch.json; only its own fields may be signed again."
    fi
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
      replaced=1
    fi
    if [[ $ch == stable && $action == release && -f $plan/stable/compose.yml.tmpl ]]; then
      render_compose "$plan/stable/compose.yml.tmpl" "$version" "$digest" "$site/compose.yml.new"
      sign_file "$key" "$COMPOSE_DOMAIN" "$site/compose.yml.new" "$site/compose.yml.sig.new"
      mkdir -p "$KEYDIR/cv" && cp "$site/compose.yml.new" "$KEYDIR/cv/compose.yml" && cp "$site/compose.yml.sig.new" "$KEYDIR/cv/compose.yml.sig"
      compose_signature_ok "$KEYDIR/cv" "$KEYDIR" || die "stable: the compose.yml just signed does not verify."
      mv "$site/compose.yml.new" "$site/compose.yml"
      mv "$site/compose.yml.sig.new" "$site/compose.yml.sig"
      composed=1
    elif [[ $ch == stable && $action == release ]]; then
      # The new digest would not match the published pin: absence is accepted by vendoring, a mismatch is not.
      if [[ -f $site/compose.yml || -f $site/compose.yml.sig ]]; then
        rm -f "$site/compose.yml" "$site/compose.yml.sig"
        say "stable $version has no compose template; removed compose.yml so get.tend.host stays consistent"
      fi
    fi
    say "$ch: signed $version ($action), expires $(date -u -d "@$expires" +%Y-%m-%dT%H:%MZ)"
  done
  [[ -f $site/install.sh ]] || die "no install.sh to publish yet."
  [[ "$(openssl pkey -pubin -in "$site/tend-panel-release-1.pub.pem" -outform DER | base64 -w0)" == "$RELEASE_SPKI" ]] ||
    die "tend-panel-release-1.pub.pem is not the release key."
  if ((replaced)); then
    # Bytes extracted from a proven image in this run.
    printf '%s  install.sh\n' "$(sha256_of "$site/install.sh")" > "$site/install.sh.sha256"
    sign_file "$key" "$SCRIPT_DOMAIN" "$site/install.sh" "$site/install.sh.sig"
  else
    # A re-sign never signs install.sh: the signature already there must verify, and stays.
    script_signature_ok "$site" "$KEYDIR" || die "site/install.sh does not verify with install.sh.sig; fix it by hand."
  fi
  # Without a new template the compose.yml already published stays, and must still verify.
  if ((!composed)) && [[ -f $site/compose.yml || -f $site/compose.yml.sig ]]; then
    compose_signature_ok "$site" "$KEYDIR" || die "site/compose.yml does not verify with compose.yml.sig; fix it by hand."
  fi
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
  # The workflow bot writes site/ and nothing else (the release key lives on this branch).
  local outside
  outside="$(git diff --cached --name-only --no-renames | awk -v p="${site%/}/" 'index($0, p) != 1')"
  [[ -z $outside ]] || die "refusing to commit paths outside $site/: $(head -n 3 <<< "$outside" | tr '\n' ' ')"
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
  for f in install.sh install.sh.sha256 install.sh.sig compose.yml compose.yml.sig tend-panel-release-1.pub.pem SHA256SUMS v1/*.json v1/*.json.sig v1/install-panel-*.sh; do
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

# ---- copy: the private package to the public one, only what has a proof ----
# Runs in the `copy` job with tend-install's own GITHUB_TOKEN (packages: write) and
# never sees the release key. Registry credentials come as docker config files
# (TEND_COPY_FROM_CONFIG for the private package, TEND_COPY_TO_CONFIG for the
# public one); no token is ever an argument.

# public_digest <tag>: the digest of the public package's manifest for <tag>, or nothing.
public_digest() {
  local f
  f="$(mktemp)"
  if reg_get "manifests/$1" "$f" "$ACCEPT_INDEX, $ACCEPT_IMAGE"; then printf 'sha256:%s' "$(sha256_of "$f")"; fi
  rm -f "$f"
}

# oras_resolve <reference>: the digest <reference> names in the private package.
oras_resolve() {
  local d
  d="$(oras resolve "${ORAS_PLAIN[@]}" --registry-config "$TEND_COPY_FROM_CONFIG" "$1")" || die "cannot read $1."
  [[ $d =~ $RE_DIGEST ]] || die "$1 resolved to something that is not a digest."
  printf '%s' "$d"
}

# copy_one <version>: verify the private proof, then copy proof-<version> and <version>
# (proof first, so plan never sees the image without its proof). Dies on any failure.
copy_one() {
  local v="$1" work title p_digest d_digest r pub_p pub_v
  work="$(mktemp -d)"
  p_digest="$(oras_resolve "$SOURCE_IMAGE:proof-$v")"
  d_digest="$(oras_resolve "$SOURCE_IMAGE:$v")"
  oras manifest fetch "${ORAS_PLAIN[@]}" --registry-config "$TEND_COPY_FROM_CONFIG" "$SOURCE_IMAGE@$p_digest" > "$work/manifest.json" ||
    die "cannot read proof-$v."
  [[ "sha256:$(sha256_of "$work/manifest.json")" == "$p_digest" ]] || die "the registry returned another manifest for proof-$v."
  proof_manifest_ok "$work/manifest.json" "$v"
  oras pull "${ORAS_PLAIN[@]}" --registry-config "$TEND_COPY_FROM_CONFIG" -o "$work/proof" "$SOURCE_IMAGE@$p_digest" > /dev/null ||
    die "cannot pull proof-$v."
  [[ "$(find "$work/proof" -mindepth 1 | wc -l)" -eq 3 ]] || die "proof-$v pulled more or fewer than three files."
  for title in "${PROOF_FILES[@]}"; do
    proof_layer "$work/manifest.json" "$v" "$title"
    [[ -f $work/proof/$title && ! -L $work/proof/$title && "sha256:$(sha256_of "$work/proof/$title")" == "$P_DIGEST" ]] ||
      die "proof-$v: $title does not match its layer."
  done
  r="$(sed -n 's/^object //p' "$work/proof/tag.txt" | head -n 1)"
  [[ $r =~ $RE_HEX40 ]] || die "proof-$v: tag.txt names no commit."
  verify_proof "$work/proof" "$v" "$r" "$d_digest"
  pub_v="$(public_digest "$v")"
  [[ -z $pub_v || $pub_v == "$d_digest" ]] || die "the public $v already names ${pub_v:0:19}, not the private ${d_digest:0:19}; a version tag must never move."
  pub_p="$(public_digest "proof-$v")"
  [[ -z $pub_p || $pub_p == "$p_digest" ]] || die "the public proof-$v already names another artifact."
  if [[ -z $pub_p ]]; then
    oras cp "${ORAS_FROM_PLAIN[@]}" "${ORAS_TO_PLAIN[@]}" --from-registry-config "$TEND_COPY_FROM_CONFIG" --to-registry-config "$TEND_COPY_TO_CONFIG" \
      "$SOURCE_IMAGE@$p_digest" "$IMAGE:proof-$v" > /dev/null || die "cannot copy proof-$v."
    say "copied proof-$v"
  fi
  if [[ -z $pub_v ]]; then
    oras cp "${ORAS_FROM_PLAIN[@]}" "${ORAS_TO_PLAIN[@]}" --from-registry-config "$TEND_COPY_FROM_CONFIG" --to-registry-config "$TEND_COPY_TO_CONFIG" \
      "$SOURCE_IMAGE@$d_digest" "$IMAGE:$v" > /dev/null || die "cannot copy $v."
    say "copied $v"
  fi
  [[ "$(public_digest "$v")" == "$d_digest" && "$(public_digest "proof-$v")" == "$p_digest" ]] ||
    die "after the copy the public $v or proof-$v does not match the private digest."
  rm -rf "$work"
}

# try_copy <version>: copy_one in a subshell with `set -e` honoured (see try_release);
# a failure is a copy-phase refusal and the next candidate goes on.
try_copy() {
  local v="$1" errf rc reason
  errf="$(mktemp)"
  set +e
  (
    set -e
    copy_one "$v"
  ) > "$errf" 2>&1
  rc=$?
  set -e
  cat "$errf" >&2
  if ((rc != 0)); then
    reason="$(grep -v '^[[:space:]]*$' "$errf" | tail -n 1 | sed 's/^tend-install: //')"
    refuse copy - "$v" "${reason:-the copy failed (exit $rc)}"
  fi
  rm -f "$errf"
}

# copy --out <dir>: <dir>/copy-refusals.tsv lists what was refused.
cmd_copy() {
  local out="" priv pub t cands=() stable any n=0 v
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out) out="$2"; shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
  [[ -n $out ]] || die "copy needs --out."
  [[ -n ${TEND_COPY_FROM_CONFIG:-} && -n ${TEND_COPY_TO_CONFIG:-} ]] || die "copy needs TEND_COPY_FROM_CONFIG and TEND_COPY_TO_CONFIG (docker config files)."
  command -v oras > /dev/null 2>&1 || die "oras is not installed."
  ORAS_PLAIN=() ORAS_FROM_PLAIN=() ORAS_TO_PLAIN=()
  if [[ $SCHEME == http ]]; then ORAS_PLAIN=(--plain-http) ORAS_FROM_PLAIN=(--from-plain-http) ORAS_TO_PLAIN=(--to-plain-http); fi
  mkdir -p "$out"
  REFUSALS="$out/copy-refusals.tsv"
  : > "$REFUSALS"
  priv="$(mktemp)" pub="$(mktemp)"
  oras repo tags "${ORAS_PLAIN[@]}" --registry-config "$TEND_COPY_FROM_CONFIG" "$SOURCE_IMAGE" > "$priv" || die "cannot list the tags of $SOURCE_IMAGE."
  reg_get "tags/list?n=10000" "$pub" || die "cannot list the tags of $IMAGE."
  stable="$(jq -r '.tags[]?' "$pub" | highest stable)"
  any="$(jq -r '.tags[]?' "$pub" | highest beta)"
  # A candidate has a proof in the private package, is not yet public with its proof, and is not below
  # what is public (stable-class: the highest public stable or above; a prerelease: the highest public
  # version or above). "Or equal" lets a version that is public without a proof be refused loudly if its
  # digest differs, instead of being skipped silently.
  while IFS= read -r t; do
    version_key "$t" > /dev/null 2>&1 || continue
    grep -qxF -- "proof-$t" "$priv" || continue
    if jq -e --arg t "$t" '.tags | index($t) != null and index("proof-" + $t) != null' "$pub" > /dev/null; then continue; fi
    if [[ $t == *-* ]]; then
      [[ -z $any ]] || ! version_lt "$t" "$any" || continue
    else
      [[ -z $stable ]] || ! version_lt "$t" "$stable" || continue
    fi
    cands+=("$t")
  done < <(sort -u "$priv" | while IFS= read -r t; do k="$(version_key "$t" 2> /dev/null)" && printf '%s %s\n' "$k" "$t"; done | LC_ALL=C sort -r | cut -d' ' -f2)
  for v in "${cands[@]}"; do
    ((n < 3)) || break
    n=$((n + 1))
    try_copy "$v"
  done
  say "copy: ${#cands[@]} candidate(s), $(wc -l < "$REFUSALS") refused."
  rm -f "$priv" "$pub"
}

# raise_issue <title> <body>: one open issue per title; never a comment on a repeat.
raise_issue() {
  local open
  open="$(gh issue list --state open --search "in:title $1" --limit 100 --json title --jq '.[].title')" ||
    die "cannot list the open issues."
  if grep -qxF -- "$1" <<< "$open"; then say "an issue titled '$1' is already open."; return 0; fi
  gh issue create --title "$1" --body "$2" > /dev/null || die "cannot create the issue '$1'."
  say "opened an issue: $1"
}

# alert --plan <dir> [--failed] [--code-change <sha>]: one issue per line of <dir>/refusals.tsv
# and <dir>/copy-refusals.tsv (`<phase>\t<channel|->\t<version>\t<reason>`), one for a failed run,
# one for a code change on main. Works without a plan directory.
cmd_alert() {
  local plan="" failed=0 code="" phase ch version reason run="" file title body
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --plan) plan="$2"; shift 2 ;; --failed) failed=1; shift ;;
      --code-change) code="$2"; shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
  if [[ -n ${GITHUB_RUN_ID:-} ]]; then run="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/$GITHUB_RUN_ID"; fi
  if [[ -n $plan ]]; then
    for file in "$plan/refusals.tsv" "$plan/copy-refusals.tsv"; do
      [[ -s $file ]] || continue
      while IFS=$'\t' read -r phase ch version reason || [[ -n $phase ]]; do
        if [[ $phase == plan && $ch =~ ^(stable|beta)$ && ($version =~ $RE_VERSION || $version == unknown) ]]; then
          title="Install channel refused $ch $version"
          body="The $ch channel did not take $version, so it was not signed; published channels keep being re-signed."
        elif [[ $phase == copy && $ch == - && $version =~ $RE_VERSION ]]; then
          title="Image copy refused $version"
          body="$version was not copied from the private package to the public one, so nothing can sign it."
        else
          say "skipping a malformed refusal line."
          continue
        fi
        raise_issue "$title" "$body"$'\n\n'"Reason: $reason"$'\n\n'"Run: ${run:-unknown}"
      done < "$file"
    done
  fi
  if ((failed)); then
    raise_issue "Install channel workflow failed" "The install channel workflow failed, so nothing new was signed. Published manifests expire 30 days after they were signed: fix this before then."$'\n\n'"Run: ${run:-unknown}"
  fi
  if [[ -n $code ]]; then
    [[ $code =~ $RE_HEX40 ]] || die "--code-change needs a commit sha."
    raise_issue "tend-install code changed ${code:0:7}" "Commit $code changed files outside site/ on main. Code here is replaced only by the operator's sync from the panel repository; if you did not make this change, treat the release key as exposed (docs/agent/panel-release-keys.md)."$'\n\n'"Commit: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/commit/$code"
  fi
}


# Sourcing the file (the tests do) defines the functions and runs nothing.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  case "${1:-}" in
    plan) shift; cmd_plan "$@" ;;
    sign) shift; cmd_sign "$@" ;;
    publish) shift; cmd_publish "$@" ;;
    alert) shift; cmd_alert "$@" ;;
    copy) shift; cmd_copy "$@" ;;
    *) die "usage: tend-install.sh copy|plan|sign|publish|alert ..." ;;
  esac
fi
