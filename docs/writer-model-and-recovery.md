# Writer model and state recovery

This document describes gh-tofu 1.13.x — the `oras` backend built on
[oras-state](https://github.com/vmvarela/oras-state) `v0.2.3`. It states the
writer model the backend supports, how to serialize writers outside gh-tofu,
and how to recover after lock or publication failures.

Examples use `tofu`; substitute your install form: the `gh tofu` extension
command or the optional `tofu` symlink.

> Portable compare-and-swap on OCI tags is an upstream investigation:
> [vmvarela/oras-state#11](https://github.com/vmvarela/oras-state/issues/11).
> This document deliberately does not present extra checks, re-tags or delays
> as a strict concurrency fix.

## Supported writer model

**At most one active writer per state repository workspace.** A writer is any
operation that publishes state: `apply`, `state push`, `state mv`, `state rm`,
or workspace deletion. Any process with registry credentials can write — the
state repository, not your configuration repository, is the boundary.

- **Read-only commands** (`plan`, `state pull`, `history list|show|pull`) do not
  need the writer position; they may run concurrently.
- **Different workspaces** in the same state repository hold independent locks
  and can be written in parallel — but they may still touch the same
  infrastructure resources.
- **OCI tags are last-writer-wins.** There is no compare-and-swap on a tag and
  registries do not enforce leases. The backend narrows races and fails closed;
  it cannot eliminate them.

## What the state lock does

When an operation begins, the backend publishes a lock manifest for the
workspace. It records the holder ID, operation, creation time and — when
`lock_ttl` is set — an expiry. Acquisition increments a generation counter and
re-reads the tag after a short stability window, so two simultaneous acquirers
do not both believe they won.

Nothing in OCI actually enforces this:

- The backend re-verifies the lock **immediately before** each state write. The
  verify and the write are separate operations, so another writer that takes
  over in between does not see the check. A process that lost its lock refuses
  to write (`refusing to write state`) instead of clobbering.
- If a registry responds ambiguously while a mutable tag is published — the
  response is lost or the tag resolves to a foreign manifest — the backend
  fails closed. It never retries a publication blindly, because re-applying a
  tag would overwrite whoever wrote last.
- These are mitigations, not fencing.

## Lock lifetime: TTL and staleness

`lock_ttl` (`TF_BACKEND_ORAS_LOCK_TTL`) sets a lease **at acquisition**; it is
stored in the lock manifest and is never renewed.

- **Default `0`**: the lock never expires. A stale lock survives until it is
  released or force-unlocked. No other writer will clear it automatically.
- **`lock_ttl` `> 0`**: once the stored expiry passes, a *later* `Lock` attempt
  by any writer configured with a positive TTL may clear the stale lock and
  take over. The expiry is compared against the reader's local clock; clock
  skew between holders is not modeled.
- Choose a TTL comfortably longer than your worst-case apply. There is no
  renewal: a lease that expires mid-apply causes exactly the failure described
  under [lock loss](#lock-lost-or-lease-expired-during-an-operation) below.
  Defaults and other options: [backend options](../README.md#backend-options).

`tofu force-unlock <LOCK_ID>` releases a lock. It requires the exact holder ID
from the lock error, marks the registry lock gone (on GHCR it retags to the
`unlocked-` marker, because GHCR cannot delete manifests), and — deliberately —
checks nothing else.

## External serialization

The lock detects contention; it does not schedule writers. Keep one mutating
operation at a time per state repository workspace **by policy**, outside
gh-tofu:

**A single pipeline.** Run applies from one workflow. If more than one
pipeline exists (for example staging and production in different
configuration repositories sharing a state repository), serialize them with an
external scheduler that spans all of them.

**GitHub Actions concurrency is repository-scoped.** The `concurrency` key
serializes workflow runs *within the repository that defines it*, keyed by the
group you choose. That makes it a useful mitigation, not registry-wide fencing:

- It never sees runs from other repositories, forks, or local runs.
- A newer queued run can replace an older pending run. Cancelling a running
  `apply` can interrupt it between an infrastructure change and the state
  write, leaving applied infrastructure and unwritten state.
- Key the group by the state repository and workspace, for example
  `state-vmvarela-infra-state-prod` (use the actual state repository name),
  and set `cancel-in-progress: false` for jobs that apply. Re-running a
  cancelled apply is recovery work (see
  [recovery](#lock-lost-or-lease-expired-during-an-operation)), not a lost
  cause — but decide it, don't let a queue do it.

**Local writers.** Anyone running `apply` from a workstation is invisible to
CI concurrency groups. Agree on a rule — CI only, or announce-and-lock — and
rely on the state lock to enforce the second: a second writer gets
`state is locked` with the holder's operation and start time, and `-lock-timeout`
only waits to *acquire*; it does not fence whoever holds it.

**Cross-repository scope.** Two writers using different *configuration*
repositories against the *same* state repository share the lock (it lives in the
registry) but not a concurrency group. Two writers using different *state*
repositories share nothing at all — if their stacks touch common resources,
that interference happens at the provider, and only external coordination by
infrastructure scope can prevent it.

**Retention changes.** Before enabling or changing `max_versions`, stop older
runners and let their background retention finish. A new process does not fence
old ones.

## Recovery

Quick reference:

| Symptom in the command output | What it means | First step |
| --- | --- | --- |
| `state is locked` with holder info | Another writer holds the lock | Confirm no writer is active, then `force-unlock` |
| `refusing to write state: this process no longer holds the state lock` | Your lock vanished or its lease expired before the write | Recover from `errored.tfstate`; do not simply re-run |
| `mutable OCI tag moved or ambiguous` | The write's outcome is unknown | Inspect remote state before doing anything |
| `state published under "…", but publishing version tag "…" failed` | Partial: state publication succeeded, history publication failed | Read current state and audit history |
| `Failed to save state` after apply, plus `errored.tfstate` in the working directory | State save failed, local snapshot kept | Follow the recovery steps, then push the snapshot if it is the newest |

### Stuck lock

1. Read the holder from the error: who, operation, created, path.
2. Confirm nothing is running: check CI runs for every repository that writes
   this state repository, and anyone who shares credentials.
3. `tofu force-unlock <LOCK_ID>`.
4. If `lock_ttl > 0`, the next writer's `Lock` clears an expired lock by
   itself; with the default `0` it never does.

Do not force-unlock while a writer is active. The running writer loses its
lease on the next verification and its state write is refused — you convert a
clean failure into recovery work.

### Lock lost or lease expired during an operation

The operation reports `refusing to write state: this process no longer holds
the state lock`. Infrastructure changes from this run may exist in the cloud;
the state write was refused, so remote state does not record them. On `apply`,
OpenTofu writes that attempted state to **`errored.tfstate`** in the working
directory rather than losing it, and stops with `Failed to save state`.

1. Keep `errored.tfstate`. It contains the full intended end state and is as
   sensitive as any state file — restrict access to it, never commit it, and
   delete it once recovery is complete.
2. Establish what actually happened. `tofu state pull > recovery-inspect.json`
   (redirect to a file you secure) or run `tofu plan` to see the drift between
   remote state and configuration, and compare against the cloud resources in
   your provider's console or API.
3. Decide who owns the workspace — check CI runs for every writing repository
   and anyone sharing credentials first:
   - Another writer superseded you: their state is authoritative. Inspect the
     drift it will show on the next plan and reconcile infrastructure through
     plan/apply, not by overwriting their state.
   - You are the only writer (lease expired, forced unlock, infrastructure
     error): the snapshot in `errored.tfstate` is the newest truth.
4. Publish the newest truth with `tofu state push errored.tfstate`. The command
    takes the state lock by default and refuses an older serial or a foreign
    lineage; use `-force` only after you have verified the serial, lineage and
    content, and that no other writer is active. Do not pass `-lock=false`.
5. Confirm with `tofu plan` that there is no drift, then delete the snapshot.

Never recover by immediately re-running `apply`: it reads the (older) remote
state, plans against it, and re-creates changes you already made — a forked
state and duplicated changes. Reconcile through the state file first.

### Ambiguous publication

When a state write ends in `mutable OCI tag moved or ambiguous`, the backend
refused to proceed because it could not determine who owns the tag now. The
write may or may not have applied. There is no rollback to perform.

1. Do not retry the write from the same process.
2. Read the remote state (`tofu state pull > recovery-inspect.json`, secured).
3. If it already contains the intended result, you are done: confirm with a
   fresh plan.
4. If it does not, re-run the operation normally after re-acquiring the lock.
   `apply` refreshes remote state first and reconciles whatever previous runs
   left half-applied, so no forked state is created.
5. `errored.tfstate` may exist from the failed run; keep it secured until the
   fresh run has converged.

### Partial history publication

`state published under "state-…", but publishing version tag "stver-…-vN"
failed` means the current state **is** published and was verified as ours at
that moment, while the retention copy failed. There is no rollback and no
automatic retry.

- The state tag may have been superseded by a later writer when you observe the
  error. Do not assume version `N` is absent or belongs to this write; inspect
  its entry and metadata with `tofu history list`.
- Do not re-apply to republish history. The next successful write continues
  version numbering from what exists; there is no automatic retry or rollback.
- If the expected version exists, inspect it with
  `tofu history pull --output recovery.tfstate <N>`.
- On GHCR, history is not pruned and `max_versions` does not bound it; any
  missing history remains missing unless a later write publishes it.

### If state was never published

If the whole write failed before the registry accepted anything (network
error, size limit, lock refusal) and no newer writer exists, the workspace
still holds the previous state. `tofu plan` shows the pending changes; re-run
the operation once you know why the write failed.
