#!/usr/bin/env bash
#
# Eyes node installer — docker-only. No root, no git clone, no host doppler.
#
#   curl -fsSL https://<your-host>/install.sh | bash -s -- <doppler-token> <factory> [version]
#
# Args:
#   <doppler-token>  A Doppler token that can read the eyes project's
#                    prd_<factory> config (a temporary universal/service-account
#                    token, or that site's service token). Used in-memory only;
#                    never written to disk.
#   <factory>        Factory name, e.g. contempo / rapidbloc / temp. Selects the
#                    Doppler config (prd_<factory>) and the active factory.
#   [version]        Optional image tag to pin, e.g. v0.0.3. Defaults to
#                    `latest`, which CI keeps pointed at the newest v* build.
#
# Requirements: docker (with the compose plugin). The daemon is reached directly
# if possible, else via sudo (when the user isn't in the docker group). That's
# it — the Doppler CLI runs as a container, and the app image carries the code,
# config, ML model, compose file, and factory metadata.
#
# What it does (Model B — secrets provisioned once into a root-readable .env,
# the bootstrap token is discarded):
#   1. Pull this factory's config+secrets from Doppler via dopplerhq/cli (docker).
#   2. docker login GHCR + pull the eyes-app image.
#   3. Rehydrate the working dir from the image (compose + config + metadata).
#   4. Write .env and `docker compose up -d`.
#
# Tunables (env): EYES_HOME (default: current dir), EYES_IMAGE_TAG (default latest),
#   EYES_DOPPLER_PROJECT (default eyes), EYES_DOPPLER_CONFIG (default prd_<factory>).
#
set -euo pipefail

TOKEN="${1:-}"; FACTORY="${2:-}"
if [[ -z "$TOKEN" || -z "$FACTORY" ]]; then
  echo "usage: install.sh <doppler-token> <factory> [version]" >&2
  exit 1
fi

VERSION="${3:-${EYES_IMAGE_TAG:-latest}}"
# CI publishes linux/amd64. Real nodes are amd64; an Apple-Silicon dev box runs
# it under emulation. Matches the compose platform pin.
PLATFORM="${EYES_PLATFORM:-linux/amd64}"
EYES_HOME="${EYES_HOME:-$(pwd)}"
PROJECT="${EYES_DOPPLER_PROJECT:-eyes}"
# One shared config (the universal token's only gate) holds the fleet secrets:
# the GHCR pull creds and the single shared M2M client (Rise issued ONE M2M
# credential for the whole integration; the hub tells factories apart by the
# factory_uuid in the payload, not by client). The factory is just a non-secret
# arg that selects which factory yaml the worker runs.
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

echo "==> Eyes node install: factory=$FACTORY  home=$EYES_HOME"
umask 077
mkdir -p "$EYES_HOME"
cd "$EYES_HOME"

# Compose auto-loads .env from the COMPOSE FILE'S directory (the "project
# directory"), NOT the cwd. Our compose file lives in $EYES_HOME/docker, so the
# .env must sit beside it — otherwise `docker compose -f docker/...` (manual or
# scripted) silently ignores it and every ${VAR:-default} falls back (e.g.
# EYES_FACTORY -> temp). Write it there so any invocation picks it up.
ENV_FILE="$EYES_HOME/docker/.env"
mkdir -p "$EYES_HOME/docker"

# 1. Fetch the shared config from Doppler via the official CLI as a container.
#    Token via env (never argv/ps). Output is .env format -> write straight to .env.
echo "==> Fetching ${PROJECT}/${CONFIG} secrets (doppler-in-docker)…"
$DOCKER run --rm -e DOPPLER_TOKEN="$TOKEN" "$DOPPLER_IMAGE" \
  secrets download --no-file --format env -p "$PROJECT" -c "$CONFIG" > "$ENV_FILE"
chmod 600 "$ENV_FILE"
# The factory comes from the CLI arg and is AUTHORITATIVE: strip any EYES_FACTORY
# the shared config may carry (prd_fleet was derived from the old per-site
# configs, which set it) so a stale value can't silently override the arg and
# pin the node to the wrong factory. Then pin the image tag so compose pulls what
# we pulled; optional rec overrides for dev boxes.
sed -i.bak '/^EYES_FACTORY=/d' "$ENV_FILE" && rm -f "$ENV_FILE.bak"
echo "EYES_FACTORY=$FACTORY" >> "$ENV_FILE"
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
$DOCKER pull --platform "$PLATFORM" "$IMAGE"

# 3. Rehydrate the working dir from the image (no git): compose + config + metadata.
#    The ML model lives inside the baked eyes/ package, so nothing else is needed.
echo "==> Extracting compose + config + metadata from the image…"
cid="$($DOCKER create --platform "$PLATFORM" "$IMAGE")"
trap '$DOCKER rm -f "$cid" >/dev/null 2>&1 || true' EXIT
mkdir -p "$EYES_HOME/docker" "$EYES_HOME/config" "$EYES_HOME/data"
$DOCKER cp "$cid:/app/$COMPOSE" "$EYES_HOME/$COMPOSE"
$DOCKER cp "$cid:/app/config/." "$EYES_HOME/config/"
if ! $DOCKER cp "$cid:/app/data/metadata" "$EYES_HOME/data/" 2>/dev/null; then
  echo "WARNING: image has no baked data/metadata. Rebuild the image after the" >&2
  echo "         .dockerignore change (data/* + !data/metadata) or the worker" >&2
  echo "         will find no cameras to scan." >&2
fi
mkdir -p "$EYES_HOME/data/bucket" "$EYES_HOME/data/workdir" "$EYES_HOME/rec"

# 4. Launch (compose pulls redis as needed; eyes-app is already local).
echo "==> Starting the stack…"
$DOCKER compose -f "$COMPOSE" up -d
echo "==> Node up for factory '$FACTORY'."
echo "    Logs:  $DOCKER compose -f $EYES_HOME/$COMPOSE logs -f tasks"
