{
  runCommand,
  openssl,
  certificateHelper,
}:

runCommand "nhiicc-certificate-tests"
  {
    nativeBuildInputs = [
      openssl
      certificateHelper
    ];
  }
  ''
    set -euo pipefail
    cert="$TMPDIR/cert"
    nhiicc-init-certificate "$cert"
    test "$(stat -c %a "$cert")" = 700
    test "$(stat -c %a "$cert/NHIServerCert.key")" = 600
    test "$(find "$cert" -type f | wc -l)" = 3
    test ! -e "$cert/ca.key"
    for name in localhost iccert.nhi.gov.tw; do
      openssl verify -CAfile "$cert/NHIRootCA.crt" -purpose sslserver \
        -verify_hostname "$name" "$cert/NHIServerCert.crt"
    done
    for ip in 127.0.0.1 ::1; do
      openssl verify -CAfile "$cert/NHIRootCA.crt" \
        -verify_ip "$ip" "$cert/NHIServerCert.crt"
    done
    sha256sum "$cert"/* > before
    nhiicc-init-certificate "$cert"
    sha256sum "$cert"/* > after
    cmp before after

    if nhiicc-init-certificate relative/path; then
      echo 'Accepted a relative path' >&2
      exit 1
    fi
    cp -r "$cert" "$TMPDIR/broken"
    rm "$TMPDIR/broken/NHIServerCert.crt"
    if nhiicc-init-certificate "$TMPDIR/broken"; then
      echo 'Accepted incomplete state' >&2
      exit 1
    fi
    openssl genpkey -algorithm RSA -out "$cert/NHIServerCert.key"
    if nhiicc-init-certificate "$cert"; then
      echo 'Accepted a mismatched private key' >&2
      exit 1
    fi
    touch "$out"
  ''
