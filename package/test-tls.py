"""Real loopback TLS server: verification must not wait for application EOF."""
import importlib.util
import os
from pathlib import Path
import socket
import ssl
import subprocess
import threading
import time

spec = importlib.util.spec_from_file_location("check_tls", os.environ["TLS_SOURCE"])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
root = Path(os.environ["TMPDIR"])
subprocess.run(["nhiicc-init-certificate", str(root / "cert")], check=True,
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
subprocess.run(["nhiicc-init-certificate", str(root / "wrong")], check=True,
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
server_context.load_cert_chain(root / "cert/NHIServerCert.crt", root / "cert/NHIServerCert.key")

for valid in (True, False):
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        listener.settimeout(5)
        release = threading.Event()
        errors = []

        def serve():
            try:
                with listener.accept()[0] as raw:
                    raw.settimeout(3)
                    try:
                        with server_context.wrap_socket(raw, server_side=True):
                            # Mimic middleware that never sends application EOF.
                            release.wait(5)
                    except ssl.SSLError:
                        if valid:
                            raise
            except Exception as error:
                errors.append(error)

        thread = threading.Thread(target=serve)
        thread.start()
        started = time.monotonic()
        try:
            cafile = root / ("cert" if valid else "wrong") / "NHIRootCA.crt"
            try:
                module.check_tls(str(cafile), listener.getsockname()[1])
            except ssl.SSLCertVerificationError:
                assert not valid
            else:
                assert valid, "Accepted an untrusted certificate"
            assert time.monotonic() - started < 2, "Waited for application EOF"
        finally:
            release.set()
            thread.join(timeout=5)
        assert not thread.is_alive()
        assert not errors, errors
        print("PASS: trusted handshake without EOF" if valid else "PASS: untrusted CA rejected")
