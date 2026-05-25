#!/usr/bin/env bash
# Install runtime dependencies for the mercadolibre Hermes skill.
# Auto-detects the package manager. Idempotent — safe to re-run.

set -e

NEEDS=()
command -v curl >/dev/null 2>&1 || NEEDS+=(curl)
command -v jq   >/dev/null 2>&1 || NEEDS+=(jq)

if [ ${#NEEDS[@]} -eq 0 ]; then
  echo "All dependencies already installed (curl, jq)."
  exit 0
fi

echo "Installing: ${NEEDS[*]}"

SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  SUDO=sudo
fi

if   command -v apt-get >/dev/null 2>&1; then
  $SUDO apt-get update -qq
  $SUDO apt-get install -y "${NEEDS[@]}"
elif command -v dnf     >/dev/null 2>&1; then
  $SUDO dnf install -y "${NEEDS[@]}"
elif command -v yum     >/dev/null 2>&1; then
  $SUDO yum install -y "${NEEDS[@]}"
elif command -v apk     >/dev/null 2>&1; then
  $SUDO apk add --no-cache "${NEEDS[@]}"
elif command -v pacman  >/dev/null 2>&1; then
  $SUDO pacman -S --noconfirm "${NEEDS[@]}"
elif command -v zypper  >/dev/null 2>&1; then
  $SUDO zypper install -y "${NEEDS[@]}"
elif command -v brew    >/dev/null 2>&1; then
  brew install "${NEEDS[@]}"
else
  echo "Could not detect a supported package manager." >&2
  echo "Install manually:" >&2
  echo "  jq:   https://jqlang.github.io/jq/download/" >&2
  echo "  curl: https://curl.se/download.html" >&2
  exit 1
fi

echo
echo "Verifying..."
curl --version | head -1
jq --version
