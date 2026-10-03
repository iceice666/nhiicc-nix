"""Resolve only the vendor's required allow-list endpoint; fail closed."""
import ipaddress
import socket
import sys

HOST = "cloudicap.nhi.gov.tw"


def validated_addresses(records):
    addresses = set()
    for record in records:
        address = ipaddress.IPv4Address(record[4][0])
        if not address.is_global or address.is_multicast:
            raise ValueError(f"Refusing non-public endpoint address: {address}")
        addresses.add(str(address))
    if not addresses or len(addresses) > 16:
        raise ValueError("Expected 1–16 public IPv4 addresses")
    return sorted(addresses)


if __name__ == "__main__":
    try:
        for address in validated_addresses(socket.getaddrinfo(HOST, 443, socket.AF_INET, socket.SOCK_STREAM)):
            print(address)
    except (OSError, ValueError) as error:
        print(f"Cannot resolve {HOST}: {error}", file=sys.stderr)
        raise SystemExit(1) from error
