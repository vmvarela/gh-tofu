"""Check the opt-in GHCR E2E workflow and its offline contract.

Parses .github/workflows/ghcr-e2e.yml without external YAML dependencies: it must stay
workflow_dispatch-only, require the typed boolean opt-in, run only on the trusted
master checkout, keep write access confined to the job's package permission, and hand
the trigger SHA and GH_TOKEN only to the lifecycle step. Also checks the Makefile target
and the normal Verify wiring.

When scripts/e2e-ghcr.sh is present (the lifecycle lane supplies it), runs it offline
with a fake CLI: refusal paths must stop before touching the CLI, and failure or signal
must still clean up the run-unique workspace. No registry, network, or credentials.
"""
import os
from pathlib import Path
import signal
import stat
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / '.github' / 'workflows' / 'ghcr-e2e.yml'
VERIFY = ROOT / '.github' / 'workflows' / 'verify.yml'
MAKEFILE = ROOT / 'Makefile'
SCRIPT = ROOT / 'scripts' / 'e2e-ghcr.sh'
JOB = 'ghcr-e2e'
STEP = '- name: Run GHCR CLI lifecycle'
SOURCE_SHA = 'a' * 40

FAKE_CLI = '''#!/bin/sh
printf 'gh-tofu %s\\n' "$*" >> "$FAKE_LOG"
if [ -n "${FAKE_FAIL_MATCH:-}" ]; then
  case "$*" in *"$FAKE_FAIL_MATCH"*) exit 1 ;; esac
fi
case "$*" in
  *"workspace list"*) printf '* gh-tofu-e2e-anchor\\n'; exit 0 ;;
esac
if [ -n "${FAKE_HANG_MARKER:-}" ] && [ -n "${FAKE_HANG_MATCH:-}" ] &&
  [ ! -e "$FAKE_HANG_MARKER" ]; then
  case "$*" in *"$FAKE_HANG_MATCH"*)
    : > "$FAKE_HANG_MARKER"
    sleep 300 ;;
  esac
fi
exit 0
'''
FAKE_COMMAND = '''#!/bin/sh
printf '%s %s\\n' "$(basename "$0")" "$*" >> "$FAKE_LOG"
exit 0
'''

# Enough of the lifecycle to reach the lock-holder timeout. The holder forks a real
# child (like a provisioner) and never exits; the delete branch fails if that child is
# still alive, proving cleanup reaps the writer tree before removing the workspace.
LIFECYCLE_CLI = '''#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_LOG"
case "$*" in
  *"workspace list"*) printf '* gh-tofu-e2e-anchor\\n'; exit 0 ;;
  *"workspace delete"*)
    pid="$(cat "$FAKE_CHILD_PID_FILE" 2>/dev/null || true)"
    if [ -n "$pid" ]; then
      state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
      if [ -n "$state" ] && [ "${state#Z}" = "$state" ]; then
        printf 'DELETE-WHILE-CHILD-ALIVE\\n' >> "$FAKE_LOG"
        exit 9
      fi
    fi
    exit 0 ;;
  *"history list"*)
    count="$(cat "$FAKE_STATE_DIR/history" 2>/dev/null || echo 0)"
    count=$((count + 1))
    printf '%s\\n' "$count" > "$FAKE_STATE_DIR/history"
    if [ "$count" -eq 1 ]; then
      printf '[{"version":1}]\\n'
    else
      printf '[{"version":1},{"version":2}]\\n'
    fi
    exit 0 ;;
  *"history show"*) printf '{"outputs":{"value":{"value":"one"}}}\\n'; exit 0 ;;
  *"output -raw value"*) printf 'two\\n'; exit 0 ;;
  *"-lock-timeout=0s"*) printf 'Error: state lock is held\\n' >&2; exit 1 ;;
  *"-detailed-exitcode"*) exit 0 ;;
  *"-var=value=three"*)
    printf '%s\\n' "$$" > "$FAKE_HOLDER_PID_FILE"
    : > "$GH_TOFU_E2E_READY"
    /bin/sleep 300 &
    child=$!
    printf '%s\\n' "$child" > "$FAKE_CHILD_PID_FILE"
    wait "$child"
    exit $? ;;
esac
exit 0
'''

SLEEP_SHIM = '''#!/bin/sh
exit 0
'''
ALIVE_PS_SHIM = '''#!/bin/sh
echo S
'''
NOOP_KILL_SHIM = '''#!/bin/sh
exit 0
'''


def indent(line):
    return len(line) - len(line.lstrip())


def job_block(name):
    lines = WORKFLOW.read_text().splitlines()
    start = next(i for i, line in enumerate(lines) if line == f'  {name}:')
    end = next((i for i in range(start + 1, len(lines))
                if lines[i].strip() and indent(lines[i]) <= 2), len(lines))
    return lines[start:end]


def permissions(block):
    start = next(i for i, line in enumerate(block) if line.strip() == 'permissions:')
    values = {}
    for line in block[start + 1:]:
        if not line.strip():
            continue
        if indent(line) <= indent(block[start]):
            break
        key, _, value = line.strip().partition(':')
        values[key] = value.strip()
    return values


def step_block(job, marker):
    start = next(i for i, line in enumerate(job) if line.strip() == marker)
    end = next((i for i in range(start + 1, len(job))
                if job[i].strip() and indent(job[i]) <= indent(job[start])), len(job))
    return job[start:end]


def top_level_block(lines, key):
    start = next(i for i, line in enumerate(lines) if line == f'{key}:')
    return lines[start + 1:next((i for i in range(start + 1, len(lines))
                                 if lines[i].strip() and indent(lines[i]) == 0), len(lines))]


def folded_value(block, key):
    start = next(i for i, line in enumerate(block) if line.strip().startswith(f'{key}:'))
    parts = [block[start].strip().partition(':')[2].lstrip('>- ').strip()]
    for line in block[start + 1:]:
        if line.strip() and indent(line) <= indent(block[start]):
            break
        parts.append(line.strip())
    return ' '.join(part for part in parts if part)


class GhcrWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.lines = WORKFLOW.read_text().splitlines()
        self.text = '\n'.join(self.lines)
        self.job = job_block(JOB)

    def test_only_manual_dispatch_with_typed_default_off_opt_in(self):
        trigger = top_level_block(self.lines, 'on')
        keys = [line.strip()[:-1] for line in trigger
                if line.strip().endswith(':') and indent(line) == 2]
        self.assertEqual(keys, ['workflow_dispatch'])
        self.assertNotIn('pull_request:', self.text)
        self.assertNotIn('push:', self.text)
        self.assertNotIn('schedule:', self.text)

        start = next(i for i, line in enumerate(trigger) if line.strip() == 'run_ghcr_e2e:')
        block = trigger[start + 1:next((i for i in range(start + 1, len(trigger))
                                        if trigger[i].strip()
                                        and indent(trigger[i]) <= indent(trigger[start])),
                                       len(trigger))]
        fields = [line.strip() for line in block]
        self.assertIn('type: boolean', fields)
        self.assertIn('default: false', fields)

    def test_job_runs_only_on_opt_in_trusted_repository_and_master(self):
        gate = folded_value(self.job, 'if')
        self.assertIn('inputs.run_ghcr_e2e == true', gate)
        self.assertIn("github.repository == 'vmvarela/gh-tofu'", gate)
        self.assertIn("github.ref == 'refs/heads/master'", gate)

    def test_permissions_are_read_only_except_the_job_package_write(self):
        self.assertEqual(permissions(self.lines), {'contents': 'read'})
        self.assertEqual(permissions(self.job), {'contents': 'read', 'packages': 'write'})
        self.assertNotIn('write-all', self.text)

    def test_checkout_pins_the_trigger_sha_and_drops_credentials(self):
        checkout = [line.strip() for line in
                    step_block(self.job, '- uses: actions/checkout@v7')]
        self.assertIn('ref: ${{ github.sha }}', checkout)
        self.assertIn('persist-credentials: false', checkout)

    def test_builds_the_checkout_before_the_lifecycle_target(self):
        self.assertIn('bash ./scripts/build.sh', self.text)
        self.assertLess(self.text.index('bash ./scripts/build.sh'),
                        self.text.index('make e2e-ghcr'))

    def test_gh_token_is_scoped_to_the_lifecycle_step(self):
        self.assertEqual(self.text.count('GH_TOKEN'), 1)
        self.assertEqual(self.text.count('secrets.GITHUB_TOKEN'), 1)
        step = [line.strip() for line in step_block(self.job, STEP)]
        self.assertIn('GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}', step)
        self.assertIn('GH_TOFU_GHCR_E2E: "1"', step)
        self.assertTrue(any(line.startswith('GH_TOFU_BIN:') for line in step))
        self.assertTrue(any(line == 'run: make e2e-ghcr' for line in step))

    def test_timeout_and_no_state_artifacts(self):
        timeout = next(line for line in self.job if line.strip().startswith('timeout-minutes:'))
        self.assertGreaterEqual(int(timeout.split(':', 1)[1]), 30)
        for leaking in ('upload-artifact', 'download-artifact', 'actions/cache',
                        'GITHUB_STEP_SUMMARY'):
            self.assertNotIn(leaking, self.text)


class WiringTests(unittest.TestCase):
    def test_make_target_is_manual_and_has_no_prerequisite(self):
        lines = MAKEFILE.read_text().splitlines()
        target = next(i for i, line in enumerate(lines) if line.startswith('e2e-ghcr:'))
        self.assertEqual(lines[target].partition(':')[2].strip(), '')
        self.assertTrue(lines[target + 1].startswith('\t'))
        self.assertIn('scripts/e2e-ghcr.sh', lines[target + 1])
        phony = next(line for line in lines if line.startswith('.PHONY:'))
        self.assertIn('e2e-ghcr', phony.split())

    def test_normal_verify_runs_the_offline_contract(self):
        steps = [line.strip() for line in VERIFY.read_text().splitlines()]
        self.assertIn('run: python3 scripts/test-e2e-ghcr.py', steps)
        self.assertNotIn('make e2e-ghcr', '\n'.join(steps))


@unittest.skipUnless(SCRIPT.exists(), 'scripts/e2e-ghcr.sh comes from the lifecycle lane')
class GhcrScriptTests(unittest.TestCase):
    def setUp(self):
        self.text = SCRIPT.read_text()
        self.tmp = tempfile.TemporaryDirectory()
        # Registered first so PID reaping cleanups (added later) run before the dir goes.
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.bin = self.work / 'bin'
        self.bin.mkdir()
        self.log = self.work / 'fake.log'
        self.tmpdir = self.work / 'tmp'
        self.tmpdir.mkdir()
        for name, text in (('gh-tofu', FAKE_CLI), ('gh', FAKE_COMMAND),
                           ('oras', FAKE_COMMAND)):
            stub = self.bin / name
            stub.write_text(text)
            stub.chmod(stub.stat().st_mode | stat.S_IXUSR)

    def env(self, **overrides):
        env = dict(os.environ)
        env.update({
            'PATH': f'{self.bin}{os.pathsep}{env["PATH"]}',
            'TMPDIR': str(self.tmpdir),
            'FAKE_LOG': str(self.log),
            'GH_TOFU_GHCR_E2E': '1',
            'GH_TOFU_BIN': str(self.bin / 'gh-tofu'),
            'GH_TOKEN': 'offline-test-token',
            'GITHUB_REPOSITORY': 'vmvarela/gh-tofu',
            'GITHUB_REF': 'refs/heads/master',
            'GITHUB_SHA': SOURCE_SHA,
            'GITHUB_RUN_ID': '12345',
            'GITHUB_RUN_ATTEMPT': '1',
        })
        env.update(overrides)
        return env

    def run_script(self, source=False, **overrides):
        command = ['bash', '--noprofile', '--norc']
        if source:
            # Disable the kill builtin so the PATH shim can simulate an unkillable tree.
            command += ['-c', 'enable -n kill; source "$1"', '_', str(SCRIPT)]
        else:
            command += [str(SCRIPT)]
        return subprocess.run(
            command, cwd=ROOT, env=self.env(**overrides), capture_output=True, text=True,
            timeout=60)

    def install_lifecycle_cli(self, unkillable_tree=False):
        for name, text in (('gh-tofu', LIFECYCLE_CLI), ('sleep', SLEEP_SHIM)):
            stub = self.bin / name
            stub.write_text(text)
            stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
        if unkillable_tree:
            for name, text in (('ps', ALIVE_PS_SHIM), ('kill', NOOP_KILL_SHIM)):
                stub = self.bin / name
                stub.write_text(text)
                stub.chmod(stub.stat().st_mode | stat.S_IXUSR)

    def track_lifecycle_pids(self, *pid_files):
        def reap():
            for pid_file in pid_files:
                try:
                    pid = int(pid_file.read_text())
                except (OSError, ValueError):
                    continue
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        self.addCleanup(reap)

    def assert_process_gone(self, pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        state = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)],
                               capture_output=True, text=True).stdout.strip()
        self.assertIn(state, ('', 'Z'), f'writer process {pid} is still running: {state}')

    def assert_refused(self, **overrides):
        result = self.run_script(**overrides)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((result.stdout + result.stderr).strip())
        self.assertFalse(self.log.exists() and self.log.read_text().strip(),
                         'the CLI ran before the gate refused')
        self.assertEqual(list(self.tmpdir.iterdir()), [])

    def test_refuses_without_opt_in(self):
        self.assert_refused(GH_TOFU_GHCR_E2E='0')

    def test_refuses_outside_the_trusted_repository(self):
        self.assert_refused(GITHUB_REPOSITORY='someone/fork')

    def test_refuses_outside_master(self):
        self.assert_refused(GITHUB_REF='refs/heads/feature')

    def test_refuses_incomplete_run_identity(self):
        for name in ('GITHUB_SHA', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT'):
            with self.subTest(name=name):
                self.assert_refused(**{name: ''})

    def test_refuses_without_credentials_or_binary(self):
        for name in ('GH_TOKEN', 'GH_TOFU_BIN'):
            with self.subTest(name=name):
                self.assert_refused(**{name: ''})

    def test_uses_the_fixed_package_anchor_and_run_workspace(self):
        for needle in ('ghcr.io/vmvarela/gh-tofu-e2e', 'gh-tofu-e2e-anchor'):
            self.assertIn(needle, self.text)
        self.assertRegex(self.text,
                         r'gh-tofu-ci-\$\{?GITHUB_RUN_ID\}?-\$\{?GITHUB_RUN_ATTEMPT\}?')

    def test_cleanup_covers_exit_and_signals(self):
        traps = [line for line in self.text.splitlines() if line.strip().startswith('trap ')]
        joined = ' '.join(traps)
        self.assertIn('EXIT', joined)
        self.assertTrue('INT' in joined or 'TERM' in joined)

    def code_lines(self):
        return '\n'.join(line for line in self.text.splitlines()
                         if not line.lstrip().startswith('#'))

    def test_cleanup_deletes_only_the_exact_run_owned_workspace_via_cli(self):
        code = self.code_lines()
        self.assertIn('workspace delete', code)
        self.assertIn('-force "$TEST_WORKSPACE"', code)
        self.assertIn('"$GH_TOFU_BIN"', code)

    def test_cleanup_never_calls_the_packages_api_or_deletes_package_level_state(self):
        code = self.code_lines()
        for forbidden in ('gh api', 'curl', 'wget', 'packages/', '--method DELETE',
                          'DELETE '):
            self.assertNotIn(forbidden, code)

    def test_cleanup_requires_the_derived_workspace_ownership_guards(self):
        code = self.code_lines()
        self.assertIn(
            '"$TEST_WORKSPACE" != "gh-tofu-ci-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"', code)
        self.assertIn('"$TEST_WORKSPACE" == "$ANCHOR"', code)
        self.assertIn('"$TEST_WORKSPACE" == "default"', code)

    def test_failure_cleans_only_the_exact_run_workspace(self):
        result = self.run_script(FAKE_FAIL_MATCH='apply')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        log = self.log.read_text()
        self.assertIn('workspace delete -force gh-tofu-ci-12345-1', log)
        self.assertNotIn('api', log)
        self.assertEqual(list(self.tmpdir.iterdir()), [])

    def test_signal_cleans_only_the_exact_run_workspace(self):
        marker = self.work / 'hanging'
        env = self.env(FAKE_HANG_MARKER=str(marker), FAKE_HANG_MATCH='apply')
        process = subprocess.Popen(
            ['bash', '--noprofile', '--norc', str(SCRIPT)],
            cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, start_new_session=True)
        deadline = time.monotonic() + 10
        while not marker.exists() and process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertTrue(marker.exists(), 'the fake CLI never reached the hanging call')
        os.killpg(process.pid, signal.SIGTERM)
        process.communicate(timeout=30)
        self.assertNotEqual(process.returncode, 0)
        log = self.log.read_text()
        self.assertIn('workspace delete -force gh-tofu-ci-12345-1', log)
        self.assertNotIn('api', log)
        self.assertEqual(list(self.tmpdir.iterdir()), [])

    def lifecycle_env(self):
        child = self.work / 'child.pid'
        holder = self.work / 'holder.pid'
        self.track_lifecycle_pids(child, holder)
        return {
            'FAKE_STATE_DIR': str(self.work),
            'FAKE_CHILD_PID_FILE': str(child),
            'FAKE_HOLDER_PID_FILE': str(holder),
        }, child, holder

    def test_holder_timeout_reaps_the_writer_tree_before_deleting_the_workspace(self):
        self.install_lifecycle_cli()
        overrides, child_file, holder_file = self.lifecycle_env()
        result = self.run_script(**overrides)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('lock-holder apply did not finish cleanly', result.stderr)
        log = self.log.read_text()
        self.assertIn('workspace delete -force gh-tofu-ci-12345-1', log)
        self.assertNotIn('DELETE-WHILE-CHILD-ALIVE', log)
        self.assertNotIn('skipping workspace removal', result.stderr)
        self.assert_process_gone(int(child_file.read_text()))
        self.assert_process_gone(int(holder_file.read_text()))
        self.assertEqual(list(self.tmpdir.iterdir()), [])

    def test_unconfirmed_teardown_skips_deletion_and_reports_the_orphan(self):
        self.install_lifecycle_cli(unkillable_tree=True)
        overrides, child_file, holder_file = self.lifecycle_env()
        result = self.run_script(source=True, **overrides)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        log = self.log.read_text() if self.log.exists() else ''
        self.assertNotIn('workspace delete', log)
        self.assertIn('could not stop and reap the writer process tree', result.stderr)
        self.assertIn('ORPHANED', result.stderr)
        self.assertIn('skipping workspace removal', result.stderr)
        self.assertEqual(list(self.tmpdir.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
