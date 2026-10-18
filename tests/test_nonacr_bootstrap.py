"""Fault injection for the unchanged production shell entry point (no Azure)."""
import hashlib
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BootstrapFailures(unittest.TestCase):
    def setUp(self):
        self.owner = tempfile.TemporaryDirectory(prefix="bootstrap-test-")
        self.root = Path(self.owner.name)
        self.mount = self.root / "mount"
        self.temp = self.root / "temporary"
        self.bin = self.root / "bin"
        for directory in (self.mount, self.temp, self.bin):
            directory.mkdir()
        self.sentinel = self.temp / "unrelated"
        self.sentinel.write_text("keep")
        shutil.copyfile(ROOT / "scripts/Start-MaesterContainerJob.sh", self.mount / "start.sh")
        self.archive = self.mount / "powershell-7.6.6-linux-x64.tar.gz"
        self.archive.write_bytes(b"intentionally invalid payload")
        self.env = dict(os.environ, TMPDIR=str(self.temp), PATH=f"{self.bin}:/usr/bin:/bin", TEST_ROOT=str(self.root))
        self.source_hash = self.hash_sources()

    def tearDown(self):
        self.assertEqual(self.hash_sources(), self.source_hash)
        self.assertEqual(list(self.temp.iterdir()), [self.sentinel])
        self.assertEqual(self.sentinel.read_text(), "keep")
        self.owner.cleanup()

    def hash_sources(self):
        return {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in self.mount.iterdir()}

    def tool(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)

    def execute(self, mode="nonacr", args=()):
        return subprocess.run(["/bin/sh", str(self.mount / "start.sh"), mode, *args], env=self.env, text=True, capture_output=True, timeout=15)

    def fake_extract(self, runtime_status=0, runner_status=0, wait=False):
        # This only injects faults; hosted CI separately executes vendor bytes.
        self.tool("sha256sum", "cat >/dev/null; exit 0")
        self.tool("tar", '''for last do :; done
cat > "$last/pwsh" <<'PWSH'
#!/bin/sh
if [ "$3" = '-Command' ]; then exit ''' + str(runtime_status) + '''; fi
printf invoked > "$TEST_ROOT/runner-invoked"
''' + ("sleep 30\n" if wait else "") + "exit " + str(runner_status) + "\nPWSH")

    def test_hash_mismatch_never_executes_runner(self):
        self.assertNotEqual(self.execute().returncode, 0)
        self.assertFalse((self.root / "runner-invoked").exists())

    def test_missing_archive(self):
        self.archive.unlink()
        self.source_hash = self.hash_sources()
        self.assertNotEqual(self.execute().returncode, 0)

    def test_truncated_archive(self):
        self.archive.write_bytes(b"\x1f\x8b")
        self.source_hash = self.hash_sources()
        self.assertNotEqual(self.execute().returncode, 0)

    def test_extraction_failure(self):
        self.tool("sha256sum", "cat >/dev/null; exit 0")
        self.tool("tar", "exit 42")
        self.assertEqual(self.execute().returncode, 42)
        self.assertFalse((self.root / "runner-invoked").exists())

    def test_runtime_failure_never_runs_assessment(self):
        self.fake_extract(runtime_status=19)
        self.assertEqual(self.execute().returncode, 19)
        self.assertFalse((self.root / "runner-invoked").exists())

    def test_wrong_architecture(self):
        self.tool("uname", "printf aarch64")
        self.assertNotEqual(self.execute().returncode, 0)
        self.assertFalse((self.root / "runner-invoked").exists())

    def test_runner_failure_is_not_success(self):
        self.fake_extract(runner_status=23)
        self.assertEqual(self.execute().returncode, 23)
        self.assertTrue((self.root / "runner-invoked").exists())

    def test_success_cleanup(self):
        self.fake_extract()
        self.assertEqual(self.execute(args=("-ValidateRuntimeOnly",)).returncode, 0)

    def test_rejects_arbitrary_arguments(self):
        self.assertEqual(self.execute(args=("-File", "other.ps1")).returncode, 2)

    def test_acr_never_falls_back(self):
        self.tool("pwsh", "exit 17")
        self.tool("tar", 'touch "$TEST_ROOT/extracted"; exit 0')
        self.assertEqual(self.execute(mode="acr").returncode, 17)
        self.assertFalse((self.root / "extracted").exists())

    def test_termination_cleans_owned_files(self):
        self.fake_extract(wait=True)
        process = subprocess.Popen(["/bin/sh", str(self.mount / "start.sh"), "nonacr"], env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            deadline = time.monotonic() + 10
            while not (self.root / "runner-invoked").exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertTrue((self.root / "runner-invoked").exists())
            process.send_signal(signal.SIGTERM)
            self.assertEqual(process.wait(timeout=10), 143)
        finally:
            # The fake runner uses sleep; terminate its test-only process group too.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass


if __name__ == "__main__":
    unittest.main(verbosity=2)
