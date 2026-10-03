"""Unprivileged supervisor contract tests with fake hardware/network commands."""
import os
from pathlib import Path
import signal
import shutil
import sys
import subprocess
import tempfile
import time

source = Path(os.environ["SESSION_SOURCE"]).read_text()
# Production validates root + /run; tests substitute only that guard and socket
# path. Real mount namespaces, sudo, systemd and USB remain integration tests.
source = source.replace("$EUID -ne 0", "1 -ne 1")
source = source.replace('"$1" != /run/nhiicc-ephemeral-*', '"$1" != /*')

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    commands = root / "bin"
    commands.mkdir()

    def command(name, text):
        path = commands / name
        path.write_text(f"#!{shutil.which('bash')}\nset -eu\n" + text)
        path.chmod(0o755)
        return str(path)

    command("findmnt", "echo tmpfs\n")
    command("pgrep", "exit 1\n")
    command("ss", "exit 0\n")
    command("chown", ":\n")
    command("setpriv", "while [[ $1 != env ]]; do shift; done\nexec \"$@\"\n")
    command("openssl", '[[ ${FAIL_TLS:-0} != 1 ]]\n')
    cert = command("cert", 'mkdir -p "$1"\nprintf fake > "$1/NHIRootCA.crt"\n')
    daemon = commands / "daemon.py"
    daemon.write_text(f"#!{sys.executable}\n" + """import os, socket, time, sys
assert os.path.isdir(sys.argv[sys.argv.index('--config') + 1])
s = socket.socket(socket.AF_UNIX)
s.bind(os.environ['SOCKET'])
open(os.environ['READER_PID'], 'w').write(str(os.getpid()))
while True: time.sleep(1)
""")
    daemon.chmod(0o755)
    vendor = command("vendor", 'echo $$ > "$HOME/vendor.pid"\n[[ ! -e "$HOME/fail-vendor" ]] || exit 42\nexec sleep 60\n')
    assets = root / "assets"
    (assets / "html").mkdir(parents=True)
    (assets / "web").mkdir()
    script = root / "session.sh"
    (root / "etc").mkdir()
    script.write_text("set -euo pipefail\n" + source.replace("/run/pcscd/pcscd.comm", str(root / "socket")).replace("/etc", str(root / "etc")))

    for mode in ("interrupt", "terminate", "hangup", "child-exit", "tls-failure", "vendor-failure"):
        state = root / mode
        state.mkdir()
        if mode == "vendor-failure":
            # Add the failure marker when the supervisor creates work/.
            # The mkdir shim preserves every other mkdir operation.
            command("mkdir", f'{shutil.which("mkdir")} "$@"\nif [[ "${{*: -1}}" == */work ]]; then touch "${{*: -1}}/fail-vendor"; fi\n')
        socket_path = root / "socket"
        socket_path.unlink(missing_ok=True)
        env = dict(os.environ, PATH=f"{commands}:{os.environ['PATH']}",
                   certificate_tool=cert, tls_tool=str(commands / "openssl"), pcscd=str(daemon), assets=str(assets),
                   vendor=vendor, vendor_path=f"{commands}:{os.environ['PATH']}",
                   SOCKET=str(socket_path), READER_PID=str(state / "reader.pid"),
                   FAIL_TLS="1" if mode in ("tls-failure", "vendor-failure") else "0")
        with (state / "output").open("w+") as output:
            process = subprocess.Popen(["bash", str(script), str(state), "1000", "1000", "8.8.8.8"],
                                       env=env, stdout=output, stderr=output,
                                       start_new_session=True)
            try:
                deadline = time.monotonic() + 15
                while not (state / "work/vendor.pid").exists():
                    assert process.poll() is None, (state / "output").read_text()
                    assert time.monotonic() < deadline
                    time.sleep(0.05)
                reader_pid = int((state / "reader.pid").read_text())
                vendor_pid = int((state / "work/vendor.pid").read_text())
                if mode == "interrupt":
                    process.send_signal(signal.SIGINT)
                elif mode == "terminate":
                    process.send_signal(signal.SIGTERM)
                elif mode == "hangup":
                    process.send_signal(signal.SIGHUP)
                elif mode == "child-exit":
                    os.kill(vendor_pid, signal.SIGTERM)
                assert process.wait(timeout=20) != 0
                if mode == "vendor-failure":
                    assert "mLNHIICC exited during startup (status 42)" in (state / "output").read_text(), (state / "output").read_text()
                for pid in (reader_pid, vendor_pid):
                    try:
                        os.kill(pid, 0)
                    except ProcessLookupError:
                        pass
                    else:
                        raise AssertionError(f"orphan process {pid}: {mode}")
                print(f"PASS: {mode}")
            finally:
                # Kill only this test's process group even if an assertion fails.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
