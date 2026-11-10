#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/gh-tofu.env"

PATCHES=(
  "$ROOT/patches/backend.patch"
  "$ROOT/patches/history.patch"
  "$ROOT/patches/init-assistant.patch"
  "$ROOT/patches/state-compact.patch"
)

for patch in "${PATCHES[@]}"; do
  if [[ ! -s "$patch" ]]; then
    echo "ERROR: missing patch: $patch" >&2
    exit 1
  fi
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SRC="$WORK/opentofu"

git clone --quiet --filter=blob:none https://github.com/opentofu/opentofu.git "$SRC"
git -C "$SRC" checkout --quiet "$OPENTOFU_COMMIT"

actual="$(git -C "$SRC" rev-parse HEAD)"
if [[ "$actual" != "$OPENTOFU_COMMIT" ]]; then
  echo "ERROR: expected OpenTofu $OPENTOFU_COMMIT, got $actual" >&2
  exit 1
fi

for patch in "${PATCHES[@]}"; do
  git -C "$SRC" apply --check "$patch"
  git -C "$SRC" apply "$patch"
done

mkdir -p "$ROOT/dist"
(
  cd "$SRC"
  GOWORK=off go build -trimpath \
    -ldflags "-X github.com/opentofu/opentofu/version.dev=no" \
    -o "$ROOT/dist/gh-tofu" ./cmd/tofu
)

# Opt-in: GH_TOFU_SYMLINK_TOFU=1 also exposes dist/tofu for scripts that expect `tofu`.
if [[ "${GH_TOFU_SYMLINK_TOFU:-0}" == "1" ]]; then
  link="$ROOT/dist/tofu"
  if [[ -e "$link" || -L "$link" ]]; then
    if [[ ! -L "$link" || "$(readlink "$link")" != "gh-tofu" ]]; then
      echo "ERROR: refusing to replace existing $link" >&2
      exit 1
    fi
  else
    ln -s gh-tofu "$link"
  fi
fi

echo "Built dist/gh-tofu from OpenTofu $GH_TOFU_VERSION"
