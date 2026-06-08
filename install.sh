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
# Requirements: docker (with the compose plugin) and a reachable daemon. That's
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
# Tunables (env): EYES_HOME (default ~/eyes), EYES_IMAGE_TAG (default latest),
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
EYES_HOME="${EYES_HOME:-$HOME/eyes}"
PROJECT="${EYES_DOPPLER_PROJECT:-eyes}"
# One shared config (the universal token's only gate) holds the fleet's GHCR
# pull creds plus EVERY factory's M2M identity, namespaced EYES_M2M_CLIENT_ID_<FACTORY>.
# We pull the bundle, then write ONLY this factory's M2M to the node — so each
# node still authenticates to the hub as its own per-factory Auth0 client.
CONFIG="${EYES_DOPPLER_CONFIG:-prd_fleet}"
IMAGE="ghcr.io/riseautomation/eyes-app:${VERSION}"
DOPPLER_IMAGE="dopplerhq/cli:latest"
COMPOSE="docker/docker-compose.yml"

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker is required." >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "ERROR: docker daemon is not reachable." >&2; exit 1; }

echo "==> Eyes node install: factory=$FACTORY  home=$EYES_HOME"
umask 077
mkdir -p "$EYES_HOME"
cd "$EYES_HOME"

# 1. Fetch the shared bundle from Doppler via the official CLI as a container.
#    Token via env (never argv/ps). Keep it in memory; we write a curated .env.
echo "==> Fetching ${PROJECT}/${CONFIG} secrets (doppler-in-docker)…"
RAW="$(docker run --rm -e DOPPLER_TOKEN="$TOKEN" "$DOPPLER_IMAGE" \
  secrets download --no-file --format env -p "$PROJECT" -c "$CONFIG")"

# Read a KEY="value" entry from the env-format blob (strips surrounding quotes).
getval() { printf '%s\n' "$RAW" | sed -n "s/^$1=//p" | head -1 | sed -e 's/^"//' -e 's/"$//'; }

FU="$(printf '%s' "$FACTORY" | tr '[:lower:]' '[:upper:]')"
M2M_ID="$(getval "EYES_M2M_CLIENT_ID_${FU}")"
M2M_SECRET="$(getval "EYES_M2M_CLIENT_SECRET_${FU}")"
if [[ -z "$M2M_ID" || -z "$M2M_SECRET" ]]; then
  echo "ERROR: no M2M creds for factory '$FACTORY' in $CONFIG (expected EYES_M2M_CLIENT_ID_${FU})." >&2
  exit 1
fi

# Write a curated .env: shared GHCR + ONLY this factory's M2M (other factories'
# M2M never touch this node). The factory is the arg; tag is what we pin/pull.
{
  echo "GHCR_USERNAME=$(getval GHCR_USERNAME)"
  echo "GHCR_PAT=$(getval GHCR_PAT)"
  echo "EYES_M2M_CLIENT_ID=$M2M_ID"
  echo "EYES_M2M_CLIENT_SECRET=$M2M_SECRET"
  echo "EYES_FACTORY=$FACTORY"
  echo "EYES_IMAGE_TAG=$VERSION"
  # Optional rec-dir overrides for dev boxes (real nodes default to /mnt/storage/rec).
  [ -n "${EYES_REC_HOST:-}" ] && echo "EYES_REC_HOST=$EYES_REC_HOST"
  [ -n "${EYES_REC_CONTAINER:-}" ] && echo "EYES_REC_CONTAINER=$EYES_REC_CONTAINER"
} > "$EYES_HOME/.env"
chmod 600 "$EYES_HOME/.env"

# Load secrets for the GHCR login below (stays in this shell only).
set -a; . "$EYES_HOME/.env"; set +a

# 2. GHCR auth + pull.
echo "==> Authenticating to GHCR and pulling $IMAGE …"
if [[ -n "${GHCR_PAT:-}" ]]; then
  printf '%s' "$GHCR_PAT" | docker login ghcr.io -u "${GHCR_USERNAME:-x-access-token}" --password-stdin
fi
docker pull --platform "$PLATFORM" "$IMAGE"

# 3. Rehydrate the working dir from the image (no git): compose + config + metadata.
#    The ML model lives inside the baked eyes/ package, so nothing else is needed.
echo "==> Extracting compose + config + metadata from the image…"
cid="$(docker create --platform "$PLATFORM" "$IMAGE")"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
mkdir -p "$EYES_HOME/docker" "$EYES_HOME/config" "$EYES_HOME/data"
docker cp "$cid:/app/$COMPOSE" "$EYES_HOME/$COMPOSE"
docker cp "$cid:/app/config/." "$EYES_HOME/config/"
if ! docker cp "$cid:/app/data/metadata" "$EYES_HOME/data/" 2>/dev/null; then
  echo "WARNING: image has no baked data/metadata. Rebuild the image after the" >&2
  echo "         .dockerignore change (data/* + !data/metadata) or the worker" >&2
  echo "         will find no cameras to scan." >&2
fi
mkdir -p "$EYES_HOME/data/bucket" "$EYES_HOME/data/workdir" "$EYES_HOME/rec"

# 4. Launch (compose pulls redis as needed; eyes-app is already local).
echo "==> Starting the stack…"
docker compose -f "$COMPOSE" up -d
echo "==> Node up for factory '$FACTORY'."
echo "    Logs:  docker compose -f $EYES_HOME/$COMPOSE logs -f tasks"
