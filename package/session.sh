if [[ $# -lt 4 || $EUID -ne 0 || "$1" != /run/nhiicc-ephemeral-* || ! "$2" =~ ^[0-9]+$ || ! "$3" =~ ^[0-9]+$ || "$2" == 0 ]]; then
  echo 'Internal helper: invoke nhiicc from your desktop session.' >&2
  exit 2
fi
state="$1"
uid="$2"
gid="$3"
shift 3

if [[ "$(findmnt --noheadings --mountpoint /etc --output FSTYPE)" != tmpfs ]]; then
  echo 'Refusing to prepare hosts outside the private /etc tmpfs.' >&2
  exit 1
fi
# /etc is a private tmpfs created by systemd, never the host /etc.
# Resolve once before sudo; avoid granting the middleware any DNS egress.
printf '127.0.0.1 localhost\n::1 localhost\n' > /etc/hosts
for address in "$@"; do
  [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 2
  printf '%s cloudicap.nhi.gov.tw\n' "$address" >> /etc/hosts
done
printf 'hosts: files\n' > /etc/nsswitch.conf
chmod 644 /etc/hosts /etc/nsswitch.conf

# Invoked by the EXIT trap, including after signal-triggered exits.
# shellcheck disable=SC2329
cleanup() {
  trap - EXIT INT TERM HUP
  # Only signal still-running children of this supervisor; systemd also owns
  # the entire cgroup and removes RuntimeDirectory after the last process exits.
  local child
  for child in $(jobs -pr); do
    kill -TERM "$child" 2>/dev/null || true
  done
  sleep 0.2
  for child in $(jobs -pr); do
    kill -KILL "$child" 2>/dev/null || true
  done
  wait || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if pgrep -x pcscd >/dev/null || [[ -n "$(ss -H -ltn 'sport = :7777')" ]]; then
  echo 'pcscd or port 7777 became busy; leaving existing processes alone.' >&2
  exit 1
fi

echo 'Generating temporary localhost certificate...'
if ! "$certificate_tool" "$state/cert" >"$state/certificate.log" 2>&1; then
  cat "$state/certificate.log" >&2
  exit 1
fi
chown -R "$uid:$gid" "$state/cert"
mkdir -m 700 "$state/work"
chown "$uid:$gid" "$state/work"
ln -s "$assets/html" "$state/html"
ln -s "$assets/web" "$state/web"
# Only the public certificate is exposed for browser import.
install -m 644 "$state/cert/NHIRootCA.crt" "$state/NHIRootCA.crt"
mkdir "$state/reader.conf.d"

# Keep error-level foreground logs visible; never enable APDU/card-data logging.
"$pcscd" --foreground --error --config "$state/reader.conf.d" &
reader_pid=$!

report_exit() {
  local name="$1" pid="$2" status=0
  wait "$pid" || status=$?
  echo "$name exited during startup (status $status)." >&2
}

for ((attempt=0; attempt<100; attempt++)); do
  if ! kill -0 "$reader_pid" 2>/dev/null; then
    report_exit pcscd "$reader_pid"
    exit 1
  fi
  [[ -S /run/pcscd/pcscd.comm ]] && break
  sleep 0.1
done
if [[ ! -S /run/pcscd/pcscd.comm ]]; then
  echo 'Temporary pcscd did not create its socket within 10 seconds.' >&2
  exit 1
fi

# pcscd needs USB access; the proprietary middleware must not run as root.
cd "$state/work"
setpriv --reuid="$uid" --regid="$gid" --clear-groups \
  --bounding-set=-all --inh-caps=-all --ambient-caps=-all \
  env -i PATH="$vendor_path" HOME="$state/work" \
  PCSCLITE_CSOCK_NAME=/run/pcscd/pcscd.comm "$vendor" &
vendor_pid=$!
ready=false
echo 'Waiting for verified TLS handshake at 127.0.0.1:7777 (up to about 15 seconds)...'
for ((attempt=0; attempt<10; attempt++)); do
  if ! kill -0 "$reader_pid" 2>/dev/null; then
    report_exit pcscd "$reader_pid"
    exit 1
  fi
  if ! kill -0 "$vendor_pid" 2>/dev/null; then
    report_exit mLNHIICC "$vendor_pid"
    exit 1
  fi
  if "$tls_tool" "$state/NHIRootCA.crt" >"$state/tls-check.log" 2>&1; then
    ready=true
    break
  fi
  printf 'TLS not ready (%d/10): ' "$((attempt + 1))" >&2
  tail -n 1 "$state/tls-check.log" >&2
  sleep 0.2
done
if [[ "$ready" != true ]]; then
  echo 'TLS readiness check failed (this is not a card authentication test):' >&2
  cat "$state/tls-check.log" >&2
  exit 1
fi
printf '\n%s\n' \
  'NHI middleware TLS endpoint is ready: https://localhost:7777/' \
  "Public CA for manual browser import: $state/NHIRootCA.crt" \
  'Use a dedicated browser profile. No trust settings were changed.' \
  'Press Ctrl+C to stop and delete temporary session data.'

# Whichever process exits first ends the session; don't leave an orphan service.
set +e
wait -n "$reader_pid" "$vendor_pid"
status=$?
set -e
echo "A session process exited (status $status); stopping the session." >&2
exit 1
