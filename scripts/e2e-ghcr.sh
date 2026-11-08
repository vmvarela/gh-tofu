#!/usr/bin/env bash
# Manual, opt-in end-to-end lifecycle test for the gh-tofu ORAS backend on GHCR.
#
# It exercises gh-tofu's own credential discovery (GH_TOKEN) and CLI commands.
# It makes no direct registry or GitHub Packages API calls and accepts no
# package or workspace overrides: the package is fixed and only the exact
# run/attempt workspace is written or removed.
#
# GHCR package versions live under /orgs/<owner>/packages/<type>/<name>/versions/<id>.
# This test never calls that API; cleanup goes through the CLI workspace command.
set -euo pipefail

if [[ "${GH_TOFU_GHCR_E2E:-}" != "1" ]]; then
  echo "REFUSED: this test writes to a real GHCR package; set GH_TOFU_GHCR_E2E=1 to opt in." >&2
  exit 1
fi

PACKAGE="ghcr.io/vmvarela/gh-tofu-e2e"
ANCHOR="gh-tofu-e2e-anchor"
REQUIRED_REPOSITORY="vmvarela/gh-tofu"
REQUIRED_REF="refs/heads/master"
WORKSPACE_COMMAND=(workspace delete) # workspace-level only; never package versions

fail() { echo "ERROR: $*" >&2; exit 1; }

[[ -n "${GH_TOFU_BIN:-}" ]] || fail "GH_TOFU_BIN is required."
[[ -x "$GH_TOFU_BIN" ]] || fail "GH_TOFU_BIN is not executable: $GH_TOFU_BIN"
[[ -n "${GH_TOKEN//[[:space:]]/}" ]] || fail "GH_TOKEN is required; the workflow supplies it only to the CLI lifecycle and cleanup."
[[ "${GITHUB_REPOSITORY:-}" == "$REQUIRED_REPOSITORY" ]] ||
  fail "GITHUB_REPOSITORY must be $REQUIRED_REPOSITORY (got ${GITHUB_REPOSITORY:-<unset>})."
[[ "${GITHUB_REF:-}" == "$REQUIRED_REF" ]] ||
  fail "GITHUB_REF must be $REQUIRED_REF (got ${GITHUB_REF:-<unset>})."
[[ -n "${GITHUB_SHA:-}" ]] || fail "GITHUB_SHA is required."
[[ "${GITHUB_RUN_ID:-}" =~ ^[0-9]+$ ]] || fail "GITHUB_RUN_ID must be numeric."
[[ "${GITHUB_RUN_ATTEMPT:-}" =~ ^[0-9]+$ ]] || fail "GITHUB_RUN_ATTEMPT must be numeric."
command -v python3 >/dev/null 2>&1 || fail "python3 is required."

TEST_WORKSPACE="gh-tofu-ci-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
[[ "$TEST_WORKSPACE" =~ ^[a-z0-9][a-z0-9._-]{0,127}$ ]] ||
  fail "derived run workspace is not a valid OCI tag: $TEST_WORKSPACE"
[[ "$TEST_WORKSPACE" != "$ANCHOR" ]] || fail "run workspace must never equal the anchor workspace."
[[ -z "${GH_TOFU_E2E_PACKAGE:-}" && -z "${GH_TOFU_E2E_WORKSPACE:-}" ]] ||
  fail "package and workspace overrides are not supported."

# Keep the test deterministic: no inherited workspace, backend overrides or logging.
# Use the workflow-supplied GH_TOKEN path, not GITHUB_TOKEN or explicit credentials.
unset GITHUB_TOKEN TF_WORKSPACE TF_LOG TF_LOG_PATH
unset TF_CLI_ARGS TF_CLI_ARGS_init TF_CLI_ARGS_plan TF_CLI_ARGS_apply
unset TF_BACKEND_ORAS_LOCK_TTL TF_BACKEND_ORAS_MAX_STATE_SIZE
unset TF_BACKEND_ORAS_RETRY_MAX TF_BACKEND_ORAS_RETRY_WAIT_MIN TF_BACKEND_ORAS_RETRY_WAIT_MAX
unset TF_BACKEND_ORAS_RATE_LIMIT TF_BACKEND_ORAS_RATE_LIMIT_BURST
export TF_IN_AUTOMATION=1 TF_INPUT=0 CHECKPOINT_DISABLE=1
umask 077

echo "GHCR CLI lifecycle E2E: package=$PACKAGE workspace=$TEST_WORKSPACE run=${GITHUB_RUN_ID}/${GITHUB_RUN_ATTEMPT}"

WORK="$(mktemp -d)"
WRITER="$WORK/writer"
READER="$WORK/reader"
ADMIN="$WORK/admin"
READY="$WORK/holder-ready"
RELEASE="$WORK/holder-release"
HOLDER_LOG="$WORK/holder.log"
HOLDER_PID=""
OWNED=0
CLEANUP_DONE=0

workspace_listed() {
  local name=$1 listing=$2 line
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    if [[ "$line" == "* "* ]]; then
      line="${line#\* }"
    fi
    line="${line%"${line##*[![:space:]]}"}"
    [[ "$line" == "$name" ]] && return 0
  done <<< "$listing"
  return 1
}

process_running() {
  local pid=$1 state
  kill -0 "$pid" 2>/dev/null || return 1
  state="$(LC_ALL=C ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
  [[ -n "$state" && "$state" != Z* ]]
}

collect_descendants() {
  local parent=$1 child
  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    collect_descendants "$child"
    printf '%s\n' "$child"
  done < <(pgrep -P "$parent" 2>/dev/null || true)
}

stop_holder_tree() {
  local pid=$1 p alive
  local -a tree=()
  [[ -n "$pid" ]] || return 0

  # Snapshot before releasing the blocked provisioner: releasing first can let
  # children exit and reparent, hiding them from later tree checks.
  while IFS= read -r p; do
    [[ -n "$p" ]] && tree+=("$p")
  done < <(collect_descendants "$pid"; printf '%s\n' "$pid")
  touch "$RELEASE" 2>/dev/null || true

  for p in "${tree[@]}"; do
    kill -TERM "$p" 2>/dev/null || true
  done
  for _ in {1..50}; do
    alive=0
    for p in "${tree[@]}"; do
      process_running "$p" && alive=1
    done
    [[ "$alive" -eq 0 ]] && break
    sleep 0.1
  done

  if [[ "$alive" -ne 0 ]]; then
    while IFS= read -r p; do
      [[ -n "$p" ]] && tree+=("$p")
    done < <(collect_descendants "$pid")
    for p in "${tree[@]}"; do
      kill -KILL "$p" 2>/dev/null || true
    done
    for _ in {1..50}; do
      alive=0
      for p in "${tree[@]}"; do
        process_running "$p" && alive=1
      done
      [[ "$alive" -eq 0 ]] && break
      sleep 0.1
    done
  fi

  # The TERM/KILL polls above are the deadline. wait is reached only when the
  # direct child is already dead or a zombie, so it cannot block on a live writer.
  if ! process_running "$pid"; then
    wait "$pid" 2>/dev/null || true
  fi

  for p in "${tree[@]}"; do
    process_running "$p" && return 1
  done
  return 0
}

wait_for_holder() {
  local pid=$1 rc
  # Poll with a deadline instead of an unbounded wait or a helper process.
  for _ in {1..240}; do
    if ! process_running "$pid"; then
      if wait "$pid" 2>/dev/null; then rc=0; else rc=$?; fi
      return "$rc"
    fi
    sleep 0.5
  done

  # Leave the holder and its descendants observable. The EXIT trap snapshots
  # that tree before releasing the blocked provisioner and before deletion;
  # killing and reaping the holder here could hide a surviving child.
  return 1
}

cleanup_residue_note() {
  echo "  package: $PACKAGE" >&2
  echo "  workspace: $TEST_WORKSPACE" >&2
  echo "  run: ${GITHUB_RUN_ID}/${GITHUB_RUN_ATTEMPT}" >&2
  echo "  residue: cleanup targets only that exact workspace; superseded untagged package" >&2
  echo "  versions can remain. This script never deletes package-level resources or claims" >&2
  echo "  that package storage is complete." >&2
}

remove_owned_workspace() {
  local listing
  if [[ "$TEST_WORKSPACE" != "gh-tofu-ci-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}" ||
    "$TEST_WORKSPACE" == "$ANCHOR" || "$TEST_WORKSPACE" == "default" ]]; then
    echo "ERROR: refusing cleanup: run workspace identity no longer matches." >&2
    cleanup_residue_note
    return 1
  fi

  echo "Deleting the owned workspace $TEST_WORKSPACE (bounded to that exact workspace)"
  if ! "$GH_TOFU_BIN" -chdir="$ADMIN" "${WORKSPACE_COMMAND[@]}" -force "$TEST_WORKSPACE"; then
    echo "ERROR: bounded cleanup could not remove the owned workspace." >&2
    cleanup_residue_note
    return 1
  fi

  # Bounded confirmation; a failed listing is a cleanup failure, not silence.
  for _ in {1..10}; do
    if listing="$("$GH_TOFU_BIN" -chdir="$ADMIN" workspace list 2>&1)"; then
      if ! workspace_listed "$TEST_WORKSPACE" "$listing"; then
        echo "Owned workspace deleted. Superseded untagged versions may remain; no package-level deletion was attempted."
        return 0
      fi
    fi
    sleep 1
  done

  echo "ERROR: owned workspace is still listed after deletion." >&2
  cleanup_residue_note
  return 1
}

cleanup() {
  local status=$? teardown_ok=1
  if [[ "$CLEANUP_DONE" -eq 1 ]]; then
    exit "$status"
  fi
  CLEANUP_DONE=1
  trap - EXIT INT TERM

  if [[ -n "$HOLDER_PID" ]]; then
    if ! stop_holder_tree "$HOLDER_PID"; then
      teardown_ok=0
    fi
    HOLDER_PID=""
  fi

  if [[ "$teardown_ok" -eq 0 ]]; then
    echo "ERROR: could not stop and reap the writer process tree; skipping workspace removal." >&2
    echo "ORPHANED run-owned workspace may remain; it was not removed:" >&2
    cleanup_residue_note
    [[ "$status" -eq 0 ]] && status=1
  elif [[ "$OWNED" -eq 1 ]]; then
    if ! remove_owned_workspace; then
      [[ "$status" -eq 0 ]] && status=1
    fi
  fi

  rm -rf "$WORK"
  if [[ "$status" -eq 0 ]]; then
    echo "GHCR CLI lifecycle E2E passed."
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

tofu_ws() {
  local dir=$1
  shift
  TF_WORKSPACE="$TEST_WORKSPACE" "$GH_TOFU_BIN" -chdir="$dir" "$@"
}

latest_history_version() {
  python3 -c '
import json, sys
items = json.load(sys.stdin)
versions = sorted(int(item["version"]) for item in items)
if not versions:
    raise SystemExit("no history versions after the first apply")
print(versions[-1])
'
}

mkdir -p "$WRITER" "$READER" "$ADMIN"

cat > "$WRITER/main.tf" <<'HCL'
terraform {
  backend "oras" {
    repository   = "ghcr.io/vmvarela/gh-tofu-e2e"
    max_versions = 1
    lock_ttl     = 0
  }
}

variable "value" {
  type = string
}

resource "terraform_data" "value" {
  input            = var.value
  triggers_replace = [var.value]

  provisioner "local-exec" {
    # Keep registry credentials out of the marker-waiting child; the parent CLI
    # still uses them for the state write.
    command = "if [ -n \"$GH_TOFU_E2E_READY\" ]; then touch \"$GH_TOFU_E2E_READY\"; i=0; while [ ! -f \"$GH_TOFU_E2E_RELEASE\" ]; do i=$((i+1)); [ \"$i\" -gt 1200 ] && exit 1; sleep 0.25; done; fi"
    environment = {
      GH_TOKEN     = ""
      GITHUB_TOKEN = ""
    }
  }
}

output "value" {
  value = terraform_data.value.output
}
HCL
cp "$WRITER/main.tf" "$READER/main.tf"

cat > "$ADMIN/main.tf" <<'HCL'
terraform {
  backend "oras" {
    repository = "ghcr.io/vmvarela/gh-tofu-e2e"
  }
}
HCL

echo "Checking the fixed package preconditions and the separately owned anchor workspace"
"$GH_TOFU_BIN" -chdir="$ADMIN" init -input=false -no-color >/dev/null
WORKSPACES="$("$GH_TOFU_BIN" -chdir="$ADMIN" workspace list)"
if ! workspace_listed "$ANCHOR" "$WORKSPACES"; then
  fail "anchor workspace $ANCHOR is missing from $PACKAGE; create it separately before running this test."
fi
if workspace_listed "$TEST_WORKSPACE" "$WORKSPACES"; then
  fail "run workspace $TEST_WORKSPACE already exists; refusing to touch a workspace this run does not own."
fi

echo "Initializing the run-owned writer workspace"
"$GH_TOFU_BIN" -chdir="$WRITER" init -input=false -no-color >/dev/null
echo "Creating the unique run workspace"
"$GH_TOFU_BIN" -chdir="$WRITER" workspace new "$TEST_WORKSPACE" -no-color >/dev/null
OWNED=1

echo "Applying the first state"
if ! tofu_ws "$WRITER" apply -auto-approve -input=false -no-color -var='value=one' >"$WORK/apply-1.log" 2>&1; then
  fail "first apply failed; its output is suppressed to avoid logging state."
fi
HISTORY_ONE="$(tofu_ws "$WRITER" history list --json)"
FIRST_VERSION="$(printf '%s' "$HISTORY_ONE" | latest_history_version)" ||
  fail "could not capture the first history version."

echo "Applying a changed state and checking GHCR retention"
if ! tofu_ws "$WRITER" apply -auto-approve -input=false -no-color -var='value=two' >"$WORK/apply-2.log" 2>&1; then
  fail "second apply failed; its output is suppressed to avoid logging state."
fi
HISTORY_TWO="$(tofu_ws "$WRITER" history list --json)"
if ! printf '%s' "$HISTORY_TWO" | FIRST_VERSION="$FIRST_VERSION" python3 -c '
import json, os, sys
items = json.load(sys.stdin)
versions = [item["version"] for item in items]
first = int(os.environ["FIRST_VERSION"])
if first not in versions:
    raise SystemExit("first history version %d was pruned after max_versions=1" % first)
if max(versions) <= first:
    raise SystemExit("the changed apply did not publish a newer history version: %r" % versions)
'; then
  fail "GHCR did not preserve the first history version after the changed apply."
fi
if ! tofu_ws "$WRITER" history show --json "$FIRST_VERSION" | python3 -c '
import json, sys
state = json.load(sys.stdin)
if "one" not in json.dumps(state):
    raise SystemExit("first retained version is not the first apply state")
'; then
  fail "the first retained history version is not readable as the first apply state."
fi

echo "Initializing an independent reader and selecting the run workspace"
"$GH_TOFU_BIN" -chdir="$READER" init -input=false -no-color >/dev/null
"$GH_TOFU_BIN" -chdir="$READER" workspace select "$TEST_WORKSPACE" -no-color >/dev/null
echo "Checking a fresh-process no-change plan"
set +e
tofu_ws "$READER" plan -detailed-exitcode -input=false -no-color -var='value=two' \
  >"$WORK/plan-reader.log" 2>&1
READER_PLAN_STATUS=$?
set -e
if [[ "$READER_PLAN_STATUS" -ne 0 ]]; then
  fail "independent reader did not produce a no-change plan (exit $READER_PLAN_STATUS)."
fi
READER_VALUE="$(tofu_ws "$READER" output -raw value)"
if [[ "$READER_VALUE" != "two" ]]; then
  fail "independent reader did not observe the current state."
fi

echo "Exercising deterministic state-lock contention"
rm -f "$READY" "$RELEASE"
GH_TOFU_E2E_READY="$READY" GH_TOFU_E2E_RELEASE="$RELEASE" \
  TF_WORKSPACE="$TEST_WORKSPACE" \
  "$GH_TOFU_BIN" -chdir="$WRITER" apply \
  -auto-approve -input=false -no-color -var='value=three' \
  >"$HOLDER_LOG" 2>&1 &
HOLDER_PID=$!

for _ in {1..120}; do
  if [[ -f "$READY" ]]; then
    break
  fi
  if ! kill -0 "$HOLDER_PID" 2>/dev/null; then
    fail "lock-holder exited before signalling that it owned the lock."
  fi
  sleep 0.5
done
if [[ ! -f "$READY" ]]; then
  fail "timed out waiting for the lock-holder readiness signal."
fi

set +e
tofu_ws "$READER" plan -lock-timeout=0s -input=false -no-color -var='value=three' \
  >"$WORK/plan-lock.log" 2>&1
LOCK_STATUS=$?
set -e
touch "$RELEASE"

if [[ "$LOCK_STATUS" -eq 0 ]]; then
  fail "competing process unexpectedly acquired the state lock."
fi
if ! grep -qi "lock" "$WORK/plan-lock.log"; then
  fail "competing process failed without a recognizable lock diagnostic."
fi

if ! wait_for_holder "$HOLDER_PID"; then
  fail "lock-holder apply did not finish cleanly (failure or deadline); its output is suppressed to avoid logging state."
fi
HOLDER_PID=""

echo "Checking that work succeeds after the lock holder is reaped"
set +e
tofu_ws "$READER" plan -detailed-exitcode -input=false -no-color -var='value=three' \
  >"$WORK/plan-after.log" 2>&1
AFTER_STATUS=$?
set -e
if [[ "$AFTER_STATUS" -ne 0 ]]; then
  fail "operation after lock release failed (exit $AFTER_STATUS)."
fi
AFTER_VALUE="$(tofu_ws "$READER" output -raw value)"
if [[ "$AFTER_VALUE" != "three" ]]; then
  fail "post-contention read did not observe the state written under lock."
fi

echo "All lifecycle checks passed; deleting the run-owned workspace"
