if [[ $# -ne 1 || "$1" != /* ]]; then
  echo 'Usage: nhiicc-init-certificate /absolute/path/to/new-cert-directory' >&2
  exit 2
fi

out="$1"
if [[ -e "$out" ]]; then
  for file in NHIRootCA.crt NHIServerCert.crt NHIServerCert.key; do
    if [[ ! -s "$out/$file" ]]; then
      echo "Incomplete certificate directory: $out (move it aside before regenerating)" >&2
      exit 1
    fi
  done
  openssl verify -CAfile "$out/NHIRootCA.crt" -purpose sslserver \
    -verify_hostname localhost "$out/NHIServerCert.crt"
  cert_public="$(openssl x509 -in "$out/NHIServerCert.crt" -pubkey -noout)"
  key_public="$(openssl pkey -in "$out/NHIServerCert.key" -pubout)"
  if [[ "$cert_public" != "$key_public" ]]; then
    echo "Server key does not match certificate: $out" >&2
    exit 1
  fi
  chmod 700 "$out"
  chmod 600 "$out/NHIServerCert.key"
  exit 0
fi

umask 077
mkdir -p -- "$(dirname -- "$out")"
tmp="$(mktemp -d "$(dirname -- "$out")/.nhiicc-cert.XXXXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
  -keyout "$tmp/ca.key" -out "$tmp/NHIRootCA.crt" \
  -subj '/CN=NHI local middleware CA' \
  -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign'
openssl req -new -newkey rsa:3072 -nodes -sha256 \
  -keyout "$tmp/NHIServerCert.key" -out "$tmp/server.csr" \
  -subj '/CN=localhost'
printf '%s\n' \
  'basicConstraints=critical,CA:FALSE' \
  'keyUsage=critical,digitalSignature,keyEncipherment' \
  'extendedKeyUsage=serverAuth' \
  'subjectAltName=DNS:localhost,DNS:iccert.nhi.gov.tw,IP:127.0.0.1,IP:::1' \
  > "$tmp/extensions.cnf"
openssl x509 -req -in "$tmp/server.csr" -sha256 -days 365 \
  -CA "$tmp/NHIRootCA.crt" -CAkey "$tmp/ca.key" -CAcreateserial \
  -extfile "$tmp/extensions.cnf" -out "$tmp/NHIServerCert.crt"

# Do not retain a CA signing key or use the vendor's distributed private keys.
rm -- "$tmp/ca.key" "$tmp/server.csr" "$tmp/extensions.cnf" "$tmp/NHIRootCA.srl"
chmod 644 "$tmp/NHIRootCA.crt" "$tmp/NHIServerCert.crt"
chmod 600 "$tmp/NHIServerCert.key"
mv -T -- "$tmp" "$out"
