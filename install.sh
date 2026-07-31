#!/usr/bin/env bash
#
# Eyes node installer — docker-only. No root, no git clone, NO DOPPLER.
#
#   curl -fsSL https://<your-host>/install.sh | bash -s -- <factory-id> <enroll-credential> [version] [updater-version]
#
# One credential, one call. The enrollment credential (minted with
# scripts/eyes_device_admin.py) authenticates BOTH the image pull and the enrollment, and
# everything else the node needs — its env, its secrets — comes from the control plane
# afterwards.
#
# The device door defaults to the live Cloud Run door; override it with
# EYES_DEVICE_DOOR_URL=https://<device-door> only if it moves. The credential may also be
# passed via the EYES_ENROLL_CREDENTIAL env var instead of the arg (prefix a leading space
# or `export` it to keep it out of shell history). Enrollment consumes it server-side, so
# exposure after that is moot. Reinstalls/upgrades of an ALREADY-ENROLLED node need no
# credential at all — they authenticate with the node's own device identity.
#
# ── A4: this is BRING-UP, not the update path ────────────────────────────────
# Updates ride the device channel now (a compose bump delivered to the eyes-updater
# sidecar, health-gated on the node, auto-reverting). install.sh remains the FLOOR:
# first bring-up, and the recovery path for a node that can run neither release. Two
# things changed here.
#
# 1. THE ON-DISK SHAPE — the retain-and-revert release layout (spec §6.1), which is what
#    makes a revert a directory swap instead of a re-download:
#
#      $EYES_HOME/
#        releases/<tag>/  docker-compose.yml  config/  env    # rehydrated from the image
#        current  -> releases/<tag>                           # the active release
#        previous -> releases/<older>                         # the revert target
#        identity/                                            # NEVER touched by a bump
#        data/                                                # NEVER touched by a bump
#        var/ota/                                             # the updater's journal
#
#    identity/ and data/ live OUTSIDE the release dirs on purpose: a revert must never roll
#    back a node's identity or its metadata bundle. Compose is always invoked as
#      docker compose -f $EYES_HOME/current/docker-compose.yml --env-file $EYES_HOME/current/env
#    so "which release is running" is one symlink, readable and swappable atomically.
#
# 2. WHERE SECRETS COME FROM — nowhere on this box, and no vendor. This script used to
#    download the ENTIRE Doppler `prd_fleet` config to $EYES_HOME/docker/.env and strip a
#    couple of keys afterwards. prd_fleet holds eleven secrets, including DATABASE_URL and
#    DEVICE_JWT_SIGNING_KEYS — the ES256 PRIVATE key the device door mints device tokens
#    with. A node holding that key can mint a token for ANY device_id: a bigger blast
#    radius than the shared SA key A3 was built to remove, and nobody had decided on it.
#    It is gone. The node's env is ten variables; the eight the control plane has any
#    business knowing come from GET /device/v1/config, built from an explicit allowlist
#    (A4-D5/A4-D12), of which precisely one pair (EYES_M2M_*) is a secret. The other two
#    are node-local pins written here (the release tag and the registry it came from). And the image pull is authenticated
#    against OUR OWN door, so no GitHub credential reaches the node either (A4-D4).
#
# Args:
#   <factory-id>     The node's hub factory id (a UUID). Becomes the node's
#                    identity: written as EYES_FACTORY_ID and consumed by the
#                    config as factory.uuid (+ celery worker location). There are
#                    no per-factory config files — a new factory just installs
#                    with its id.
#   <enroll-credential>  The one-time device-enroll credential (epc-…), minted with
#                    scripts/eyes_device_admin.py. It authenticates the image pull (the
#                    door does NOT consume it for that) and is then redeemed once to
#                    enroll this node's identity. Falls back to the
#                    EYES_ENROLL_CREDENTIAL env var. OMIT IT ONLY on a reinstall of an
#                    already-enrolled node, which authenticates with its own identity.
#   [version]        Optional image tag to pin, e.g. v0.0.3. Defaults to
#                    `latest`, which CI keeps pointed at the newest v* build.
#   [updater-version]  The eyes-updater tag (updater-vX.Y.Z). REQUIRED on a first A4
#                    install and carried forward on every one after — see step 0c. There is
#                    no default: `updater-build.yml` publishes `updater-v*` tags only and
#                    deliberately never `latest`, so a default would name an image that
#                    does not exist. Falls back to the EYES_UPDATER_TAG env var.
#
# Deployment profile: `onsite` by default (real nodes). Override with
# EYES_PROFILE=dev for a laptop/webcam rig (see config/profile/).
#
# Requirements: docker (with the compose plugin) and curl. The daemon is reached directly
# if possible, else via sudo (when the user isn't in the docker group). That's it — no
# Doppler CLI, no python on the host, and the app image carries the code, config, ML
# model, and compose file. Site metadata is NOT in the image (A1.5): the node fetches its
# factory bundle from the control plane at boot.
#
# What it does:
#   1. Ask OUR OWN device door for a ~1h Artifact Registry pull token, `docker login`
#      with it, pull the eyes-app image, log out. No GitHub credential of any kind
#      reaches this node (A4-D4) and nothing durable is left in docker's config.json.
#   2. Rehydrate the RELEASE DIR from the image (compose + config). Site metadata is
#      NOT baked (A1.5): the node fetches it from the control plane at boot.
#   3. Enroll the device identity (A1) if the node isn't already enrolled: redeem the
#      one-time EYES_ENROLL_CREDENTIAL at the PUBLIC device door, writing the Ed25519 key
#      into $EYES_HOME/identity. Idempotent (skipped when already enrolled).
#   4. Fetch this node's resolved env from GET /device/v1/config and write
#      releases/<tag>/env. This is the ONLY place secrets come from.
#   5. Promote the release (current/previous symlinks) and `docker compose up -d`.
#
# Tunables (env): EYES_HOME (default: current dir), EYES_IMAGE_TAG (default latest),
#   EYES_ENROLL_CREDENTIAL (one-time device-enroll credential; may also be passed as the
#   second positional arg; unused once enrolled),
#   EYES_DEVICE_DOOR_URL (public device-door base URL; defaults to the live Cloud Run
#   door — it is not a secret),
#   EYES_REC_HOST / EYES_REC_CONTAINER (recordings dir overrides for a dev rig; normally
#   delivered per-device by /config instead).
#
set -euo pipefail

FACTORY_ID="${1:-}"
if [[ -z "$FACTORY_ID" ]]; then
  echo "usage: install.sh <factory-id> <enroll-credential> [version] [updater-version]" >&2
  exit 1
fi
# The one-time device-enroll credential ($2). It authenticates the image pull AND the
# enrollment — one credential for the whole bring-up (spec §8.2). Falls back to the
# EYES_ENROLL_CREDENTIAL env var (use a leading space or `export` so it stays out of shell
# history that way). Omit it ONLY when reinstalling an already-enrolled node, which
# authenticates with its own device identity instead (step 1).
EYES_ENROLL_CREDENTIAL="${2:-${EYES_ENROLL_CREDENTIAL:-}}"
# Deployment profile (config/profile/<name>.yaml). Real nodes are on-site; a dev
# laptop/webcam rig passes EYES_PROFILE=dev.
PROFILE="${EYES_PROFILE:-onsite}"

VERSION="${3:-${EYES_IMAGE_TAG:-latest}}"
# The eyes-updater pin. Resolved properly in step 0c (arg → env → carried forward); left
# empty here so the carry-forward can see whether one was passed at all.
UPDATER_TAG="${4:-${EYES_UPDATER_TAG:-}}"
# CI publishes linux/amd64. Real nodes are amd64; an Apple-Silicon dev box runs
# it under emulation. Matches the compose platform pin.
PLATFORM="${EYES_PLATFORM:-linux/amd64}"
EYES_HOME="${EYES_HOME:-$(pwd)}"
# Where the compose spec lives INSIDE the image (the docker cp source).
IMAGE_COMPOSE="docker/docker-compose.yml"
# Public device-door base URL. Defaults to the live Cloud Run door; override with the
# EYES_DEVICE_DOOR_URL env var. Non-secret. Needed EARLY now (A4-2): the image pull itself
# is authenticated against this door, not against a vendor registry.
DOOR_URL="${EYES_DEVICE_DOOR_URL:-https://eyes-device-door-rj72it466a-nn.a.run.app}"

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker is required." >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required." >&2; exit 1; }
# Use docker directly if we can reach the daemon; otherwise fall back to sudo
# (this user isn't in the docker group). Probe once; all docker calls below go
# through $DOCKER. sudo may prompt for a password on first use.
DOCKER="docker"
if ! docker info >/dev/null 2>&1; then
  if command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
    DOCKER="sudo docker"
    echo "==> docker needs elevated permissions here; using 'sudo docker'."
  else
    echo "ERROR: docker daemon is not reachable (tried with and without sudo)." >&2
    exit 1
  fi
fi

echo "==> Eyes node install: factory-id=$FACTORY_ID  profile=$PROFILE  home=$EYES_HOME  release=$VERSION"
umask 077
mkdir -p "$EYES_HOME"
cd "$EYES_HOME"

# ── 0. Release layout (A4-1, spec §6.1) ──────────────────────────────────────
# Stage the incoming release beside (not over) the running one, then promote by symlink
# at the very end. Nothing below touches identity/ or data/ — they are outside every
# release dir precisely so a revert cannot roll them back.
RELEASES="$EYES_HOME/releases"
RELEASE_DIR="$RELEASES/$VERSION"
IDENTITY_DIR="$EYES_HOME/identity"
CURRENT_LINK="$EYES_HOME/current"
PREVIOUS_LINK="$EYES_HOME/previous"
# The compose --env-file for THIS release. Replaces the old $EYES_HOME/docker/.env:
# compose auto-loaded that from the compose file's directory, which no longer works when
# the spec is versioned per release — so every invocation passes --env-file explicitly.
ENV_FILE="$RELEASE_DIR/env"

# The tag currently running, if any (readlink of `current`). Used for the `previous`
# symlink and to carry the machine id forward.
ACTIVE_TAG=""
if [[ -L "$CURRENT_LINK" ]]; then
  ACTIVE_TAG="$(basename "$(readlink "$CURRENT_LINK")")"
fi

# Re-staging the release that is currently RUNNING would rewrite a live stack's compose
# spec underneath it. A reinstall of the active tag is a legitimate repair operation
# though, so stop the stack first and stage from a clean slate.
if [[ -n "$ACTIVE_TAG" && "$ACTIVE_TAG" == "$VERSION" ]]; then
  echo "==> $VERSION is already the active release — stopping the stack to re-stage it."
  $DOCKER compose -f "$CURRENT_LINK/docker-compose.yml" --env-file "$CURRENT_LINK/env" down \
    >/dev/null 2>&1 || true
fi

# ── 0a. Read everything that must SURVIVE this install, before deleting anything ──
#
# THE INVARIANT (§1.2): nothing that must survive a reinstall may be read after the staging
# directory is removed. Add the next such value HERE, not to the step that consumes it.
#
# `$CURRENT_LINK` points at `releases/$ACTIVE_TAG`, so on a reinstall of the ACTIVE tag —
# the legitimate repair just above, and the path a broken node is sent down — the
# `rm -rf "$RELEASE_DIR"` below deletes the very file these values are read from. Each
# consumer resolved them itself, further down, and so got nothing: the install refused for
# want of an updater tag, and the machine id was silently regenerated. Both loops looked
# correct in isolation; the ordering is not visible from either one.
#
# This changes only WHEN the file is read. The resolution orders (argument → env →
# `current/env` → legacy `docker/.env`), the refusals and the error texts are unchanged.
prior_env_value() {
  # One key, out of the release being replaced, then the pre-A4 legacy docker/.env.
  local key="$1" prior value=""
  for prior in "$CURRENT_LINK/env" "$EYES_HOME/docker/.env"; do
    if [[ -z "$value" && -r "$prior" ]]; then
      value="$(sed -n "s/^$key=//p" "$prior" | tail -n1)"
    fi
  done
  printf '%s' "$value"
}
CARRIED_MACHINE_ID="$(prior_env_value EYES_MACHINE_ID)"
CARRIED_UPDATER_TAG="$(prior_env_value EYES_UPDATER_TAG)"
# The active release's image coordinates. Step 1 runs THAT image to mint a device bearer
# when an already-enrolled node is reinstalled without a credential — which is exactly the
# repair path, so the same deletion breaks it in the same way.
PRIOR_ENV_READABLE=""
PRIOR_REPO=""
PRIOR_TAG=""
if [[ -r "$CURRENT_LINK/env" ]]; then
  PRIOR_ENV_READABLE=1
  PRIOR_REPO="$(sed -n 's/^EYES_IMAGE_REPO=//p' "$CURRENT_LINK/env" | tail -n1)"
  PRIOR_TAG="$(sed -n 's/^EYES_IMAGE_TAG=//p' "$CURRENT_LINK/env" | tail -n1)"
fi

mkdir -p "$RELEASES" "$IDENTITY_DIR" "$EYES_HOME/var/ota"
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

# ── 0b. Seed the release env with NODE-LOCAL values only ─────────────────────
# A4-3: THE DOPPLER DOWNLOAD IS GONE. Nothing secret is written here — the node's
# secrets and its control-plane-known config arrive in step 4 from
# GET /device/v1/config, allowlisted (A4-D5/A4-D12). What remains in this file is only
# what the box itself knows: its factory binding, its shape, its release, its paths.
: > "$ENV_FILE"
chmod 600 "$ENV_FILE"
# Identity + profile are a BOOTSTRAP SEED, not an authority (§1.9, decided 2026-07-29).
# `/config` overwrites both in step 4 — the registry is what a node IS, and these arguments
# exist only so the box can reach the door in the first place. If they disagree, step 4 says
# so in a WARNING naming both values; a reported repoint is fine, a silent one is not.
#
# They used to be authoritative here, on the reasoning that a mis-set registry row must not
# repoint a node mid-install. But the updater's `_write_release_env` layers the opposite way,
# so that protection expired on the node's FIRST bump — which makes a comment claiming it
# worse than no comment at all. One rule, one source of truth, everywhere.
echo "EYES_FACTORY_ID=$FACTORY_ID" >> "$ENV_FILE"
echo "EYES_PROFILE=$PROFILE" >> "$ENV_FILE"
echo "EYES_IMAGE_TAG=$VERSION" >> "$ENV_FILE"
# Where compose finds this node's config/ and its persistent state (A4-1). Absolute, so
# the mount sources never depend on how the `current` symlink is resolved: config/ moves
# WITH the release, data/ and identity/ never do.
echo "EYES_CONFIG_HOST=$RELEASE_DIR/config" >> "$ENV_FILE"
echo "EYES_STATE_ROOT=$EYES_HOME" >> "$ENV_FILE"
[ -n "${EYES_REC_HOST:-}" ] && echo "EYES_REC_HOST=$EYES_REC_HOST" >> "$ENV_FILE"
[ -n "${EYES_REC_CONTAINER:-}" ] && echo "EYES_REC_CONTAINER=$EYES_REC_CONTAINER" >> "$ENV_FILE"
# Per-node machine id: seeds the node-general queue that this node's general
# workers share, so node-local work (commit aggregation, which writes the local
# bucket) runs on this node but off the dedicated inference workers. Unique per
# node so it never collides if nodes are ever pointed at a shared broker. Set
# EYES_MACHINE_ID in the Doppler config to pin a fixed value instead.
#
# A4-1: CARRIED FORWARD across releases. It used to live in docker/.env and survive
# by accident (the file was never rewritten wholesale); a per-release env file would
# rotate it on every bump instead, silently orphaning the node-general queue the
# previous release's commit batches were routed to. So take it, in order, from the
# release being replaced, then the legacy docker/.env, then mint a fresh one.
#
# Resolved in step 0a, above the staging `rm -rf` — on a same-version reinstall the file it
# comes from is inside the directory being staged (§1.2).
if ! grep -q '^EYES_MACHINE_ID=' "$ENV_FILE"; then
  if [[ -n "$CARRIED_MACHINE_ID" ]]; then
    echo "==> Carrying EYES_MACHINE_ID=$CARRIED_MACHINE_ID forward from the previous release."
    echo "EYES_MACHINE_ID=$CARRIED_MACHINE_ID" >> "$ENV_FILE"
  else
    echo "EYES_MACHINE_ID=node-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')" >> "$ENV_FILE"
  fi
fi

# ── 0c. The updater's own pin (§1.1) ─────────────────────────────────────────
# Exactly the same problem as EYES_MACHINE_ID above, and the same carry-forward, for the
# same reason: this file is written fresh per release, so anything not carried is LOST.
# What is lost here is worse, though, because the loss is silent and self-inflicting:
#
#   * eyes-updater has no `profiles:`, so it is part of the default `compose up -d` service
#     set. An unresolved pin means step 6 cannot resolve its image, `up -d` aborts the
#     WHOLE stack, and `set -euo pipefail` exits — AFTER step 5 promoted the symlinks. The
#     node is left with `current` pointing at the new release and nothing running, which is
#     precisely the state this script is the recovery floor FOR.
#   * `updater-build.yml` publishes `updater-v*` tags only and deliberately never `latest`,
#     so there is nothing sensible to default to (the compose file's `:-latest` fallbacks
#     are gone for that reason — an unset pin is now a parse error, not a tag that was
#     never published and, worse, one the updater would then propagate forward into every
#     release env it writes as if it were deliberate).
#   * the updater DOES preserve this across bumps it performs, so a node that has
#     self-updated and is then reinstalled would come back floating.
#
# Refusing without one is the point: a node silently running no updater is invisible from
# the control plane until someone pins a cohort and wonders why it never converges — the
# exact state A4 exists to eliminate.
#
# Resolved in step 0a for the same reason EYES_MACHINE_ID is (§1.2): `current/env` is inside
# the directory the staging `rm -rf` removes whenever the tag being installed is the one
# already running — which is the documented repair, i.e. the one install that must not refuse.
if [[ -z "$UPDATER_TAG" && -n "$CARRIED_UPDATER_TAG" ]]; then
  UPDATER_TAG="$CARRIED_UPDATER_TAG"
  echo "==> Carrying EYES_UPDATER_TAG=$UPDATER_TAG forward from the previous release."
fi
if [[ -z "$UPDATER_TAG" ]]; then
  echo "ERROR: no eyes-updater tag. This node would come up with no OTA at all — which is" >&2
  echo "       invisible from the control plane until someone pins a cohort and wonders why" >&2
  echo "       this node never converges. Refusing." >&2
  echo >&2
  echo "       Pass one as the FOURTH argument (or set EYES_UPDATER_TAG):" >&2
  echo "         install.sh $FACTORY_ID <enroll-credential> $VERSION updater-vX.Y.Z" >&2
  echo >&2
  echo "       Tags come from .github/workflows/updater-build.yml, which publishes" >&2
  echo "       'updater-v*' tags ONLY and never 'latest'. List what exists:" >&2
  echo "         gcloud artifacts docker images list \\" >&2
  echo "           northamerica-northeast1-docker.pkg.dev/eyes-buffer/eyes-fleet/eyes-updater \\" >&2
  echo "           --include-tags" >&2
  exit 1
fi
echo "EYES_UPDATER_TAG=$UPDATER_TAG" >> "$ENV_FILE"

# ── 1. Artifact Registry auth + pull (A4-2, A4-D4) ───────────────────────────
# NO GitHub credential of any kind reaches this node. The node presents its DEVICE
# identity to our own device door and gets back a ~1h Artifact Registry token scoped to
# the `eyes-fleet` repo — which holds only eyes-app and eyes-updater, never the
# control-plane image (§8.1).
#
# Two ways to authenticate that call, and which one applies is decided by what the box
# already has (spec §8.2, the bootstrap cycle):
#
#   * FRESH node — no identity yet, and enrollment runs INSIDE the image we are about to
#     pull. So the enroll credential the operator is already carrying authenticates the
#     pull, in plain curl (there is no local image to run Python in). The door does NOT
#     consume it; only /enroll does, so this stays ONE credential for the whole bring-up.
#   * REINSTALL of an enrolled node — mint a device bearer instead, which needs the
#     Ed25519 key and a JWT library, i.e. the app image. Run it inside the image the
#     PREVIOUS release left on the box (`python -m eyes.ota.door pull-token`).
#
# The minted token is spent immediately and we log out straight after: nothing durable,
# and no registry credential persisted in docker's config.json (which is exactly what the
# old GHCR login DID leave behind).
json_field() {
  # One flat JSON object, one string field. Deliberately not python3/jq — neither is a
  # guaranteed host dependency, and this response has no nesting.
  sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

PULL_JSON=""
if [[ -n "${EYES_ENROLL_CREDENTIAL:-}" ]]; then
  echo "==> Requesting an Artifact Registry pull token (enroll credential) from $DOOR_URL …"
  # The credential goes in the JSON BODY, never the URL or argv: a query string lands in
  # access logs and argv lands in `ps`.
  PULL_JSON="$(printf '{"credential":"%s"}' "$EYES_ENROLL_CREDENTIAL" | curl -fsS \
    -X POST -H 'Content-Type: application/json' --data-binary @- \
    "$DOOR_URL/device/v1/pull-token")" || {
    echo "ERROR: the device door refused the pull-token request." >&2
    echo "       Check the credential is un-consumed and unexpired (scripts/eyes_device_admin.py)." >&2
    exit 1
  }
elif [[ -n "$PRIOR_ENV_READABLE" ]]; then
  # Both read in step 0a, before the staging `rm -rf` could delete the file they come from
  # on a same-version reinstall (§1.2). Same values, same order, read earlier.
  if [[ -z "$PRIOR_REPO" || -z "$PRIOR_TAG" ]]; then
    echo "ERROR: no enroll credential, and the active release's env names no image to" >&2
    echo "       mint a device bearer with. Pass a credential as the SECOND arg." >&2
    exit 1
  fi
  echo "==> Requesting an Artifact Registry pull token (device identity, via $PRIOR_REPO/eyes-app:$PRIOR_TAG) …"
  PULL_JSON="$($DOCKER run --rm --platform "$PLATFORM" \
    -v "$IDENTITY_DIR:/app/identity:ro" \
    -e EYES_IDENTITY_DIR=/app/identity \
    "$PRIOR_REPO/eyes-app:$PRIOR_TAG" \
    python -m eyes.ota.door pull-token)" || {
    echo "ERROR: could not mint a pull token from this node's device identity." >&2
    echo "       Is the node revoked? Otherwise reissue a credential and pass it as arg 3:" >&2
    echo "       scripts/eyes_device_admin.py reissue <device-id>" >&2
    exit 1
  }
else
  echo "ERROR: this node has no active release and no EYES_ENROLL_CREDENTIAL, so it can" >&2
  echo "       neither mint a device bearer nor present a credential for the image pull." >&2
  echo "       Mint one and pass it as the SECOND arg:" >&2
  echo "         scripts/eyes_device_admin.py mint --device-type factory_node --factory-id $FACTORY_ID" >&2
  exit 1
fi

REGISTRY="$(printf '%s' "$PULL_JSON" | json_field registry)"
IMAGE_REPO="$(printf '%s' "$PULL_JSON" | json_field repository)"
PULL_USER="$(printf '%s' "$PULL_JSON" | json_field username)"
PULL_TOKEN="$(printf '%s' "$PULL_JSON" | json_field token)"
if [[ -z "$REGISTRY" || -z "$IMAGE_REPO" || -z "$PULL_TOKEN" ]]; then
  echo "ERROR: the pull-token response was missing registry/repository/token." >&2
  exit 1
fi
IMAGE="$IMAGE_REPO/eyes-app:$VERSION"
# The updater comes from the SAME repo the pull token named — `eyes-fleet` holds exactly
# these two images (§8.1), and pulling both against one credential is what keeps the spec
# and the credential unable to disagree.
UPDATER_IMAGE="$IMAGE_REPO/eyes-updater:$UPDATER_TAG"
# Where compose pulls from. The default in the compose file is GHCR (humans, local dev);
# a node resolves against the registry it just authenticated to, so the spec and the
# credential can never disagree. Keeping this in the release env rather than baked into
# the compose spec is also what makes swapping registries a deploy plus a bump (A4-Q1).
echo "EYES_IMAGE_REPO=$IMAGE_REPO" >> "$ENV_FILE"

echo "==> Pulling $IMAGE and $UPDATER_IMAGE …"
printf '%s' "$PULL_TOKEN" | $DOCKER login "$REGISTRY" -u "${PULL_USER:-oauth2accesstoken}" --password-stdin
# Log out no matter how either pull goes: a half-finished install must not leave a live
# registry credential in docker's config.json.
trap '$DOCKER logout "$REGISTRY" >/dev/null 2>&1 || true' EXIT
$DOCKER pull --platform "$PLATFORM" "$IMAGE"
# BOTH images inside the ONE login window. The token lives ~1h and we log out immediately
# after, so a later pull (step 6's `up -d`, which needs eyes-updater) has no credential —
# which is why this cannot be left to compose.
$DOCKER pull --platform "$PLATFORM" "$UPDATER_IMAGE" || {
  echo "ERROR: could not pull $UPDATER_IMAGE." >&2
  echo "       Does that tag exist? updater-build.yml publishes 'updater-v*' only:" >&2
  echo "         gcloud artifacts docker images list \\" >&2
  echo "           ${IMAGE_REPO}/eyes-updater --include-tags" >&2
  echo "       Nothing has changed on this node — the release is staged but not promoted." >&2
  exit 1
}
$DOCKER logout "$REGISTRY" >/dev/null 2>&1 || true
trap - EXIT
unset PULL_TOKEN PULL_JSON

# 2. Rehydrate the RELEASE DIR from the image (no git): compose + config.
#    The ML model lives inside the baked eyes/ package. Site metadata is NOT baked
#    (A1.5 / spec M4): the node boots blank and the command-listener fetches this
#    factory's current bundle from the control plane into data/metadata/ (a cache),
#    so a reinstall can no longer clobber pushed metadata with a stale git snapshot.
#    We create an EMPTY data/metadata so the volume mount + the worker gate have a
#    dir to watch; the fetch fills it (see EYES_METADATA_SOURCE / metadata gate).
#
#    A4-1: this writes releases/<tag>/ rather than overwriting $EYES_HOME/docker/ in
#    place. In-place overwrite is what made "retain the previous compose spec"
#    impossible — and retaining it is the whole mechanism of a revert (A4-D6).
echo "==> Extracting compose + config from the image into $RELEASE_DIR …"
cid="$($DOCKER create --platform "$PLATFORM" "$IMAGE")"
trap '$DOCKER rm -f "$cid" >/dev/null 2>&1 || true' EXIT
mkdir -p "$RELEASE_DIR/config" "$EYES_HOME/data"
$DOCKER cp "$cid:/app/$IMAGE_COMPOSE" "$RELEASE_DIR/docker-compose.yml"
$DOCKER cp "$cid:/app/config/." "$RELEASE_DIR/config/"
mkdir -p "$EYES_HOME/data/metadata" "$EYES_HOME/data/bucket" "$EYES_HOME/data/workdir" "$EYES_HOME/rec"

# 2b. Sanity-check the chosen profile now that the config is on disk. Identity
#     (EYES_FACTORY_ID) needs no lookup — it's the hub id, written verbatim above.
PROFILE_DIR="$RELEASE_DIR/config/profile"
if [[ -d "$PROFILE_DIR" && ! -f "$PROFILE_DIR/$PROFILE.yaml" ]]; then
  known="$(cd "$PROFILE_DIR" && ls -1 ./*.yaml 2>/dev/null | sed 's#.*/##; s#\.yaml$##' | tr '\n' ' ')"
  echo "ERROR: no config/profile/$PROFILE.yaml (known: ${known:-none})." >&2
  exit 1
fi

# 3. Device identity (A1) — single-call enrollment. The node authenticates to the
#     control plane with its OWN Ed25519 identity: the command-listener's boot-fetch
#     mints a bearer from it, and A2+ token consumers will too. Enrollment lives here so
#     bringing a node up is ONE install.sh call, and it is IDEMPOTENT:
#       * identity already on disk  -> leave it (reinstalls/upgrades never re-enroll and
#         need no credential);
#       * EYES_ENROLL_CREDENTIAL set -> redeem it at the PUBLIC device door, which writes
#         the key + door coords into $EYES_HOME/identity (root:root 0600, per keys.py).
#         The key is generated INSIDE the container and never leaves the box. The
#         credential is single-use and is piped in on STDIN (never argv or -e) so it can't
#         leak to `ps`/logs even when $DOCKER is `sudo docker`; the door consumes it on
#         success.
#       * neither -> WARN and continue: the stack still starts, but the metadata
#         boot-fetch parks (backs off) until a later install.sh enrolls it (order is
#         forgiving by design — spec M3).
#
#     NB (spec §8.2, the bootstrap cycle): enrollment runs INSIDE the app image, so the
#     image must already be pulled — which is why the pull above cannot itself require a
#     device identity. Step 2's enroll-credential path is what closes that loop without
#     any vendor credential: the credential authenticates the pull and is NOT consumed by
#     it, so the same credential is still redeemable here.
# ($DOOR_URL was resolved before step 2 — the pull itself is authenticated against it.)
# Is a COMPLETE identity already on disk? Check it with the SAME visibility enrollment
# has — root, inside the image, over the same mount. The identity dir is root-owned and
# 0700 (keys.py) and install commonly runs as a non-root user (docker via sudo), so a
# host-side `[ -f … ]` here can't even stat the files for lack of search permission on
# the dir: it would report the identity "absent" though it is present and send every
# reinstall back through enrollment, straight into the enroll step's "already enrolled"
# refusal (enroll.py, keys.key_exists). Running the check as container-root over the
# bind mount is exactly what enroll sees, so a spun-down-then-reinstalled node whose
# identity dir was kept is correctly recognized and skipped.
if $DOCKER run --rm --platform "$PLATFORM" -v "$IDENTITY_DIR:/app/identity" "$IMAGE" \
     sh -c 'test -f /app/identity/device_key.pem && test -f /app/identity/device.json'; then
  echo "==> Device identity already present ($IDENTITY_DIR) — skipping enrollment."
elif [[ -n "${EYES_ENROLL_CREDENTIAL:-}" ]]; then
  [[ -n "$DOOR_URL" ]] || { echo "ERROR: EYES_ENROLL_CREDENTIAL is set but no device-door URL. Set EYES_DEVICE_DOOR_URL (env or Doppler config)." >&2; exit 1; }
  echo "==> Enrolling device identity against ${DOOR_URL} …"
  if printf '%s\n' "$EYES_ENROLL_CREDENTIAL" | $DOCKER run --rm -i --platform "$PLATFORM" \
      -e EYES_DEVICE_DOOR_URL="$DOOR_URL" \
      -e EYES_IDENTITY_DIR=/app/identity \
      -e EYES_AGENT_VERSION="$VERSION" \
      -v "$IDENTITY_DIR:/app/identity" \
      "$IMAGE" \
      python -m eyes.device_identity.enroll --door-url "$DOOR_URL"; then
    echo "==> Enrolled — identity written to $IDENTITY_DIR."
  else
    echo "ERROR: enrollment failed (see the self-check table above). Mint or reissue a" >&2
    echo "       credential (scripts/eyes_device_admin.py) and re-run install.sh." >&2
    exit 1
  fi
else
  echo "WARNING: node is NOT enrolled and no EYES_ENROLL_CREDENTIAL was provided." >&2
  echo "         The stack will start, but the metadata boot-fetch will PARK until this" >&2
  echo "         node is enrolled. To enroll, mint a credential —" >&2
  echo "         scripts/eyes_device_admin.py mint --device-type factory_node --factory-id $FACTORY_ID —" >&2
  echo "         then re-run install.sh with the credential as the second arg:" >&2
  echo "         install.sh $FACTORY_ID epc-…  (the device door defaults; no URL needed)." >&2
fi

# ── 4. Fetch this node's resolved env from the control plane (A4-3, A4-D5) ────
# The step that replaces the prd_fleet dump. GET /device/v1/config returns the eight (and
# only eight) variables of this node's env that the control plane owns — the whole
# ALLOWLIST in services/frontdoor/device_config.py — so the control-plane secrets that used
# to land here (DATABASE_URL, and the ES256 signing key that could mint a token for ANY
# device) are structurally unable to appear. The rest of the node's ten-variable env is
# node-local: its release tag, registry, paths and machine id, written above and below.
#
# Run inside the app image because it needs the Ed25519 key + a JWT library to mint the
# bearer, neither of which exists on the host. It is bearer-only by design: by now the node
# is enrolled, so extending the credential's reach to cover this would buy nothing.
#
# Written OVER the node-local values seeded in step 0b (§1.9, decided 2026-07-29). **The
# registry wins, for every key it serves, everywhere.** This is the stronger form of A4-D5:
# an argument that can override central delivery is an argument that has to be re-passed by
# hand, which is the thing A4 exists to retire.
#
# It also makes install.sh and the updater's `_write_release_env` layer IDENTICALLY, which is
# the actual point. They used to disagree — install.sh's args beat /config, the updater's
# /config beat everything — so a `dev`-profile rig ran as `dev` right up until its first bump
# silently reconfigured it to `onsite` underneath whoever was watching. That changes which
# config/profile/*.yaml the whole stack loads and how EYES_METADATA_SOURCE behaves, i.e. it
# can park the workers on the metadata gate.
#
# The overlap is exactly EYES_FACTORY_ID, EYES_PROFILE, EYES_REC_HOST, EYES_REC_CONTAINER.
# The node-local pins (EYES_IMAGE_TAG, EYES_IMAGE_REPO, EYES_UPDATER_TAG, EYES_CONFIG_HOST,
# EYES_STATE_ROOT, EYES_MACHINE_ID) are not in the allowlist and therefore cannot collide, so
# this needs no key-by-key exception list.
#
# CONSEQUENCE, and it is an operational prerequisite: a rig that is not `onsite` must carry
# `node_env: {"EYES_PROFILE": "dev", …}` on its registry row BEFORE this runs, or the install
# itself repoints it. Mint can set that in one call, and the device modal can edit it (§1.12).
if $DOCKER run --rm --platform "$PLATFORM" -v "$IDENTITY_DIR:/app/identity:ro" \
     -e EYES_IDENTITY_DIR=/app/identity "$IMAGE" \
     sh -c 'test -f /app/identity/device_key.pem'; then
  echo "==> Fetching this node's env from $DOOR_URL/device/v1/config …"
  CONFIG_JSON="$($DOCKER run --rm --platform "$PLATFORM" \
    -v "$IDENTITY_DIR:/app/identity:ro" \
    -e EYES_IDENTITY_DIR=/app/identity \
    "$IMAGE" python -m eyes.ota.door config)" || {
    echo "ERROR: could not fetch this node's config from the device door." >&2
    echo "       The stack would start without its ingest credential, so refusing." >&2
    echo "       Check the node is in_service (Devices tab) and the door is reachable." >&2
    exit 1
  }
  # Flatten {"env": {...}} into KEY=VALUE lines. sed over a flat one-level object: the env
  # map is strings only (device_config.resolve stringifies), so there is no nesting to
  # mis-parse — and this keeps python off the host requirement list.
  CONFIG_ENV="$RELEASE_DIR/.config-env"
  : > "$CONFIG_ENV"
  chmod 600 "$CONFIG_ENV"
  printf '%s' "$CONFIG_JSON" \
    | sed -n 's/.*"env"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*/\1/p' \
    | tr ',' '\n' \
    | sed -n 's/^[[:space:]]*"\([A-Za-z_][A-Za-z0-9_]*\)"[[:space:]]*:[[:space:]]*"\(.*\)"[[:space:]]*$/\1=\2/p' \
    >> "$CONFIG_ENV"

  # THE DIVERGENCE REPORT (§1.9). Compared before the merge, because after it the seeded
  # value is gone. This is what keeps the protection the old arg-authoritative comment
  # CLAIMED — an operator standing at the box learns the node just got repointed — without
  # giving the argument a precedence it should not have. Silent divergence is the only
  # genuinely bad outcome here; a reported repoint is fine.
  CFG_FACTORY="$(sed -n 's/^EYES_FACTORY_ID=//p' "$CONFIG_ENV" | tail -n1)"
  CFG_PROFILE="$(sed -n 's/^EYES_PROFILE=//p' "$CONFIG_ENV" | tail -n1)"
  if [[ -n "$CFG_FACTORY" && "$CFG_FACTORY" != "$FACTORY_ID" ]]; then
    echo "WARNING: this node's REGISTRY ROW says factory '$CFG_FACTORY', but the command line" >&2
    echo "         said '$FACTORY_ID'. The registry wins — this node is being pointed at" >&2
    echo "         '$CFG_FACTORY'. If that is wrong, fix the device's factory binding" >&2
    echo "         (re-mint; it is an authorization fact, not a settable override) and re-run." >&2
    FACTORY_ID="$CFG_FACTORY"
  fi
  if [[ -n "$CFG_PROFILE" && "$CFG_PROFILE" != "$PROFILE" ]]; then
    echo "WARNING: this node's REGISTRY ROW says profile '$CFG_PROFILE', but the command line" >&2
    echo "         said '$PROFILE'. The registry wins — this node will run as '$CFG_PROFILE'," >&2
    echo "         which changes which config/profile/*.yaml the whole stack loads." >&2
    echo "         To run as '$PROFILE', set node_env {\"EYES_PROFILE\": \"$PROFILE\"} on the" >&2
    echo "         device (Devices tab → the device → Env overrides) and re-run install.sh." >&2
    PROFILE="$CFG_PROFILE"
  fi

  # The merge: /config OVERWRITES what step 0b seeded. Rewritten rather than appended, even
  # though both compose and layout.read_env take the last duplicate — an env file with two
  # EYES_PROFILE lines is a file that lies to the human reading it over SSH, and that human is
  # this file's entire audience.
  while IFS= read -r line; do
    key="${line%%=*}"
    [[ -n "$key" && "$key" != "$line" ]] || continue
    { grep -v "^${key}=" "$ENV_FILE" || true; } > "$ENV_FILE.merging"
    mv "$ENV_FILE.merging" "$ENV_FILE"
  done < "$CONFIG_ENV"
  cat "$CONFIG_ENV" >> "$ENV_FILE"
  rm -f "$CONFIG_ENV"
  chmod 600 "$ENV_FILE"
  unset CONFIG_JSON

  # Re-check the profile now that we know the EFFECTIVE one. Step 2b validated the argument,
  # which /config may just have overridden — and a node whose profile names a yaml that does
  # not exist in this release starts and then fails to load its config.
  if [[ -d "$PROFILE_DIR" && ! -f "$PROFILE_DIR/$PROFILE.yaml" ]]; then
    known="$(cd "$PROFILE_DIR" && ls -1 ./*.yaml 2>/dev/null | sed 's#.*/##; s#\.yaml$##' | tr '\n' ' ')"
    echo "ERROR: /config set EYES_PROFILE=$PROFILE, but this release has no" >&2
    echo "       config/profile/$PROFILE.yaml (known: ${known:-none})." >&2
    echo "       Fix the device's node_env override, or pin a release that has that profile." >&2
    exit 1
  fi
  # Loud, because a node without it silently produces no customer data: the ingest
  # credential is the one live secret /config delivers (A4-D9).
  if ! grep -q '^EYES_M2M_CLIENT_SECRET=' "$ENV_FILE"; then
    echo "WARNING: /config returned no EYES_M2M_* pair — this node cannot push to the" >&2
    echo "         Rise Hub ingest API. Check the device door's --set-secrets mount" >&2
    echo "         (deploy/frontdoor/deploy-device-door.sh, A4-D12)." >&2
  fi
else
  echo "WARNING: no device identity, so no /config fetch. The stack will start with only" >&2
  echo "         node-local env — no ingest credential — and the metadata boot-fetch will" >&2
  echo "         PARK. Enroll the node, then re-run install.sh." >&2
fi

# 5. Promote the staged release, then launch.
#    `previous` moves FIRST so a crash between the two renames leaves `current` still
#    pointing at the release that is actually running — the safe half-state. Both links
#    are RELATIVE (releases/<tag>): the updater writes them through its /host bind mount
#    and the daemon reads them on the host, and only a relative target resolves under both.
if [[ -n "$ACTIVE_TAG" && "$ACTIVE_TAG" != "$VERSION" ]]; then
  echo "==> Retaining $ACTIVE_TAG as the revert target (previous -> releases/$ACTIVE_TAG)."
  ln -sfn "releases/$ACTIVE_TAG" "$PREVIOUS_LINK"
fi
ln -sfn "releases/$VERSION" "$CURRENT_LINK"

# 6. Launch (compose pulls redis as needed; eyes-app is already local).
#    Always through `current`, always with an explicit --env-file: the project name is
#    pinned to `eyes` in the compose file, so this reconciles the SAME stack a previous
#    release started (containers whose spec changed are recreated, the rest are left
#    alone) rather than standing up a duplicate project.
echo "==> Starting the stack…"
$DOCKER compose -f "$CURRENT_LINK/docker-compose.yml" --env-file "$CURRENT_LINK/env" up -d

# ── 6b. Clear a terminal `failed` journal (§1.6) ──────────────────────────────
# The updater refuses every bump while `state == failed` — correctly, that is §7's bounded
# behaviour for a node that could run neither version. But nothing ever CLEARED it:
# `observe()` refreshes the position, not the state, and `recover()` returns early because
# `failed` is not in-flight. So this script — the documented escape from a failed node —
# restored the stack and left the node permanently OTA-frozen: polling, reporting,
# converging on nothing, forever. Which is discovered the way every failure of this class is:
# someone pins a cohort and wonders why one node never moves.
#
# MOVED, not edited: a `mv` needs no JSON parser on the host, it preserves the forensics of
# why the node failed, and it leaves the updater to rebuild a fresh `idle` journal from the
# symlinks on its next observe() — which is exactly what observe() is for. Done AFTER the
# stack is up, so a failed `up -d` leaves the evidence in place.
OTA_STATE="$EYES_HOME/var/ota/state.json"
if [[ -f "$OTA_STATE" ]]; then
  ARCHIVED="$OTA_STATE.pre-install-$(date +%s)"
  mv "$OTA_STATE" "$ARCHIVED"
  echo "==> Moved the previous updater journal aside → $(basename "$ARCHIVED")"
  echo "    (a terminal \`failed\` state would otherwise survive this install and keep the"
  echo "     node frozen out of OTA; the updater rebuilds a fresh one from the symlinks)."
fi

echo "==> Node up: factory-id=$FACTORY_ID profile=$PROFILE release=$VERSION updater=$UPDATER_TAG."
echo "    Logs:  $DOCKER compose -f $CURRENT_LINK/docker-compose.yml --env-file $CURRENT_LINK/env logs -f tasks"
if [[ -e "$EYES_HOME/docker/.env" ]]; then
  echo
  echo "    NOTE: a legacy $EYES_HOME/docker/ dir is still on this node from the"
  echo "          pre-A4 layout. It is no longer read. docker/.env holds the old"
  echo "          prd_fleet dump (incl. control-plane secrets) — wipe it as part of"
  echo "          the terminal rotation pass (deploy/frontdoor/A4_ROLLOUT_RUNBOOK.md)."
fi
