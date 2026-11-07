"""Exercise run-dev.sh through a PTY with isolated build/app fixtures."""
import errno
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


class TerminalSession:
    def __init__(self, root, env):
        self.output = ""
        self.waited = False
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(root)
            os.execve("/bin/zsh", ["zsh", "./run-dev.sh"], env)

    def send(self, key):
        os.write(self.fd, key.encode())

    def expect(self, text, count=1):
        deadline = time.monotonic() + 8
        while self.output.count(text) < count:
            if time.monotonic() > deadline:
                raise AssertionError(f"Missing {text!r}: {self.output}")
            if select.select([self.fd], [], [], 0.1)[0]:
                try:
                    chunk = os.read(self.fd, 65536)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    chunk = b""
                if not chunk:
                    raise AssertionError(f"Terminal closed before {text!r}: {self.output}")
                self.output += chunk.decode(errors="replace")

    def finish(self, key="q"):
        self.send(key)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.waited = True
                return os.waitstatus_to_exitcode(status)
            time.sleep(0.02)
        raise AssertionError("Runner did not exit")

    def close(self):
        if not self.waited:
            try:
                os.killpg(self.pid, signal.SIGTERM)
                os.waitpid(self.pid, 0)
            except ProcessLookupError:
                pass
        os.close(self.fd)


class RunDevChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mio-run-dev-")
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)
        shutil.copy2(Path(__file__).resolve().parents[1] / "run-dev.sh", self.root / "run-dev.sh")
        mock_bin = self.root / "bin"
        mock_bin.mkdir()
        self.env = dict(os.environ, TEST_ROOT=str(self.root), PATH=str(mock_bin) + ":/usr/bin:/bin:/usr/sbin:/sbin")
        app_code = r"""import os, signal
from pathlib import Path
root = Path(os.environ['TEST_ROOT'])
def log(text):
    with (root / 'events').open('a') as out: out.write(text + '\n')
def stop(*args):
    log('STOP')
    raise SystemExit(0)
signal.signal(signal.SIGTERM, stop)
log('START')
print('MOCK_APP_STARTED', flush=True)
if (root / 'exit-app').exists(): raise SystemExit(7)
while True: signal.pause()
"""
        build_code = """import os, sys
from pathlib import Path
root = Path(os.environ['TEST_ROOT'])
if (root / 'fail-build').exists():
    print('mock build failure')
    raise SystemExit(1)
derived = Path(sys.argv[sys.argv.index('-derivedDataPath') + 1])
exe = derived / 'Build/Products/Debug/Mio.app/Contents/MacOS/Mio'
exe.parent.mkdir(parents=True, exist_ok=True)
exe.write_text(APP_SOURCE)
exe.chmod(0o755)
""".replace("APP_SOURCE", repr("#!" + sys.executable + "\n" + app_code))
        for name, code in [("xcodebuild", build_code), ("codesign", "raise SystemExit(0)\n")]:
            path = mock_bin / name
            path.write_text("#!" + sys.executable + "\n" + code)
            path.chmod(0o755)

    def start(self):
        session = TerminalSession(self.root, self.env)
        self.addCleanup(session.close)
        session.expect("MOCK_APP_STARTED")
        return session

    def events(self):
        return (self.root / "events").read_text().splitlines()

    def test_restart_and_quit(self):
        session = self.start()
        session.send("r")
        session.expect("MOCK_APP_STARTED", count=2)
        self.assertEqual(session.finish(), 0)
        self.assertEqual(self.events(), ["START", "STOP", "START", "STOP"])

    def test_ctrl_c_stops_child(self):
        session = self.start()
        self.assertEqual(session.finish("\x03"), 130)
        self.assertEqual(self.events().count("START"), 1)
        # Ctrl+C may terminate the process directly before the EXIT trap sends TERM.
        self.assertLessEqual(self.events().count("STOP"), 1)

    def test_retry_after_failed_restart(self):
        session = self.start()
        failure = self.root / "fail-build"
        failure.touch()
        session.send("r")
        session.expect("按 r 重试构建")
        self.assertEqual(self.events(), ["START", "STOP"])
        failure.unlink()
        session.send("r")
        session.expect("MOCK_APP_STARTED", count=2)
        self.assertEqual(session.finish(), 0)
        self.assertEqual(self.events(), ["START", "STOP", "START", "STOP"])

    def test_restart_after_app_exits(self):
        exit_flag = self.root / "exit-app"
        exit_flag.touch()
        session = self.start()
        session.expect("Mio 已退出（7）")
        exit_flag.unlink()
        session.send("r")
        session.expect("MOCK_APP_STARTED", count=2)
        self.assertEqual(session.finish(), 0)
        self.assertEqual(self.events(), ["START", "START", "STOP"])

    def test_build_only_does_not_launch(self):
        result = subprocess.run(["/bin/zsh", "./run-dev.sh", "--build-only"], cwd=self.root, env=self.env, capture_output=True, timeout=8)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertFalse((self.root / "events").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
