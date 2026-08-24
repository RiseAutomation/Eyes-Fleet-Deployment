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
#   6. Lay down the two HOST-level units (C10): a NIGHTLY REBOOT OF THE MACHINE at 03:00
#      local — a rescue hook for the Tailscale work, which takes the VMS down with it and is
#      meant to — and the bring-up that follows it. Both skip while an OTA bump is in flight.
#      Never fatal — a node that cannot reinstall because a timer exists is a bricked node.
#   7. Install the INDEPENDENT TAILNET PATH (C12): our own Tailscale beside the vendor's, so
#      reaching this box stops depending on a tailnet we do not control. The tree is lifted
#      out of the app image (/app/remote-access/) and installed to /opt/eyes-remote-access
#      with its own unit — SEPARATE LIFECYCLE, shared install moment only. Never fatal.
#      (Steps 6 and 7 here are steps 7 and 8 in the body, which numbers the launch separately.)
#
# Tunables (env): EYES_HOME (default: current dir), EYES_IMAGE_TAG (default latest),
#   EYES_ENROLL_CREDENTIAL (one-time device-enroll credential; may also be passed as the
#   second positional arg; unused once enrolled),
#   EYES_DEVICE_DOOR_URL (public device-door base URL; defaults to the live Cloud Run
#   door — it is not a secret),
#   EYES_REC_HOST / EYES_REC_CONTAINER (recordings dir overrides for a dev rig; normally
#   delivered per-device by /config instead),
#   EYES_SYSTEMD_DIR / EYES_LIBEXEC_DIR / EYES_HOST_CONF_DIR (where step 7 writes the host
#   units, the script they run and their EnvironmentFile; default /etc/systemd/system,
#   /usr/local/lib/eyes and /etc/eyes. Redirect them at a writable tree to install the units
#   without root — which is also how the suite exercises this step).
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
# An image already on this box that can mint a device bearer. Step 1 runs it when an
# already-enrolled node is reinstalled without a credential — the repair path, and also
# **every node's first A4 install**, which is the case this used to get wrong.
#
# A4-28: resolved through `prior_env_value`, i.e. `current/env` FIRST and then the pre-A4
# legacy `docker/.env` — the same chain the machine id and the updater tag already use, two
# lines above. Reading `current/env` alone made the gate below "is there an A4 release on
# this box", when the question it has to answer is "is there an image on this box we can run
# Python in". On a pre-A4 node those differ: there is no `current` symlink at all, so the
# script refused an enrolled node whose identity was sitting right there in identity/ and
# whose image was sitting right there in `docker images` — the exact migration A4 exists to
# perform, on every node in the fleet.
#
# EYES_IMAGE_REPO is absent from a pre-A4 `docker/.env` (the compose spec's own default
# supplied it), so fall back to that same default rather than treating "no repo named" as
# "no image". The default is GHCR deliberately: a pre-A4 node's image came from GHCR, which
# is also why the GHCR PAT stays alive until the fleet has soaked (Stage 7a).
PRIOR_REPO="$(prior_env_value EYES_IMAGE_REPO)"
PRIOR_TAG="$(prior_env_value EYES_IMAGE_TAG)"
PRIOR_REPO="${PRIOR_REPO:-ghcr.io/riseautomation}"
# The gate for the bearer-minting path: a tag to run, whose image is actually PRESENT. The
# presence check is the point — the local image is what makes this work with no registry
# credential of any kind, so "named but not on the box" has to fail here, with that said,
# rather than as an opaque `docker run` pull attempt against a registry we cannot authenticate.
PRIOR_IMAGE=""
if [[ -n "$PRIOR_TAG" ]] \
   && $DOCKER image inspect "$PRIOR_REPO/eyes-app:$PRIOR_TAG" >/dev/null 2>&1; then
  PRIOR_IMAGE="$PRIOR_REPO/eyes-app:$PRIOR_TAG"
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
elif [[ -n "$PRIOR_IMAGE" ]]; then
  # Resolved in step 0a, before the staging `rm -rf` could delete the file they come from on
  # a same-version reinstall (§1.2). A4-28: `$PRIOR_IMAGE` is any eyes-app image already on
  # the box — from `current/env` on an A4 node, from the legacy `docker/.env` on a pre-A4 one
  # — so this branch covers the first A4 install of an enrolled node, not just an A4-to-A4
  # reinstall.
  #
  # Gated on the IMAGE alone, and deliberately not also on a host-side `-r identity/device.json`:
  # identity/ is root-owned 0700 (keys.py) while install commonly runs as a non-root user with
  # docker-via-sudo, so a host-side stat cannot even search the directory and would report a
  # present identity as absent. That is the exact trap the enrollment check below is written
  # around, and it must not be reintroduced here. Whether an identity exists is settled by
  # MINTING with it, in-image, over the same mount — so the failure path says so instead.
  echo "==> Requesting an Artifact Registry pull token (device identity, via $PRIOR_IMAGE) …"
  # `eyes.ota.door` is the intended path and the one the suite covers — but it only exists in
  # an A4 image, and on every node's FIRST A4 install `$PRIOR_IMAGE` is by definition the
  # PRE-A4 image, which has no `eyes.ota` package at all (A4-28). So try the module, then fall
  # back to the same two calls spelled out against `eyes.device_identity`, which has been in
  # the image since A1: mint a bearer off the Ed25519 key, POST it to /pull-token. The door
  # base comes from the identity's own persisted `token_url` — the same source
  # `door.identity_door_base()` reads — so the fallback cannot reach a different door than
  # the module would have.
  PORTABLE_MINT='
import json, sys, httpx
from eyes.device_identity.tokens import get_token
try:
    from eyes.device_identity.keys import load_identity
    base = load_identity().token_url.rsplit("/", 1)[0]
except Exception:
    base = sys.argv[1].rstrip("/") + "/device/v1"
r = httpx.post(base + "/pull-token", json={},
               headers={"Authorization": "Bearer " + get_token()}, timeout=30.0)
r.raise_for_status()
json.dump(r.json(), sys.stdout)
'
  mint_in_image() {
    $DOCKER run --rm --platform "$PLATFORM" \
      -v "$IDENTITY_DIR:/app/identity:ro" \
      -e EYES_IDENTITY_DIR=/app/identity \
      "$PRIOR_IMAGE" "$@"
  }
  PULL_JSON="$(mint_in_image python -m eyes.ota.door pull-token 2>/dev/null)" || PULL_JSON=""
  if [[ -z "$PULL_JSON" ]]; then
    echo "    (that image predates eyes.ota — minting via eyes.device_identity instead)"
    PULL_JSON="$(mint_in_image python -c "$PORTABLE_MINT" "$DOOR_URL")" || {
      echo "ERROR: could not mint a pull token from this node's device identity, using" >&2
      echo "       $PRIOR_IMAGE. Three things do this, in order of likelihood:" >&2
      echo "         * the node is NOT enrolled — no $IDENTITY_DIR/device_key.pem, so there" >&2
      echo "           is nothing to mint with. This is a first bring-up: pass a credential." >&2
      echo "         * the node's device identity is revoked or its factory is out of service." >&2
      echo "         * the device door is unreachable from this box ($DOOR_URL)." >&2
      echo "       Mint or reissue a credential and pass it as the SECOND arg:" >&2
      echo "         scripts/eyes_device_admin.py reissue <device-id>" >&2
      exit 1
    }
  fi
else
  # No credential AND no local eyes-app image: there is nothing on this box that can run the
  # minting code, so a credential is genuinely required. This is a first bring-up.
  echo "ERROR: no EYES_ENROLL_CREDENTIAL, and no eyes-app image is on this box to mint a" >&2
  echo "       device bearer with, so the image pull cannot be authenticated." >&2
  echo "       Looked for '$PRIOR_REPO/eyes-app:${PRIOR_TAG:-<no EYES_IMAGE_TAG in current/env or docker/.env>}'" >&2
  echo "       (from current/env, then the pre-A4 docker/.env)." >&2
  echo "       Mint a credential and pass it as the SECOND arg:" >&2
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

# ── 7. Host-level units: the nightly reboot and the bring-up after it (C10) ──
# Two jobs that must outlive any single release, so they live on the HOST rather than in a
# release dir — a revert must not be able to silently uninstall a scheduled job, and a stack
# that did not come back after a reboot must not depend on the release that failed to.
#
#   eyes-nightly-reboot.timer    03:00 node-local, jittered, fires
#   eyes-nightly-reboot.service  which reboots THE MACHINE.
#   eyes-stack.service           `compose up -d` through current/ on the way back up.
#
# **THIS ONE REBOOTS THE HOST, AND THAT IS THE POINT.** It is not a stack restart and must not
# be softened into one. It exists as a RESCUE HOOK: C11/C12 add our own Tailscale beside the
# vendor's on a box whose only remote access is that vendor's tailnet, so the failure mode
# being designed against is "we lose the route in and nobody can walk to the machine". A
# reboot is the only thing that recovers a box from that class of mistake, because it discards
# every piece of running state that was never persisted — a daemon in a namespace, iptables
# chains, a rewritten resolv.conf.
#
# Two consequences worth being explicit about, because both are easy to forget later:
#
#   * **It takes the VMS vendor's appliance down with it, nightly.** This machine is theirs
#     with our stack added to it. That was a deliberate, explicitly-taken decision, not an
#     oversight — anyone who finds this and thinks it looks reckless is reading it correctly
#     and should go and ask rather than quietly weaken it.
#   * **A reboot only rescues what was never persisted.** A bad committed config comes back
#     exactly as broken. This buys back a box wedged by a live experiment, not one wedged by
#     something written to disk.
#
# THE INTERLOCK. eyes/ota/gate.py runs a three-phase health gate after a swap, budgeted at up
# to ~28 minutes (T_boot 180 s + T_live 300 s + T_pipe 1200 s). A reboot landing in that window
# fails it exactly as a restart would — the updater itself survives (its journal is crash-safe
# precisely because a host reboot mid-bump was always possible) but the GATE does not, and the
# result is a healthy release reverted at 03:00 with nobody watching. So the job reads
# var/ota/state.json and skips the night when a bump is in flight. It only ever READS it: the
# updater is that file's single writer (eyes/ota/journal.py) and that invariant is what makes
# its crash-recovery reasoning sound.
#
# …but the interlock must not be able to disable the rescue, which is the whole reason the
# thing exists. So an in-flight state that is OLDER than any bump could legitimately be is
# treated as a wedged updater rather than as a live bump, and the reboot proceeds (loudly). A
# reboot is good medicine for a wedged updater anyway.
#
# The units name $EYES_HOME/current/…, which is stable across every bump and revert, so
# nothing installed here changes with a release. The one per-node fact — $EYES_HOME itself,
# /home/valtorvms/Rise/Eyes in production and not /opt/eyes — goes in an EnvironmentFile, so
# the units and the script are byte-identical on every node.
#
# THIS STEP MAY NEVER FAIL THE INSTALL. install.sh is also the recovery path for a node that
# can run neither release, and a node that cannot reinstall because a timer already exists (or
# because this box has no systemd, or because sudo is unavailable) is a node we have bricked.
# Every failure below is a WARNING naming what to do by hand, and the install continues.
# It is also idempotent: the unit files are rewritten wholesale and `systemctl enable` is a
# symlink at a fixed path, so a reinstall leaves exactly one timer.
#
# Root is REQUIRED here and there is no way around it: nothing inside a container can reboot
# the host it runs on. install.sh already probes for docker-via-sudo (step 1); this needs the
# same escalation for systemctl, which is not necessarily the same sudoers grant.
#
# Run LAST, after the stack is up, for the same reason §6b's move-aside is: a failed launch
# should leave the box in a state the operator can reason about, not one this step has since
# scheduled a reboot against.
UNIT_DIR="${EYES_SYSTEMD_DIR:-/etc/systemd/system}"
LIBEXEC_DIR="${EYES_LIBEXEC_DIR:-/usr/local/lib/eyes}"
HOST_CONF_DIR="${EYES_HOST_CONF_DIR:-/etc/eyes}"

install_host_units() {
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "WARNING: no systemctl on this host, so the nightly reboot and the after-reboot" >&2
    echo "         bring-up were NOT installed. The stack itself is up and unaffected." >&2
    echo "         Everything else on this box is unchanged." >&2
    return 1
  fi

  # These land outside $EYES_HOME, so they need root — and install.sh commonly runs as a
  # non-root user with docker-via-sudo (step 1 assumes exactly that). Probe the same way
  # $DOCKER is probed: try direct, fall back to sudo. Probing with a real write rather than
  # `mkdir -p`, which succeeds on an existing directory whether or not it is writable.
  AS_ROOT=""
  probe="$UNIT_DIR/.eyes-write-probe.$$"
  if mkdir -p "$UNIT_DIR" 2>/dev/null && : > "$probe" 2>/dev/null; then
    rm -f "$probe"
  elif command -v sudo >/dev/null 2>&1 && sudo mkdir -p "$UNIT_DIR" 2>/dev/null; then
    AS_ROOT="sudo"
  else
    echo "WARNING: cannot write $UNIT_DIR (not root, and sudo is unavailable), so the" >&2
    echo "         nightly reboot and the after-reboot bring-up were NOT installed." >&2
    echo "         Re-run this install as root to add them. The stack is up regardless." >&2
    echo "         NB a sudoers policy that grants only 'docker' is enough for every other" >&2
    echo "         step of this install and not enough for this one." >&2
    return 1
  fi
  $AS_ROOT mkdir -p "$LIBEXEC_DIR" "$HOST_CONF_DIR" || return 1

  # <path> <mode>, content on stdin. Staged and then `install`ed into place, so systemd can
  # never execute a half-written file, and so the destination is owned by whoever `$AS_ROOT`
  # makes us (root on a node) rather than by the user who happened to run the install.
  install_file() {
    staged="$(mktemp)" || return 1
    cat > "$staged"
    $AS_ROOT install -m "$2" "$staged" "$1" || { rm -f "$staged"; return 1; }
    rm -f "$staged"
  }

  install_file "$HOST_CONF_DIR/node.env" 0644 <<EYES_NODE_ENV || return 1
# Written by scripts/install.sh. The one per-node fact the Eyes host units need: everything
# else they touch hangs off it. \$EYES_HOME differs per node — /home/valtorvms/Rise/Eyes in
# production, not /opt/eyes — which is why it is here and not baked into the units.
EYES_HOME=$EYES_HOME
EYES_NODE_ENV

  install_file "$LIBEXEC_DIR/eyes-host.sh" 0755 <<'EYES_HOST_SH' || return 1
#!/bin/sh
#
# Eyes host jobs — the two that outlive any single release (C10/RIS-99).
#
#   eyes-host.sh nightly-reboot   REBOOT THE MACHINE at 03:00 node-local.
#   eyes-host.sh boot             bring the compose stack back up afterwards: `up -d`
#                                 through current/, which starts whatever the daemon's
#                                 restart policies did not.
#
# THE REBOOT IS DELIBERATE AND IS THE POINT OF THIS FILE. It is a RESCUE HOOK. C11/C12 put our
# own Tailscale on a box whose only remote access is the VMS vendor's tailnet, so the failure
# being designed against is "we lose the route in and nobody can walk to the machine". A
# reboot is the one thing that recovers a box from that, because it discards every piece of
# running state that was never persisted — a daemon in a namespace, iptables chains, a
# rewritten resolv.conf. It does NOT rescue a bad committed config, which comes back as broken
# as it went down.
#
# It also takes the vendor's VMS down with it, nightly. That is a decision that was taken with
# its eyes open, not an accident. If it looks reckless to you, you are reading it correctly —
# go and ask, rather than quietly softening it into a stack restart.
#
# THE INTERLOCK. eyes/ota/gate.py runs a three-phase gate after a swap — T_boot 180 s +
# T_live 300 s + T_pipe 1200 s, so up to ~28 minutes. A reboot inside that window fails it by
# construction: containers go `restarting` (phase 1), the command-listener's poll beacon is
# delayed (phase 2), and the frames-processed counter stops advancing (phase 3, where an
# unreadable counter is a deliberate FAIL, not a skip). The updater itself survives — its
# journal is crash-safe precisely because a host reboot mid-bump was always possible — but the
# gate does not, and the consequence is a healthy release reverted at 03:00 with nobody
# watching. So: read the updater's journal first, and SKIP THE NIGHT when a bump is in flight.
#
# Skip, never defer. A reboot moved to 03:25 is the same reboot with a worse alibi.
#
# BUT THE INTERLOCK MUST NOT BE ABLE TO DISABLE THE RESCUE. An in-flight state older than any
# bump could legitimately be is a wedged updater, not a live bump, and the reboot proceeds —
# loudly. A reboot is good medicine for a wedged updater in any case.
#
# var/ota/state.json is READ-ONLY here. The updater is its single writer (eyes/ota/journal.py)
# and that invariant is what makes its crash-recovery reasoning sound; a reboot script is not a
# good enough reason to add a second writer.
#
# Installed by scripts/install.sh into /usr/local/lib/eyes/, OUTSIDE every release dir, and
# driven by eyes-nightly-reboot.timer / eyes-stack.service. It refers only to
# $EYES_HOME/current/, which is stable across every bump and revert, so this file never
# changes with a release. $EYES_HOME arrives from /etc/eyes/node.env.
set -eu

MODE="${1:-}"
case "$MODE" in
  boot|nightly-reboot) ;;
  *) echo "usage: eyes-host.sh <boot|nightly-reboot>" >&2; exit 2 ;;
esac

: "${EYES_HOME:?EYES_HOME is unset — it comes from /etc/eyes/node.env, which install.sh writes}"

COMPOSE_FILE="$EYES_HOME/current/docker-compose.yml"
RELEASE_ENV="$EYES_HOME/current/env"
OTA_STATE="$EYES_HOME/var/ota/state.json"

# How long `boot` waits for the daemon. After=docker.service only means the unit started.
DOCKER_WAIT_S="${EYES_DOCKER_WAIT_S:-180}"

# A bump cannot legitimately be in flight for longer than this: the gate budgets total ~28 min
# and the pull is bounded at 3600 s (dockercli.PULL_TIMEOUT_S), so ~1.5 h is the honest worst
# case for a slow site uplink. Past four hours the journal is describing a bump that is not
# happening, and refusing to reboot on that basis would let a wedged updater switch off the
# rescue hook — the one failure this whole unit exists to survive.
STALE_IN_FLIGHT_S="${EYES_STALE_IN_FLIGHT_S:-14400}"

# Do not reboot a machine that has only just come up. Nothing here should be able to produce a
# reboot LOOP: a box that reboots every few minutes is unreachable for good, and unreachable
# for good is precisely the outcome this unit is the insurance against. `Persistent=false` on
# the timer is the other half of that (no catch-up firing the instant a box boots).
MIN_UPTIME_S="${EYES_MIN_UPTIME_S:-1800}"

log()  { echo "eyes-host[$MODE]: $*"; }
warn() { echo "eyes-host[$MODE]: $*" >&2; }

# A4-35: compose gives the PROCESS ENVIRONMENT precedence over --env-file when it interpolates
# the spec, and the release env is the sole authority for this pin. systemd hands us a clean
# environment, but a hand-run from a shell that exported one must not be able to resolve a
# different updater image than the file names.
unset EYES_UPDATER_TAG

# Always through current/, always with an explicit --env-file — the invariant install.sh and
# the updater already hold (install.sh §6). The project name is pinned to `eyes` in the spec,
# so this reconciles the SAME stack rather than standing up a second one. And EYES_UPDATER_TAG
# has no default, so an invocation that forgot the env file is a compose PARSE ERROR: loud,
# immediate, and on the right box.
compose() { docker compose -f "$COMPOSE_FILE" --env-file "$RELEASE_ENV" "$@"; }

release_env_value() {
  # One key out of the release env. sed, deliberately not a parser — there is no python on the
  # host (docs/node-lifecycle.md) and this file is KEY=VALUE lines. Same idiom install.sh's
  # own `prior_env_value` uses.
  [ -r "$RELEASE_ENV" ] || return 1
  sed -n "s/^$1=//p" "$RELEASE_ENV" | tail -n1
}

require_release() {
  # `boot` only. The nightly reboot deliberately does NOT require a working release: a box
  # whose Eyes install is broken is exactly the box that most needs its rescue hook to fire.
  if [ ! -r "$COMPOSE_FILE" ]; then
    warn "no compose spec at $COMPOSE_FILE. Is EYES_HOME ($EYES_HOME) right, and has"
    warn "install.sh ever run here? Doing nothing."
    exit 1
  fi
  if [ ! -r "$RELEASE_ENV" ]; then
    warn "no release env at $RELEASE_ENV. Doing nothing — EYES_UPDATER_TAG has no default,"
    warn "so a compose invocation without that file cannot even parse the spec."
    exit 1
  fi
}

# ── The interlock ───────────────────────────────────────────────────────────────────────
# Five verdicts: absent | clear | stale-in-flight | in-flight | unreadable. The first three
# proceed; the last two do not.
#
# `absent` and `unreadable` are deliberately NOT the same answer. A node with no journal has
# never bumped and is therefore plainly not mid-bump; a journal that exists and cannot be read
# is not evidence of anything, least of all of safety.
#
# That is the OPPOSITE default from Journal.read(), which degrades an unparsable file to
# `idle`. Both are right: the updater refusing to start over a corrupt journal would turn one
# bad write into a node that needs SSH, whereas our failure mode is not "stand down" but
# "reboot the machine in the middle of a health gate".

# Mirrors journal.State.in_flight exactly, so the two cannot drift, plus the staleness escape.
# A self-update `handoff` is deliberately NOT in-flight: it is decided by the updater's own
# beacon, which a reboot re-establishes rather than breaks, and a stale stamp would otherwise
# suppress the reboot silently.
#
# Age is measured from `started_at` (when the bump began) rather than `updated_at`, which the
# updater refreshes every tick with its container snapshot — so `updated_at` stays young on a
# node that has been stuck in `bumping` for hours, i.e. on exactly the node this is for. An
# age that cannot be determined at all counts as FRESH: the file says a bump is in flight and
# nothing contradicts it, and a false revert is worse than a rescue delayed by a day.
PARSE_STATE_PY='
import json, sys, time
STALE = float(sys.argv[1])
try:
    with open("/s/state.json") as fh:
        data = json.load(fh)
except Exception:
    print("unreadable"); sys.exit(0)
if not isinstance(data, dict) or "state" not in data:
    print("unreadable"); sys.exit(0)
if data["state"] not in ("bumping", "reverting"):
    print("clear"); sys.exit(0)
try:
    started = float(data.get("started_at") or data.get("updated_at") or 0)
except (TypeError, ValueError):
    started = 0.0
age = time.time() - started
print("stale-in-flight" if started > 0 and age > STALE else "in-flight")
'

verdict_via_updater_image() {
  # The preferred read: a real JSON parse, run inside the image that is already on this box
  # and already pinned, whose stdlib is the same one that WROTE the file. Zero new host
  # dependencies (there is no python on the host).
  repo="$(release_env_value EYES_IMAGE_REPO)" || return 1
  tag="$(release_env_value EYES_UPDATER_TAG)" || return 1
  [ -n "$repo" ] && [ -n "$tag" ] || return 1
  image="$repo/eyes-updater:$tag"
  # Local images ONLY. This box authenticates pulls with a ~1 h token it does not hold, so a
  # pull attempt would stall or fail rather than help.
  docker image inspect "$image" >/dev/null 2>&1 || return 1
  out="$(docker run --rm --network none -v "$EYES_HOME/var/ota:/s:ro" \
         "$image" python -c "$PARSE_STATE_PY" "$STALE_IN_FLIGHT_S" 2>/dev/null)" || return 1
  case "$out" in
    in-flight|stale-in-flight|clear|unreadable) printf '%s' "$out" ;;
    *) return 1 ;;
  esac
}

verdict_via_grep() {
  # The fallback, for when the daemon or the image cannot answer — which includes the boot
  # path, where the daemon may be the thing that is unwell.
  #
  # journal._atomic_write_json writes json.dumps(indent=2, sort_keys=True), so the journal's
  # own `state` is the only key at indent 2 spelled that way. THE INDENT ANCHOR IS
  # LOAD-BEARING: `gate_detail` carries a per-container `"state"` nested deeper, and
  # `gate_detail` sorts BEFORE `state` at the top level, so an unanchored grep reads a
  # container's state and answers confidently wrong.
  #
  # Coupled to that formatting on purpose, and fenced by a test that writes the file with the
  # real Journal and reads it back with this function. If the shape ever changes, nothing
  # matches and the answer is `unreadable` — a loud skip, never a silent reboot.
  line="$(grep -E '^  "state": ' "$OTA_STATE" 2>/dev/null | head -n1)" || line=""
  case "$line" in
    *'"idle"'*|*'"failed"'*)       echo clear;      return 0 ;;
    *'"bumping"'*|*'"reverting"'*) ;;
    *)                             echo unreadable; return 0 ;;
  esac
  # In flight — but for how long? Integer seconds only; the fractional part is noise at this
  # scale and POSIX sh cannot do float arithmetic anyway.
  started="$(grep -E '^  "started_at": ' "$OTA_STATE" 2>/dev/null | head -n1 \
             | sed -n 's/.*: *\([0-9]*\).*/\1/p')" || started=""
  if [ -n "$started" ] && [ "$started" -gt 0 ] 2>/dev/null \
     && [ "$(( $(date +%s) - started ))" -gt "$STALE_IN_FLIGHT_S" ] 2>/dev/null; then
    echo stale-in-flight
  else
    echo in-flight
  fi
}

ota_verdict() {
  [ -f "$OTA_STATE" ] || { echo absent; return 0; }
  verdict="$(verdict_via_updater_image)" && { printf '%s\n' "$verdict"; return 0; }
  verdict_via_grep
}

interlock_or_exit() {
  case "$(ota_verdict)" in
    absent)
      log "no updater journal at $OTA_STATE — a node that has never bumped is not mid-bump. Proceeding." ;;
    clear)
      log "the updater journal reports no bump in flight. Proceeding." ;;
    stale-in-flight)
      warn "the updater journal says a bump is in flight, but it started more than"
      warn "${STALE_IN_FLIGHT_S}s ago — longer than any bump can legitimately take. Treating"
      warn "the updater as WEDGED rather than busy, and proceeding: a stuck journal must not"
      warn "be able to switch off this node's rescue hook, and a reboot is good medicine for a"
      warn "wedged updater. Look at $OTA_STATE." ;;
    in-flight)
      log "SKIPPING: an OTA bump or revert is IN FLIGHT ($OTA_STATE)."
      log "Acting now would fail the post-swap health gate and revert a release that is very"
      log "probably healthy. Skipping this run entirely rather than deferring it."
      exit 0 ;;
    unreadable)
      warn "SKIPPING: $OTA_STATE exists but could not be read, so whether a bump is in flight"
      warn "is unknown — and an unparsable journal is not evidence of safety. Skipping, and"
      warn "failing loudly so this shows up in \`systemctl --failed\` rather than as a node"
      warn "that quietly never reboots. Look at the file; the updater owns it."
      exit 1 ;;
  esac
}

uptime_s() {
  # /proc/uptime is "<seconds since boot> <idle>"; the integer part is plenty. Overridable so
  # the suite can exercise the loop guard on a dev box that has no /proc — the guard is the one
  # piece of this whose failure mode is an unreachable machine, so it does not go untested for
  # want of a Linux laptop. Unreadable means "cannot tell", and the guard then stands aside:
  # a rescue hook that refuses to fire because it could not stat a file is not a rescue hook.
  uptime_file="${EYES_UPTIME_FILE:-/proc/uptime}"
  [ -r "$uptime_file" ] || { echo ""; return 0; }
  cut -d' ' -f1 "$uptime_file" | cut -d. -f1
}

wait_for_docker() {
  waited=0
  while ! docker info >/dev/null 2>&1; do
    if [ "$waited" -ge "$DOCKER_WAIT_S" ]; then
      warn "the docker daemon did not answer within ${DOCKER_WAIT_S}s. Doing nothing."
      return 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
  if [ "$waited" -gt 0 ]; then log "the docker daemon answered after ${waited}s."; fi
}

do_boot() {
  # `up -d`, not `restart`: after a reboot some containers may not exist at all, and this is
  # the same reconcile install.sh §6 performs. The container restart policies bring most of the
  # stack back on their own; this closes what they cannot — `command-listener` is
  # `restart: on-failure`, so a clean exit stays stopped, and a container that never existed
  # has no policy at all. With a reboot happening EVERY night, that gap would be a nightly one.
  #
  # It is safe here and would not be in a scheduled job, precisely because of the interlock:
  # recreating containers re-reads the spec and the env file, which is a release operation, and
  # the one moment those disagree with what is running is mid-bump.
  #
  # No service list, so eyes-updater comes back too — at boot that is the point.
  wait_for_docker || exit 1
  require_release
  interlock_or_exit
  log "reconciling the stack from $COMPOSE_FILE"
  compose up -d
  log "the stack is up."
}

do_nightly_reboot() {
  up="$(uptime_s)"
  if [ -n "$up" ] && [ "$up" -lt "$MIN_UPTIME_S" ] 2>/dev/null; then
    log "SKIPPING: this machine has only been up ${up}s (floor ${MIN_UPTIME_S}s)."
    log "Rebooting a box that has only just come up buys nothing, and a reboot loop on a"
    log "machine nobody can walk up to is unrecoverable. This is that guard."
    exit 0
  fi
  interlock_or_exit
  # Deliberately NOT stopping the stack first. systemd stops docker.service on the way down,
  # which SIGTERMs every container; Celery's task_acks_late + task_reject_on_worker_lost
  # (eyes/entrypoint.py) mean a task in flight when its worker dies is redelivered rather than
  # lost, so a graceful drain would buy nothing but a longer window.
  log "REBOOTING THIS MACHINE NOW (nightly, 03:00 local, C10/RIS-99)."
  log "The stack comes back via the container restart policies plus eyes-stack.service."
  systemctl reboot
}

case "$MODE" in
  boot)           do_boot ;;
  nightly-reboot) do_nightly_reboot ;;
esac
EYES_HOST_SH

  install_file "$UNIT_DIR/eyes-stack.service" 0644 <<'EYES_STACK_SERVICE' || return 1
[Unit]
# Brings the Eyes compose stack back after the host reboots — which, since C10, is EVERY
# night. That makes this unit load-bearing rather than an insurance policy: the container
# restart policies restore most of the stack when the daemon starts, but `command-listener` is
# `restart: on-failure` so a clean exit stays stopped, and a container that never existed has
# no policy at all. `up -d` is idempotent, so on the boot where the policies did their job this
# does nothing.
Description=Eyes stack (bring the compose stack up after a host reboot)
# `Wants`, deliberately NOT `Requires`. This box is the VMS vendor's appliance and how their
# docker is packaged is not ours to assume: under snap the unit is `snap.docker.dockerd`, not
# `docker.service`, and `Requires=` a unit that does not exist makes THIS unit fail outright —
# so a naming difference we do not control would turn the after-reboot bring-up into a unit
# that silently never runs. `Wants` orders us behind it when it exists and is harmless when it
# does not; the real dependency is the daemon answering, which eyes-host.sh waits for and
# reports on. (Observed: `Failed to start eyes-stack.service: Unit docker.service not found`.)
Wants=docker.service network-online.target
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=/etc/eyes/node.env
ExecStart=/usr/local/lib/eyes/eyes-host.sh boot
# Generous: the script waits for the daemon, and `up -d` on a cold box has images to start.
TimeoutStartSec=1200

# There is deliberately NO ExecStop. Stopping this unit must not take the stack down — that
# would make `systemctl stop eyes-stack` a site outage button, and worse, systemd stops units
# at shutdown, so the nightly reboot would tear the stack down through this unit on the way out
# for no benefit. The daemon already signals containers when it stops.

[Install]
WantedBy=multi-user.target
EYES_STACK_SERVICE

  install_file "$UNIT_DIR/eyes-nightly-reboot.service" 0644 <<'EYES_NIGHTLY_REBOOT_SERVICE' || return 1
[Unit]
# Reboots THE MACHINE. Started by eyes-nightly-reboot.timer, and deliberately NOT enabled
# itself — a reboot unit wired into a target would be a reboot loop.
#
# It is a rescue hook: C11/C12 put our own Tailscale beside the vendor's on a box whose only
# remote access is that vendor's tailnet, and a reboot is the one thing that recovers a machine
# from an experiment that took the route in with it. It skips the night if an OTA bump is in
# flight — see eyes-host.sh.
Description=Eyes nightly machine reboot (skips while an OTA bump is in flight)
# Ordering only, and no `Requires=` — see the note in eyes-stack.service. The interlock reads
# the updater's journal, which is a file; docker is only needed for the nicer of the two ways
# of parsing it, and the script falls back when it is not there.
After=docker.service

[Service]
Type=oneshot
EnvironmentFile=/etc/eyes/node.env
ExecStart=/usr/local/lib/eyes/eyes-host.sh nightly-reboot
TimeoutStartSec=600
EYES_NIGHTLY_REBOOT_SERVICE

  install_file "$UNIT_DIR/eyes-nightly-reboot.timer" 0644 <<'EYES_NIGHTLY_REBOOT_TIMER' || return 1
[Unit]
Description=Reboot this machine nightly at 03:00 node-local time

[Timer]
# Node-local 03:00: systemd reads the host's /etc/localtime, and the containers mount the same
# file, so "03:00" here and the timestamps in the stack's logs are the same clock.
OnCalendar=*-*-* 03:00:00
# LOAD-BEARING, and more so than it looks. `Persistent=true` would make a box that was off at
# 03:00 reboot the instant it came up — which is a reboot loop on any machine whose boot lands
# after 03:00, i.e. an unreachable node, i.e. the exact outcome this timer is insurance
# against. The script's minimum-uptime floor is the second half of the same guard.
Persistent=false
# Two nodes today, more later. A fleet rebooting in lockstep is a thundering herd against the
# device door and the ingest API at 03:00, and every node's stack re-enrolling at once.
RandomizedDelaySec=300
Unit=eyes-nightly-reboot.service

[Install]
WantedBy=timers.target
EYES_NIGHTLY_REBOOT_TIMER

  $AS_ROOT systemctl daemon-reload || return 1
  # `enable` is a symlink at a fixed path and the unit files are rewritten wholesale, so a
  # reinstall converges rather than accumulating.
  $AS_ROOT systemctl enable eyes-nightly-reboot.timer || return 1
  $AS_ROOT systemctl start eyes-nightly-reboot.timer || return 1
  $AS_ROOT systemctl enable eyes-stack.service || return 1

  # Starting the boot unit NOW is a proof, not part of the installation: it runs the same
  # reconcile tonight's reboot will, so a unit that cannot run is found by the operator
  # standing at the box rather than at 3 a.m. tomorrow. The stack is already up, so it is a
  # no-op when it works. It is therefore reported and NOT fatal — the units are written and
  # enabled either way, and saying "not installed" when they are is worse than saying nothing.
  #
  # Nothing here ever starts eyes-nightly-reboot.service. Proving THAT one by running it would
  # reboot the box under the operator who is mid-install.
  if ! $AS_ROOT systemctl start eyes-stack.service; then
    echo "WARNING: eyes-stack.service is installed and enabled, but did NOT start just now." >&2
    echo "         It is the unit that brings this stack back after the nightly reboot, so it" >&2
    echo "         will fail the same way tonight. Diagnose it here, while you are on the box:" >&2
    echo "           systemctl status eyes-stack.service; journalctl -u eyes-stack.service" >&2
    echo "         A dependency named differently on this host (docker packaged as a snap" >&2
    echo "         rather than docker.service) is the likeliest cause." >&2
  fi
  echo "==> Host units installed."
  echo "    *** THIS MACHINE WILL REBOOT NIGHTLY AT 03:00 LOCAL (±5 min). ***"
  echo "    That takes the VMS down with it. It is deliberate — C10/RIS-99, a rescue hook for"
  echo "    the Tailscale work — and it is skipped while an OTA bump is in flight."
  echo "      systemctl list-timers eyes-nightly-reboot.timer"
  echo "      sudo systemctl mask eyes-nightly-reboot.timer   # stop it on this node"
  return 0
}

if ! install_host_units; then
  echo "WARNING: the Eyes host units (nightly reboot + after-reboot bring-up) were not" >&2
  echo "         installed — see above. The stack is up and this install is otherwise" >&2
  echo "         complete. NOTE this node will NOT reboot nightly, so it does not have the" >&2
  echo "         rescue hook the Tailscale work assumes." >&2
fi

# ── 8. The independent tailnet path (C12/RIS-101) ────────────────────────────
# Our OWN Tailscale beside the VMS vendor's, so that reaching this box stops depending on a
# tailnet we do not control and a share the vendor can revoke with one click. Step 7 installs
# the nightly reboot that exists as a rescue hook for exactly this work; this step installs the
# thing it is a rescue hook FOR.
#
# WHY THIS IS A STEP OF *THIS* INSTALLER, given the design insists on a SEPARATE LIFECYCLE.
# Because "separate lifecycle" is a claim about the RUNTIME, not about who lays the files down.
# What must stay separate — and still does, untouched by this step — is: its own compose
# project (`eyes-remote-access`, never `eyes`), its own unit with NO ordering relation to
# eyes-stack.service in either direction, its own state volume, /opt/eyes-remote-access rather
# than a release dir, and no OTA participation at all. `remote-access.sh doctor` § 3 asserts
# the last of those on every run.
#
# Sharing the install MOMENT buys the thing that was actually missing: every node gets the
# rescue path automatically, while everything still works, rather than when someone remembers.
# Contempo had it and Classique did not, purely because it was a second manual operation.
#
# WHERE THE FILES COME FROM, and the trade taken (C12, 2026-08-24). They are lifted out of the
# eyes-app image already pulled above, at /app/remote-access/ — the same `docker cp` mechanism
# step 2 uses for the compose spec. The alternative was the public fleet-deployment mirror.
#
#   * cost: the rescue path's version IS the app release's version, so fixing it means cutting
#     a release; and it cannot be installed FRESH on a node that cannot pull the image, which
#     needs a pull-token and therefore a working control plane.
#   * why that is acceptable: this step runs on EVERY install, so the rescue path is on the
#     node long before anyone needs it. You never install it during an emergency. The residual
#     exposure is a node that never ran a post-C12 install.sh AND has lost the control plane.
#
# THE STAGING DIR MUST BE OUTSIDE $EYES_HOME. Copying into releases/<tag>/ would trip the
# release-dir guard inside remote-access/scripts/install.sh AND fail doctor § 3 — correctly,
# because an OTA bump rewrites release dirs and would rewrite the rescue path with them.
#
# THIS STEP MAY NEVER FAIL THE INSTALL, for step 7's reason: install.sh is the documented
# escape from a node that can run neither release, and a node that cannot reinstall because
# the rescue path would not install is a node we have bricked. Every failure is a WARNING.
#
# IDEMPOTENT: the inner installer reuses an existing /etc/eyes-remote-access/env unless passed
# --from-door, so a re-install neither re-mints a credential nor disturbs a live tunnel.
#
# UNTIL RIS-111 LANDS, a node with NO existing credential warns and continues: the inner
# fetch-credential.sh still reads the fleet-wide EYES_TAILSCALE_AUTHKEY that RIS-109 dropped.
# A node that already has /etc/eyes-remote-access/env converges silently — which is why this
# is safe to run on Contempo today, and why it does nothing useful on Classique yet.
RA_IMAGE_DIR="${EYES_RA_IMAGE_DIR:-remote-access}" # where the tree lives INSIDE the image

install_remote_access() {
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "WARNING: no systemctl on this host, so the independent tailnet path (C12) was NOT" >&2
    echo "         installed. The stack is up and unaffected." >&2
    return 1
  fi

  # Same probe as step 7, for the same reason: this lands in /opt, /etc and /etc/systemd/system,
  # none of which are under $EYES_HOME. A real write, not `mkdir -p`, which succeeds on an
  # existing directory whether or not it is writable. /opt stands in for all three — the inner
  # installer checks the rest itself and fails loudly. Overridable for the same reason step 7's
  # EYES_SYSTEMD_DIR is: so this can be exercised by a test without root.
  local as_root="" probe probe_dir="${EYES_RA_PROBE_DIR:-/opt}"
  probe="$probe_dir/.eyes-write-probe.$$"
  if mkdir -p "$probe_dir" 2>/dev/null && : >"$probe" 2>/dev/null; then
    rm -f "$probe"
  elif command -v sudo >/dev/null 2>&1 && sudo mkdir -p "$probe_dir" 2>/dev/null; then
    as_root="sudo"
  else
    echo "WARNING: cannot write $probe_dir (not root, and sudo is unavailable), so the" >&2
    echo "         independent tailnet path (C12) was NOT installed. Re-run as root." >&2
    echo "         NB a sudoers policy granting only 'docker' is enough for every other step" >&2
    echo "         of this install and not enough for this one." >&2
    return 1
  fi

  local staged rc cid=""
  staged="$(mktemp -d "${TMPDIR:-/tmp}/eyes-remote-access.XXXXXX")" || {
    echo "WARNING: could not create a staging dir for the tailnet path." >&2
    return 1
  }

  if ! cid="$($DOCKER create --platform "$PLATFORM" "$IMAGE" 2>/dev/null)" || [[ -z "$cid" ]]; then
    echo "WARNING: could not create a container from $IMAGE to extract $RA_IMAGE_DIR/, so the" >&2
    echo "         independent tailnet path (C12) was NOT installed." >&2
    rm -rf "$staged"
    return 1
  fi
  if ! $DOCKER cp "$cid:/app/$RA_IMAGE_DIR/." "$staged/" 2>/dev/null; then
    echo "WARNING: $IMAGE has no /app/$RA_IMAGE_DIR — either this image predates C12, or the" >&2
    echo "         directory was excluded from the build context. The independent tailnet" >&2
    echo "         path was NOT installed. Check that docker/Dockerfile.app.dockerignore does" >&2
    echo "         not list remote-access/ (it must not; see the note in that file)." >&2
    $DOCKER rm -f "$cid" >/dev/null 2>&1 || true
    rm -rf "$staged"
    return 1
  fi
  $DOCKER rm -f "$cid" >/dev/null 2>&1 || true

  if [[ ! -f "$staged/docker-compose.yml" || ! -f "$staged/scripts/install.sh" ]]; then
    echo "WARNING: the extracted $RA_IMAGE_DIR/ is incomplete (missing docker-compose.yml or" >&2
    echo "         scripts/install.sh). Refusing to install a partial rescue path." >&2
    rm -rf "$staged"
    return 1
  fi
  # `docker cp` preserves modes, but a tree that somehow arrived without them fails three
  # layers down in a confusing way. Make the entry points executable regardless.
  chmod 0755 "$staged"/scripts/*.sh "$staged"/forwarder/entrypoint.sh 2>/dev/null || true

  echo "==> Installing the independent tailnet path from $IMAGE (/app/$RA_IMAGE_DIR)"
  $as_root "$staged/scripts/install.sh"
  rc=$?
  rm -rf "$staged"
  return "$rc"
}

if ! install_remote_access; then
  echo "WARNING: the independent tailnet path (C12/RIS-101) is NOT installed on this node" >&2
  echo "         — see above. The stack is up and this install is otherwise complete, but" >&2
  echo "         reaching this box still depends entirely on the VMS vendor's tailnet." >&2
  echo "         Until RIS-111 ships the per-device credential route, a node with no existing" >&2
  echo "         /etc/eyes-remote-access/env cannot self-provision one; install by hand with" >&2
  echo "         sudo <tree>/scripts/install.sh --env-file <file>" >&2
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
