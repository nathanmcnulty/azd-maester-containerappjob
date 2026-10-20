"""Run the actual embedded launcher without network or Azure credentials."""
import base64
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = ROOT / 'scripts' / 'Start-MaesterRuntimeBootstrap.sh'


class KeylessLauncherTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix='keyless-launcher-test-')
        self.path = Path(self.work.name)
        (self.path / 'bin').mkdir()
        (self.path / 'temp').mkdir()
        self.fake = self.path / 'bin' / 'pwsh'
        self.fake.write_text('''#!/bin/sh
set -eu
while [ "$1" != '-Destination' ]; do shift; done
shift
test -d "$1"
test -z "$(ls -A "$1")"
test -d "$HOME"
test -d "$XDG_CONFIG_HOME"
test -d "$XDG_CACHE_HOME"
if [ "$TEST_MODE" = 'failure' ]; then exit 17; fi
cat > "$1/Start-MaesterContainerJob.sh" <<'RUNNER'
#!/bin/sh
set -eu
test "$1" = 'nonacr'
printf 'started' > "$TEST_ROOT/started"
if [ "$TEST_MODE" = 'cancel' ]; then
  trap 'printf terminated > "$TEST_ROOT/terminated"; exit 143' TERM
  while :; do sleep 1; done
fi
exit 23
RUNNER
''')
        self.fake.chmod(0o700)
        self.env = dict(os.environ, PATH=str(self.path / 'bin') + ':' + os.environ['PATH'],
                        TMPDIR=str(self.path / 'temp'), TEST_ROOT=str(self.path),
                        MAESTER_RUNTIME_BOOTSTRAP=base64.b64encode(b'# offline fixture').decode())

    def tearDown(self):
        self.work.cleanup()

    def run_launcher(self, mode):
        return subprocess.run(['/bin/sh', str(LAUNCHER)], env=dict(self.env, TEST_MODE=mode),
                              capture_output=True, timeout=10)

    def assert_cleaned(self):
        self.assertEqual(list((self.path / 'temp').iterdir()), [])

    def test_bootstrap_failure_is_returned_and_assessment_never_runs(self):
        result = self.run_launcher('failure')
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertFalse((self.path / 'started').exists())
        self.assert_cleaned()

    def test_assessment_exit_is_propagated_and_owned_files_removed(self):
        result = self.run_launcher('success')
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertTrue((self.path / 'started').exists())
        self.assert_cleaned()

    def test_termination_reaches_child_and_cleans_owned_directory(self):
        process = subprocess.Popen(['/bin/sh', str(LAUNCHER)], env=dict(self.env, TEST_MODE='cancel'),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 5
            while not (self.path / 'started').exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue((self.path / 'started').exists())
            process.send_signal(signal.SIGTERM)
            _, err = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 143, err)
            self.assertTrue((self.path / 'terminated').exists())
            self.assert_cleaned()
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()


if __name__ == '__main__':
    unittest.main()
