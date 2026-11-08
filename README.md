# gh-tofu

gh-tofu is a GitHub-first distribution of [OpenTofu](https://opentofu.org) with an
`oras` state backend. The backend stores state, locks and retained state history as
OCI artifacts in a registry such as GitHub Container Registry (GHCR).

> **Not affiliated.** gh-tofu is an independent project. It is not affiliated with,
> endorsed by, or sponsored by GitHub or the OpenTofu project. OpenTofu names are used
> only to describe the software that gh-tofu distributes.

gh-tofu wraps one pinned OpenTofu release. Its version matches that OpenTofu release.

## Forms

- **GitHub CLI extension**: `gh tofu`.
- **Standalone executable**: `gh-tofu`, from the release assets.
- **Optional `tofu` command**: a symlink to `gh-tofu`, created by you.

## Install

### GitHub CLI extension

```sh
gh extension install vmvarela/gh-tofu
```

The extension uses the release asset for your platform, including Windows.

### Installer script (Linux and macOS, amd64 and arm64)

```sh
curl -sSfL https://raw.githubusercontent.com/vmvarela/gh-tofu/master/scripts/install.sh | sh
```

- Installs only `gh-tofu` into `INSTALL_DIR` (default `/usr/local/bin`). Use a writable
  directory if you do not have root access.
- Installs the latest stable release by default. Set `VERSION` to pin a version, for example `VERSION=1.13.2`.
- Verifies the download against `sha256sums.txt` before installing.

```sh
curl -sSfL https://raw.githubusercontent.com/vmvarela/gh-tofu/master/scripts/install.sh | INSTALL_DIR="$HOME/.local/bin" sh
```

### Standalone binary

Download `gh-tofu-<os>-<arch>` (or `gh-tofu-windows-amd64.exe`) from the release, and check
it against `sha256sums.txt`. Then make it executable and put it on your `PATH`.

Verify the downloaded release asset's provenance attestation with GitHub CLI:

```sh
gh attestation verify <asset> --repo vmvarela/gh-tofu
```

This requires GitHub CLI v2.67.0 or newer.

Optional `tofu` command:

```sh
ln -s gh-tofu tofu
```

### GitHub Action (Linux and macOS runners)

The composite action installs `gh-tofu` and adds it to `PATH`. It does not run OpenTofu,
configure state, or handle credentials.

```yaml
- uses: vmvarela/gh-tofu@<ref>
  with:
    version: "1.13.2"        # optional; empty installs the latest stable release
    install-dir: ""          # optional; empty uses $RUNNER_TEMP/gh-tofu-bin, which later steps in the job reuse
```

Pin `<ref>` to a tag or commit.

## First run

`gh tofu init` in an interactive terminal offers to set up the ORAS backend when the
root module has no `backend` or `cloud` block:

1. It asks whether to set up the backend. The default is no, and declining writes no file.
2. It asks for the repository, pre-filled with a suggestion when `origin` is a
   `github.com` HTTPS or SSH URL. The suggestion is
   `ghcr.io/<owner>/<repo>-tfstate`, plus the module's subdirectory inside the
   repository. Edit it before accepting. Other hosts, host aliases and GitHub Enterprise
   URLs produce no suggestion.
3. It writes `backend.tf` in the working directory, or `backend.gh-tofu.tf`,
   `backend.gh-tofu-2.tf` and so on when that name is taken. Existing files are never
   overwritten. An invalid location fails immediately without writing a file.

OpenTofu then runs its normal backend migration and confirmation prompts. gh-tofu does
not inspect, copy, delete or change state itself. If init or migration fails, the
generated file is kept so you can fix the error and run `gh tofu init` again.

The assistant is skipped when a `backend` or `cloud` block already exists, and in
non-interactive use: no terminal, `-input=false`, `TF_INPUT=0`, `-backend=false`,
`-json`, `-backend-config`, or `-force-copy`. CI must configure the backend explicitly.

> An ORAS-configured directory requires gh-tofu. Stock Terraform and OpenTofu builds do
> not include the `oras` backend and fail on these configurations.

## Configure the backend

The state repository is required. It must be a plain string literal in the HCL backend
block, in the form `<registry>/<repository>`, without a tag or digest. Variables, locals,
functions, and `null` are rejected, and so are values from environment variables such as
`TF_VAR_*`. `-backend-config` cannot set or override it: `init` fails if the block omits
it, or if `-backend-config` supplies it, whether as an argument or in a file. Other options
may still come from `-backend-config`.
In `.tf.json` files, a repository value that contains a `${` or `%{` template sequence is
rejected too, including escaped forms such as `$${`. A plain JSON string is accepted.

```hcl
terraform {
  backend "oras" {
    repository = "ghcr.io/my-org/infra-state"
  }
}
```

Then run the usual workflow:

```sh
gh tofu init
gh tofu plan
gh tofu apply
```

## Authentication

The backend and the first-run assistant use the same credentials. The assistant never
asks for or stores a registry token; it only writes the repository location.

For `ghcr.io`, gh-tofu tries these sources in order and uses the first token it finds:

1. `GH_TOKEN`
2. `GITHUB_TOKEN`
3. `gh auth token --hostname github.com`, run non-interactively with a 10-second limit.
4. OCI/Docker credentials: the registry credentials configured for OpenTofu, Docker-style
   `config.json`, and Docker credential helpers.

If no GitHub token is found, or the `gh` call fails, gh-tofu logs a warning and falls
back to step 4. A rejected token is not retried with other credentials.

For `ghcr.io`, credentials go only over HTTPS to the `ghcr.io` token endpoint and registry
API. During explicit tag deletion they also go to the GitHub Packages API calls that list
and delete that package's versions on `api.github.com`. No other host or path receives them.
Other registries use step 4 only. Their token requests go over HTTPS. With `insecure`,
credentials go only to the registry host.

## Backend options

| Option | Default | Meaning |
| --- | --- | --- |
| `repository` | required | OCI repository that holds the state, set only in the HCL backend block. No tag or digest. `-backend-config` and environment variables cannot set it. |
| `compression` | `none` | `none` or `gzip`. |
| `lock_ttl` | `0` | Lock lease in seconds. `0` disables automatic stale-lock clearing. |
| `max_versions` | `0` | Number of state versions to retain. `0` disables history. |
| `max_state_size` | `0` | Maximum state size in bytes. `0` uses the 256 MiB default. |
| `ca_file` | unset | PEM CA bundle to trust for the registry. |
| `insecure` | `false` | Plain HTTP and skipped TLS verification. Use only for local test registries. Rejected for `ghcr.io`. With `insecure`, credentials go only to the registry host. |
| `retry_max`, `retry_wait_min`, `retry_wait_max` | `2`, `1`, `30` | Retries for transient registry errors. Waits are in seconds. |
| `rate_limit`, `rate_limit_burst` | `0`, `0` | Registry requests per second. `0` disables rate limiting. |

## State history

With `max_versions` greater than `0`, the backend publishes retained state versions. You
can inspect them without knowing the OCI tag layout:

```sh
gh tofu history list
gh tofu history list --json
gh tofu history show 3
gh tofu history show --json 3
gh tofu history pull --output recovery.tfstate 3
```

- `history list` shows metadata only, never state contents.
- `history show` prints one retained state.
- `history pull` writes one version to a new file with mode `0600`. It never overwrites
  an existing file.

Backends without this capability return a clear error. History is read-only. Restore,
per-version deletion and garbage collection are not provided.

## Data safety and limits

- gh-tofu does not retry a whole state or workspace delete, because a retry could delete
  state that another process wrote in the meantime. On `ghcr.io`, oras-state can retry the
  package-version DELETE for the same version ID, up to three attempts, when GitHub
  reports that version as not yet deletable (HTTP 404). If a delete reports an error,
  check the registry before you run it again.
- Registry tags are last-writer-wins. Locks are verified before each write, but there is
  no strict distributed compare-and-swap. If a mutable tag moved or became ambiguous, the
  write stops instead of being retried blindly.
- If a lock was lost or its lease expired, gh-tofu refuses to write state
  (`refusing to write state`).
- If history publication fails after the state was written, the command reports an error.
  Do not assume the write fully failed, and do not assume the state is still current,
  because another writer may have superseded it.
- Before you enable or change retention, stop older writers and let their background
  retention finish. A new process does not fence old processes.
- On `ghcr.io`, history is published and readable, but it is not pruned automatically.
  `max_versions` does not cap history there, and it can grow without limit. On other
  registries, pruning is best-effort.

## Live GHCR CLI lifecycle test

The normal `verify` workflow uses a disposable local registry. To test the CLI against GHCR, run the `GHCR CLI lifecycle` workflow manually from `master` and set `run_ghcr_e2e` to `true`. It rejects other repositories and refs, and gives package-write permission only to this job.

Before the first run, configure the test package `ghcr.io/vmvarela/gh-tofu-e2e` for this repository and create a separate `gh-tofu-e2e-anchor` workspace. The workflow must have package-admin access to delete package versions; `packages: write` alone is not enough. Keep the anchor intact. The test uses synthetic state in a unique run-and-attempt workspace; never point it at a real state repository.

Cleanup removes only the run's tagged workspace; it does not delete the package. GHCR may retain untagged package versions and does not prune this history. The job fails and reports the package, workspace and run IDs if it cannot confirm workspace deletion. Do not delete the whole package to clean up a run.

After an authorized successful run, record its Actions URL and cleanup outcome in issue #5. Do not include state contents or credentials in the report.

## License

See [LICENSE](LICENSE).
