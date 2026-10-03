"""Check the handshake and certificate only, not HTTP or TLS shutdown."""
import socket
import ssl
import sys


def check_tls(cafile, port=7777, timeout=1.0):
    context = ssl.create_default_context(cafile=cafile)
    # Certificate verification and hostname checking remain enabled.
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as raw:
        with context.wrap_socket(raw, server_hostname="localhost"):
            pass


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: nhiicc-check-tls /path/to/public-ca.crt")
    try:
        check_tls(sys.argv[1])
    except (OSError, ValueError) as error:
        print(f"TLS handshake failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error
