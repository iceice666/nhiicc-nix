"""Version-specific x86_64 fixes for supervision; never patch an unknown ELF."""
import hashlib
from pathlib import Path
import sys

path = Path(sys.argv[1])
data = bytearray(path.read_bytes())
expected_hash = "965ed289c36522b45b5d83ede0d9dff84009cd6ef585ba367d0e47f0b900fe6f"
if hashlib.sha256(data).hexdigest() != expected_hash:
    raise SystemExit("Unexpected mLNHIICC ELF; re-audit supervision patches for this release")

# In upstream 20240710.1, executable LOAD has file offset == virtual address.
# main+0x62 calls daemonize(), which forks, closes stderr, changes cwd, and
# installs signal handlers. systemd/supervisor must own those responsibilities.
# main+0x67 starts a hosts-file check/write, returning -2 when read-only.
# Jump to main+0x192, which starts normal service initialization. Temporary
# mode uses localhost and a private hosts file, never the host's mapping.
patches = [
    (0x494DF, bytes.fromhex("e8 e6 fc ff ff"), bytes.fromhex("90 90 90 90 90")),
    (0x494E4, bytes.fromhex("48 8d 35 c6 bb 1e 00"), bytes.fromhex("e9 26 01 00 00 90 90")),
]
for offset, before, after in patches:
    if data[offset:offset + len(before)] != before:
        raise SystemExit(f"Unexpected instruction bytes at {offset:#x}")
    assert len(before) == len(after)
    data[offset:offset + len(before)] = after
path.write_bytes(data)
