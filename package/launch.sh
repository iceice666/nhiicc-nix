if [[ $# -ne 0 ]]; then
  echo 'Usage: nhiicc (no arguments); Ctrl+C stops and removes the temporary session.' >&2
  exit 2
fi
if [[ ! -t 0 || ! -t 1 ]]; then
  echo 'Run nhiicc in an interactive terminal so sudo and Ctrl+C work.' >&2
  exit 1
fi
if [[ $EUID -eq 0 ]]; then
  echo 'Run nix run as your normal desktop user, not as root.' >&2
  exit 1
fi
if [[ ! -d /run/systemd/system ]]; then
  echo 'This temporary launcher requires Linux with systemd.' >&2
  exit 1
fi
if [[ -S /run/pcscd/pcscd.comm ]] || pgrep -x pcscd >/dev/null; then
  echo 'An existing pcscd/socket was found. No service was stopped.' >&2
  echo 'Stop the existing reader service yourself only if appropriate, then retry.' >&2
  exit 1
fi
if [[ -n "$(ss -H -ltn 'sport = :7777')" ]]; then
  echo 'TCP port 7777 is already in use; no existing process was stopped.' >&2
  exit 1
fi

echo 'Resolving required NHI endpoint cloudicap.nhi.gov.tw...'
endpoint_text="$(timeout 10 "$endpoint_tool")" || {
  echo 'Endpoint resolution failed; no service was started.' >&2
  exit 1
}
mapfile -t endpoint_addresses <<< "$endpoint_text"
echo "NHI endpoint IP exception: ${endpoint_addresses[*]} (IP-level, not port-specific)"

# A fixed transient unit name prevents concurrent sessions from racing for USB.
unit=nhiicc-ephemeral-session
echo "Temporary service: $unit.service"
echo "Emergency stop: sudo systemctl stop $unit.service"
echo 'Ctrl+C stops this session. It also expires automatically after two hours.'

# systemd-run accepts "localhost" only as the entire property value; mixed
# lists must spell out its equivalent CIDRs (127/8 and ::1/128).
# sudo is deliberately the host wrapper, not a non-setuid Nix-store binary.
exec /run/wrappers/bin/sudo -- "$systemd_run" \
  --unit="$unit" --description='Temporary NHI card middleware' \
  --pty --wait --collect --send-sighup --service-type=exec \
  --property="RuntimeDirectory=$unit" --property=RuntimeDirectoryMode=0711 \
  --property=RuntimeMaxSec=2h --property=TimeoutStopSec=10s \
  --property=KillMode=control-group --property=UMask=0077 \
  --property=PrivateTmp=yes --property=ProtectHome=yes \
  --property=ProtectSystem=strict --property=NoNewPrivileges=yes \
  --property=ProtectKernelTunables=yes --property=ProtectKernelModules=yes \
  --property=ProtectControlGroups=yes --property=RestrictSUIDSGID=yes \
  --property='RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK' \
  --property=IPAddressDeny=any --property="IPAddressAllow=127.0.0.0/8 ::1/128 ${endpoint_addresses[*]}" \
  --property='TemporaryFileSystem=/usr/local/share:ro /run/pcscd /etc' \
  --property="BindPaths=/run/$unit:/usr/local/share/NHIICC" \
  "$supervisor" "/run/$unit" "$(id -u)" "$(id -g)" "${endpoint_addresses[@]}"
