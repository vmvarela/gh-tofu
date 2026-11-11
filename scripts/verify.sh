#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/gh-tofu.env"

sh -n "$ROOT/scripts/install.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SRC="$WORK/opentofu"

git clone --quiet --filter=blob:none https://github.com/opentofu/opentofu.git "$SRC"
git -C "$SRC" checkout --quiet "$OPENTOFU_COMMIT"

PATCHES=(
  "$ROOT/patches/backend.patch"
  "$ROOT/patches/history.patch"
  "$ROOT/patches/init-assistant.patch"
  "$ROOT/patches/oras-purge.patch"
)

for patch in "${PATCHES[@]}"; do
  git -C "$SRC" apply --check "$patch"
  git -C "$SRC" apply "$patch"
done

# Smart Refresh was removed entirely; fail if any of its symbols reappear.
if git -C "$SRC" grep -qiE 'refreshsmart|smart_refresh' -- internal cmd; then
  echo "ERROR: Smart Refresh symbols found in patched OpenTofu tree" >&2
  exit 1
fi

(
  cd "$SRC"
  # TestFmt fails on macOS because TMPDIR sits behind the /var -> /private/var
  # symlink; it fails the same way on the unpatched base.
  GOWORK=off go test -skip 'TestFmt' \
    ./internal/command \
    ./internal/tofu \
    ./internal/states/... \
    ./internal/plans \
    ./internal/command/arguments \
    ./internal/command/views/... \
    ./internal/backend/local \
    ./internal/backend/remote-state/oras \
    ./internal/backend/init

  CGO_ENABLED=0 GOWORK=off go build -trimpath \
    -ldflags "-X github.com/opentofu/opentofu/version.dev=no" \
    -o "$WORK/gh-tofu" ./cmd/tofu
  version_line="$("$WORK/gh-tofu" version | sed -n '1p')"
  if [[ "$version_line" != "OpenTofu v$GH_TOFU_VERSION" ]]; then
    echo "ERROR: release binary reports '$version_line', expected OpenTofu v$GH_TOFU_VERSION" >&2
    exit 1
  fi
  if [[ -n "${GH_TOFU_VERIFY_ARM64_OUTPUT:-}" ]]; then
    mkdir -p "$(dirname "$GH_TOFU_VERIFY_ARM64_OUTPUT")"
    CGO_ENABLED=0 GOOS=linux GOARCH=arm64 GOWORK=off go build -trimpath \
      -ldflags "-X github.com/opentofu/opentofu/version.dev=no" \
      -o "$GH_TOFU_VERIFY_ARM64_OUTPUT" ./cmd/tofu
  fi
)

if [[ -n "${GH_TOFU_VERIFY_OUTPUT:-}" ]]; then
  mkdir -p "$(dirname "$GH_TOFU_VERIFY_OUTPUT")"
  cp "$WORK/gh-tofu" "$GH_TOFU_VERIFY_OUTPUT"
  chmod +x "$GH_TOFU_VERIFY_OUTPUT"
fi

echo "Verified gh-tofu $GH_TOFU_VERSION against OpenTofu $OPENTOFU_COMMIT"
