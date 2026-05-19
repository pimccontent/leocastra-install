#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER_DEFAULT="pimccontent"
REPO_NAME_DEFAULT="leocastra-cloud-studio"
BOOTSTRAP_REPO_DEFAULT="pimccontent/leocastra-install"
INSTALL_DIR_DEFAULT="/opt/leocastra-cloud-studio"
GHCR_OWNER_DEFAULT="${REPO_OWNER_DEFAULT}"
IMAGE_TAG_DEFAULT="latest"

REPO_OWNER="${REPO_OWNER:-$REPO_OWNER_DEFAULT}"
REPO_NAME="${REPO_NAME:-$REPO_NAME_DEFAULT}"
GHCR_OWNER="${GHCR_OWNER:-$GHCR_OWNER_DEFAULT}"
IMAGE_TAG="${LEO_IMAGE_TAG:-$IMAGE_TAG_DEFAULT}"
INSTALL_DIR="${INSTALL_DIR:-$INSTALL_DIR_DEFAULT}"
REPO_SUBDIR="${REPO_SUBDIR:-}"
GIT_BRANCH="${GIT_BRANCH:-main}"
DOMAIN="${DOMAIN:-}"
ACME_EMAIL="${ACME_EMAIL:-}"
INSTALL_MODE="${INSTALL_MODE:-registry}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GHCR_TOKEN="${GHCR_TOKEN:-$GITHUB_TOKEN}"

usage() {
  cat <<EOF
LeoCastra Cloud Broadcast Studio — one-command install (Ubuntu)

Private source + GHCR images (recommended):

  export GITHUB_TOKEN="ghp_xxxx"    # scopes: read:packages, repo
  curl -fsSL https://raw.githubusercontent.com/${BOOTSTRAP_REPO_DEFAULT}/main/install.sh \\
    | sudo -E bash -s -- \\
        --domain studio.example.com \\
        --email admin@example.com \\
        --github-token "\$GITHUB_TOKEN"

Options:
  --domain <fqdn>              Required on first install
  --email <addr>               Let's Encrypt contact
  --install-mode registry|source   Default: registry
  --github-token <token>       Private git sparse clone
  --ghcr-token <token>         GHCR pull (defaults to github-token)
  --image-tag <tag>            Image tag (default: latest)

Env: REPO_OWNER, REPO_NAME, INSTALL_DIR, INSTALL_MODE, GITHUB_TOKEN, GHCR_TOKEN

Docs: deploy/PRIVATE-GITHUB-INSTALL.md

EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --email) ACME_EMAIL="${2:-}"; shift 2 ;;
    --install-mode) INSTALL_MODE="${2:-}"; shift 2 ;;
    --github-token) GITHUB_TOKEN="${2:-}"; shift 2 ;;
    --ghcr-token) GHCR_TOKEN="${2:-}"; shift 2 ;;
    --image-tag) IMAGE_TAG="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

compose_dir() {
  if [[ -n "$REPO_SUBDIR" ]]; then
    echo "${INSTALL_DIR}/${REPO_SUBDIR}/docker"
  else
    echo "${INSTALL_DIR}/docker"
  fi
}

compose_run() {
  local dir
  dir="$(compose_dir)"
  if [[ "$INSTALL_MODE" == "registry" ]]; then
    docker compose -f "${dir}/docker-compose.yml" -f "${dir}/docker-compose.registry.yml" "$@"
  else
    docker compose -f "${dir}/docker-compose.yml" "$@"
  fi
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Please run as root (use sudo)." >&2
    exit 1
  fi
}

rand_hex() {
  openssl rand -hex "${1:-32}"
}

install_docker_if_needed() {
  if command -v docker >/dev/null 2>&1; then
    return 0
  fi
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release git
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin git
}

git_clone_url() {
  if [[ -n "$GITHUB_TOKEN" ]]; then
    echo "https://x-access-token:${GITHUB_TOKEN}@github.com/${REPO_OWNER}/${REPO_NAME}.git"
  else
    echo "https://github.com/${REPO_OWNER}/${REPO_NAME}.git"
  fi
}

clone_or_update_repo() {
  mkdir -p "$INSTALL_DIR"
  local url
  url="$(git_clone_url)"

  if [[ -d "$INSTALL_DIR/.git" ]]; then
    git -C "$INSTALL_DIR" remote set-url origin "$url" 2>/dev/null || true
    git -C "$INSTALL_DIR" fetch --all --prune
    git -C "$INSTALL_DIR" reset --hard "origin/${GIT_BRANCH}"
    if [[ "$INSTALL_MODE" == "registry" ]]; then
      git -C "$INSTALL_DIR" sparse-checkout init --cone 2>/dev/null || true
      git -C "$INSTALL_DIR" sparse-checkout set docker deploy
    fi
    return 0
  fi

  rm -rf "$INSTALL_DIR"

  if [[ "$INSTALL_MODE" == "registry" ]]; then
    if [[ -z "$GITHUB_TOKEN" ]]; then
      echo "ERROR: GITHUB_TOKEN is required to sparse-clone the private repo." >&2
      echo "Create a fine-grained PAT with repo + read:packages." >&2
      exit 1
    fi
    echo "Sparse-cloning docker/ + deploy/ (application images from GHCR)..." >&2
    git clone --depth 1 --filter=blob:none --sparse -b "$GIT_BRANCH" "$url" "$INSTALL_DIR"
    git -C "$INSTALL_DIR" sparse-checkout set docker deploy
  else
    if [[ -z "$GITHUB_TOKEN" ]]; then
      echo "WARN: Cloning without token — only works if the repo is public." >&2
    fi
    git clone --depth 1 -b "$GIT_BRANCH" "$url" "$INSTALL_DIR"
  fi
}

ghcr_login() {
  if [[ -z "$GHCR_TOKEN" ]]; then
    echo "ERROR: GHCR_TOKEN (or --github-token) required for registry install (read:packages)." >&2
    exit 1
  fi
  echo "$GHCR_TOKEN" | docker login ghcr.io -u "${GHCR_USER:-github}" --password-stdin
}

write_docker_env() {
  local env_path
  env_path="$(compose_dir)/.env"
  INSTALLER_BOOTSTRAP_TOKEN=""

  if [[ -f "$env_path" ]]; then
    INSTALLER_BOOTSTRAP_TOKEN="$(
      grep -E '^[[:space:]]*BOOTSTRAP_TOKEN=' "$env_path" | head -n1 | cut -d= -f2- | tr -d '"' | tr -d '\r' || true
    )"
    # Preserve secrets on update; refresh image pins + install metadata.
    local backend_image="ghcr.io/${GHCR_OWNER}/leocastra-backend:${IMAGE_TAG}"
    local frontend_image="ghcr.io/${GHCR_OWNER}/leocastra-frontend:${IMAGE_TAG}"
    grep -v -E '^(LEO_BACKEND_IMAGE|LEO_FRONTEND_IMAGE|LEO_IMAGE_TAG|INSTALL_MODE|REPO_OWNER|REPO_NAME|GHCR_OWNER|GIT_BRANCH)=' "$env_path" > "${env_path}.tmp" || true
    cat >> "${env_path}.tmp" <<EOF
INSTALL_MODE=${INSTALL_MODE}
REPO_OWNER=${REPO_OWNER}
REPO_NAME=${REPO_NAME}
GHCR_OWNER=${GHCR_OWNER}
GIT_BRANCH=${GIT_BRANCH}
LEO_BACKEND_IMAGE=${backend_image}
LEO_FRONTEND_IMAGE=${frontend_image}
LEO_IMAGE_TAG=${IMAGE_TAG}
EOF
    mv "${env_path}.tmp" "$env_path"
    chmod 600 "$env_path"
    return 0
  fi

  if [[ -z "${DOMAIN}" ]]; then
    echo "--domain is required on first install (example: studio.example.com)" >&2
    exit 1
  fi

  local ORYX_MGMT_PASSWORD="lc_$(rand_hex 12)"
  local ORYX_PLATFORM_SECRET="lc_$(rand_hex 16)"
  local LEO_AUTH_JWT_SECRET="lc_$(rand_hex 16)"
  local LEO_STREAM_PUBLISH_SECRET="lc_$(rand_hex 16)"
  local LEO_HLS_TOKEN_SECRET="lc_$(rand_hex 16)"
  INSTALLER_BOOTSTRAP_TOKEN="lc_bootstrap_$(rand_hex 12)"
  local backend_image="ghcr.io/${GHCR_OWNER}/leocastra-backend:${IMAGE_TAG}"
  local frontend_image="ghcr.io/${GHCR_OWNER}/leocastra-frontend:${IMAGE_TAG}"

  cat > "$env_path" <<EOF
DOMAIN=${DOMAIN}
ACME_EMAIL=${ACME_EMAIL}
SITE_ADDRESS=${DOMAIN}
BOOTSTRAP_TOKEN=${INSTALLER_BOOTSTRAP_TOKEN}
ORYX_MGMT_PASSWORD=${ORYX_MGMT_PASSWORD}
ORYX_PLATFORM_SECRET=${ORYX_PLATFORM_SECRET}
LEO_AUTH_JWT_SECRET=${LEO_AUTH_JWT_SECRET}
LEO_STREAM_PUBLISH_SECRET=${LEO_STREAM_PUBLISH_SECRET}
LEO_HLS_TOKEN_SECRET=${LEO_HLS_TOKEN_SECRET}
STREAMING_RTMP_BASE=rtmp://${DOMAIN}:1935
STREAMING_RTMP_BASE_INTERNAL=rtmp://leocastra-streaming:1935
STREAMING_SRT_BASE=srt://${DOMAIN}:10080
SRT_PUBLIC_HOST=${DOMAIN}
SRT_DEFAULT_LATENCY_MS=400
STREAM_LATENCY_PROFILE=balanced
HLS_SEGMENT_SECONDS=2
HLS_LIST_SIZE=8
HLS_DELETE_THRESHOLD=2
FFMPEG_STATS_PERIOD=0.5
LICENSE_VALIDATE_URL=https://lic.unibms.com/api/license/validate
LICENSE_KEY=
LICENSE_DEV_BYPASS=false
LICENSE_DEV_MAX_STREAMS=5
INSTALL_MODE=${INSTALL_MODE}
REPO_OWNER=${REPO_OWNER}
REPO_NAME=${REPO_NAME}
GHCR_OWNER=${GHCR_OWNER}
GIT_BRANCH=${GIT_BRANCH}
LEO_BACKEND_IMAGE=${backend_image}
LEO_FRONTEND_IMAGE=${frontend_image}
LEO_IMAGE_TAG=${IMAGE_TAG}
EOF
  chmod 600 "$env_path"
}

load_install_env() {
  local env_path
  env_path="$(compose_dir)/.env"
  [[ -f "$env_path" ]] || return 0
  set -a
  # shellcheck disable=SC1090
  source "$env_path"
  set +a
  INSTALL_MODE="${INSTALL_MODE:-registry}"
  REPO_OWNER="${REPO_OWNER:-$REPO_OWNER_DEFAULT}"
  REPO_NAME="${REPO_NAME:-$REPO_NAME_DEFAULT}"
  GHCR_OWNER="${GHCR_OWNER:-$GHCR_OWNER_DEFAULT}"
  IMAGE_TAG="${LEO_IMAGE_TAG:-$IMAGE_TAG_DEFAULT}"
  GIT_BRANCH="${GIT_BRANCH:-main}"
}

start_stack() {
  load_install_env
  cd "$(compose_dir)"

  if [[ "$INSTALL_MODE" == "registry" ]]; then
    ghcr_login
    compose_run pull
    compose_run up -d --no-build
    return 0
  fi

  compose_run pull --ignore-pull-failures || true
  compose_run build --pull leocastra-backend leocastra-frontend
  compose_run up -d
}

ensure_swap_if_low_ram() {
  local mem_kb swap_kb
  mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo || echo 0)"
  swap_kb="$(awk '/SwapTotal/ {print $2}' /proc/meminfo || echo 0)"
  [[ "${swap_kb:-0}" -gt 0 ]] && return 0
  [[ "${mem_kb:-0}" -ge 3000000 ]] && return 0
  local swap_file="/swapfile"
  [[ -f "$swap_file" ]] && return 0
  echo "Low memory detected; creating 4G swap at $swap_file" >&2
  if command -v fallocate >/dev/null 2>&1; then
    fallocate -l 4G "$swap_file"
  else
    dd if=/dev/zero of="$swap_file" bs=1M count=4096 status=none
  fi
  chmod 600 "$swap_file"
  mkswap "$swap_file" >/dev/null
  swapon "$swap_file"
  grep -qE '^/swapfile\s' /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
}

print_success() {
  local dir
  dir="$(compose_dir)"
  cat <<EOF

LeoCastra Cloud Broadcast Studio is starting (mode: ${INSTALL_MODE}).

  https://${DOMAIN:-<your-domain>}
  Setup: https://${DOMAIN:-<your-domain>}/setup
  Bootstrap token: ${INSTALLER_BOOTSTRAP_TOKEN:-<see ${dir}/.env>}

License: https://lic.unibms.com → Settings → License

Update later:
  cd ${INSTALL_DIR} && sudo GITHUB_TOKEN=... GHCR_TOKEN=... bash deploy/update-live.sh

EOF
}

require_root
export DEBIAN_FRONTEND=noninteractive

case "$INSTALL_MODE" in
  registry|source) ;;
  *)
    echo "Invalid INSTALL_MODE: ${INSTALL_MODE}" >&2
    exit 1
    ;;
esac

apt-get update -y
apt-get install -y git openssl curl
install_docker_if_needed
clone_or_update_repo
write_docker_env
load_install_env
ensure_swap_if_low_ram
start_stack
print_success
