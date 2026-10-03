import importlib.util
import os
import ipaddress
from pathlib import Path
import re

spec = importlib.util.spec_from_file_location("endpoint", os.environ["ENDPOINT_SOURCE"])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def records(*addresses):
    return [(2, 1, 6, "", (address, 443)) for address in addresses]


assert module.validated_addresses(records("8.8.8.8", "8.8.8.8")) == ["8.8.8.8"]
for addresses in ((), ("127.0.0.1",), ("192.168.1.1",), ("169.254.1.1",),
                  ("0.0.0.0",), ("224.0.0.1",), ("bad",), ("8.8.8.8", "10.0.0.1")):
    try:
        module.validated_addresses(records(*addresses))
    except ValueError:
        pass
    else:
        raise AssertionError(f"Accepted unsafe/empty DNS response: {addresses}")
print("PASS: deduplication and fail-closed public IPv4 validation (no DNS queries)")

# systemd-run's special aliases work only as a whole value. Mixed lists take
# the prefix parser path, so every word must be a literal IP/CIDR.
launcher = Path(os.environ["LAUNCH_SOURCE"]).read_text()
match = re.search(r'--property="IPAddressAllow=([^"]+)"', launcher)
assert match, "Missing explicit mixed address allow-list"
value = match[1].replace("${endpoint_addresses[*]}", "8.8.8.8 1.1.1.1")
networks = {str(ipaddress.ip_network(word, strict=True)) for word in value.split()}
assert networks == {"127.0.0.0/8", "::1/128", "8.8.8.8/32", "1.1.1.1/32"}
assert "--property=IPAddressDeny=any" in launcher
print("PASS: literal mixed-prefix syntax and unchanged loopback/endpoint scope")
