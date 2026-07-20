#!/usr/bin/env bash
#
# Eyes node installer — docker-only. No root, no git clone, no host doppler.
#
#   curl -fsSL https://<your-host>/install.sh | bash -s -- <doppler-token> <factory-id> [version]
#
# Args:
#   <doppler-token>  A Doppler token that can read the eyes project's shared
#                    prd_fleet config (a temporary universal/service-account
#                    token, or a site service token). Used in-memory only;
#                    never written to disk.
#   <factory-id>     The node's hub factory id (a UUID). Becomes the node's
#                    identity: written as EYES_FACTORY_ID and consumed by the
#                    config as factory.uuid (+ celery worker location). There are
#                    no per-factory config files — a new factory just installs
#                    with its id. Secrets come from the shared prd_fleet config.
#   [version]        Optional image tag to pin, e.g. v0.0.3. Defaults to
#                    `latest`, which CI keeps pointed at the newest v* build.
#
# Deployment profile: `onsite` by default (real nodes). Override with
# EYES_PROFILE=dev for a laptop/webcam rig (see config/profile/).
#
# Requirements: docker (with the compose plugin). The daemon is reached directly
# if possible, else via sudo (when the user isn't in the docker group). That's
# it — the Doppler CLI runs as a container, and the app image carries the code,
# config, ML model, and compose file. Site metadata is NOT in the image (A1.5): the
# node fetches its factory bundle from the control plane at boot.
#
# What it does (Model B — secrets provisioned once into a root-readable .env,
# the bootstrap token is discarded):
#   1. Pull the shared fleet config+secrets from Doppler via dopplerhq/cli (docker).
#   2. docker login GHCR + pull the eyes-app image.
#   3. Rehydrate the working dir from the image (compose + config). Site metadata is
#      NOT baked (A1.5): the node fetches it from the control plane at boot.
#   4. Write .env and `docker compose up -d`.
#
# Tunables (env): EYES_HOME (default: current dir), EYES_IMAGE_TAG (default latest),
#   EYES_DOPPLER_PROJECT (default eyes), EYES_DOPPLER_CONFIG (default prd_<factory>).
#
set -euo pipefail

TOKEN="${1:-}"; FACTORY_ID="${2:-}"
if [[ -z "$TOKEN" || -z "$FACTORY_ID" ]]; then
  echo "usage: install.sh <doppler-token> <factory-id> [version]" >&2
  exit 1
fi
# Deployment profile (config/profile/<name>.yaml). Real nodes are on-site; a dev
# laptop/webcam rig passes EYES_PROFILE=dev.
PROFILE="${EYES_PROFILE:-onsite}"

VERSION="${3:-${EYES_IMAGE_TAG:-latest}}"
# CI publishes linux/amd64. Real nodes are amd64; an Apple-Silicon dev box runs
# it under emulation. Matches the compose platform pin.
PLATFORM="${EYES_PLATFORM:-linux/amd64}"
EYES_HOME="${EYES_HOME:-$(pwd)}"
PROJECT="${EYES_DOPPLER_PROJECT:-eyes}"
# One shared config (the universal token's only gate) holds the fleet secrets:
# the GHCR pull creds and the single shared M2M client (Rise issued ONE M2M
# credential for the whole integration; the hub tells factories apart by the
# factory id in the payload, not by client). The factory id + profile are just
# non-secret args that set this node's identity and deployment shape.
CONFIG="${EYES_DOPPLER_CONFIG:-prd_fleet}"
IMAGE="ghcr.io/riseautomation/eyes-app:${VERSION}"
DOPPLER_IMAGE="dopplerhq/cli:latest"
COMPOSE="docker/docker-compose.yml"

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker is required." >&2; exit 1; }
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

echo "==> Eyes node install: factory-id=$FACTORY_ID  profile=$PROFILE  home=$EYES_HOME"
umask 077
mkdir -p "$EYES_HOME"
cd "$EYES_HOME"

# Compose auto-loads .env from the COMPOSE FILE'S directory (the "project
# directory"), NOT the cwd. Our compose file lives in $EYES_HOME/docker, so the
# .env must sit beside it — otherwise `docker compose -f docker/...` (manual or
# scripted) silently ignores it and every ${VAR:-default} falls back (e.g.
# EYES_PROFILE -> dev). Write it there so any invocation picks it up.
ENV_FILE="$EYES_HOME/docker/.env"
mkdir -p "$EYES_HOME/docker"

# 1. Fetch the shared config from Doppler via the official CLI as a container.
#    Token via env (never argv/ps). Output is .env format -> write straight to .env.
echo "==> Fetching ${PROJECT}/${CONFIG} secrets (doppler-in-docker)…"
$DOCKER run --rm -e DOPPLER_TOKEN="$TOKEN" "$DOPPLER_IMAGE" \
  secrets download --no-file --format env -p "$PROJECT" -c "$CONFIG" > "$ENV_FILE"
chmod 600 "$ENV_FILE"
# Identity + profile come from the CLI arg/env and are AUTHORITATIVE: strip any
# EYES_FACTORY_ID/EYES_PROFILE (and the legacy EYES_FACTORY) the shared config may
# carry so a stale value can't silently override the arg and pin the node to the
# wrong factory/shape. Then write the resolved values + pin the image tag so
# compose pulls what we pulled; optional rec overrides for dev boxes.
sed -i.bak '/^EYES_FACTORY_ID=/d; /^EYES_PROFILE=/d; /^EYES_FACTORY=/d' "$ENV_FILE" && rm -f "$ENV_FILE.bak"
echo "EYES_FACTORY_ID=$FACTORY_ID" >> "$ENV_FILE"
echo "EYES_PROFILE=$PROFILE" >> "$ENV_FILE"
echo "EYES_IMAGE_TAG=$VERSION" >> "$ENV_FILE"
[ -n "${EYES_REC_HOST:-}" ] && echo "EYES_REC_HOST=$EYES_REC_HOST" >> "$ENV_FILE"
[ -n "${EYES_REC_CONTAINER:-}" ] && echo "EYES_REC_CONTAINER=$EYES_REC_CONTAINER" >> "$ENV_FILE"
# Per-node machine id: seeds the node-general queue that this node's general
# workers share, so node-local work (commit aggregation, which writes the local
# bucket) runs on this node but off the dedicated inference workers. Unique per
# node so it never collides if nodes are ever pointed at a shared broker. Lives
# in .env, so it's stable across `compose up`/restarts; a reinstall rotates it
# (harmless — the local filesystem is the source of truth for commits). Set
# EYES_MACHINE_ID in the Doppler config to pin a fixed value instead.
grep -q '^EYES_MACHINE_ID=' "$ENV_FILE" || \
  echo "EYES_MACHINE_ID=node-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')" >> "$ENV_FILE"

# Load secrets for the GHCR login below (stays in this shell only).
set -a; . "$ENV_FILE"; set +a

# 2. GHCR auth + pull.
echo "==> Authenticating to GHCR and pulling $IMAGE …"
if [[ -n "${GHCR_PAT:-}" ]]; then
  printf '%s' "$GHCR_PAT" | $DOCKER login ghcr.io -u "${GHCR_USERNAME:-x-access-token}" --password-stdin
fi
# The PAT is only needed for this one login; docker persists the credential to
# its config.json, so the pull below (and future `compose pull` upgrades) reuse
# it without the PAT. Strip GHCR creds from the on-disk .env so they don't linger
# at rest on the node — they stay in this shell only (dies at exit). compose
# doesn't reference them, so nothing downstream breaks.
sed -i.bak '/^GHCR_PAT=/d; /^GHCR_USERNAME=/d' "$ENV_FILE" && rm -f "$ENV_FILE.bak"
$DOCKER pull --platform "$PLATFORM" "$IMAGE"

# 3. Rehydrate the working dir from the image (no git): compose + config.
#    The ML model lives inside the baked eyes/ package. Site metadata is NOT baked
#    (A1.5 / spec M4): the node boots blank and the command-listener fetches this
#    factory's current bundle from the control plane into data/metadata/ (a cache),
#    so a reinstall can no longer clobber pushed metadata with a stale git snapshot.
#    We create an EMPTY data/metadata so the volume mount + the worker gate have a
#    dir to watch; the fetch fills it (see EYES_METADATA_SOURCE / metadata gate).
echo "==> Extracting compose + config from the image…"
cid="$($DOCKER create --platform "$PLATFORM" "$IMAGE")"
trap '$DOCKER rm -f "$cid" >/dev/null 2>&1 || true' EXIT
mkdir -p "$EYES_HOME/docker" "$EYES_HOME/config" "$EYES_HOME/data"
$DOCKER cp "$cid:/app/$COMPOSE" "$EYES_HOME/$COMPOSE"
$DOCKER cp "$cid:/app/config/." "$EYES_HOME/config/"
mkdir -p "$EYES_HOME/data/metadata" "$EYES_HOME/data/bucket" "$EYES_HOME/data/workdir" "$EYES_HOME/rec"

# 3b. Sanity-check the chosen profile now that the config is on disk. Identity
#     (EYES_FACTORY_ID) needs no lookup — it's the hub id, written verbatim above.
PROFILE_DIR="$EYES_HOME/config/profile"
if [[ -d "$PROFILE_DIR" && ! -f "$PROFILE_DIR/$PROFILE.yaml" ]]; then
  known="$(cd "$PROFILE_DIR" && ls -1 ./*.yaml 2>/dev/null | sed 's#.*/##; s#\.yaml$##' | tr '\n' ' ')"
  echo "ERROR: no config/profile/$PROFILE.yaml (known: ${known:-none})." >&2
  exit 1
fi

# 4. Launch (compose pulls redis as needed; eyes-app is already local).
echo "==> Starting the stack…"
$DOCKER compose -f "$COMPOSE" up -d
echo "==> Node up: factory-id=$FACTORY_ID profile=$PROFILE."
echo "    Logs:  $DOCKER compose -f $EYES_HOME/$COMPOSE logs -f tasks"
