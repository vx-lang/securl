#!/bin/sh
# Make the certificates of the TLS tests: a test certificate authority, and a server
# certificate for localhost and 127.0.0.1 that it signs. They are valid for 100 years. They are
# for tests only: their private keys are in the repository.
#
#   tests/tls/make-certs.sh OUT_DIR
#
# The key of the authority stays in a temporary folder, because the tests do not need it.
set -eu
out=$1
work=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/ca.key" -out "$out/ca.pem" \
  -days 36500 -subj "/CN=curl-vx test CA" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"
openssl req -newkey rsa:2048 -nodes -keyout "$out/server.key" -out "$work/server.csr" \
  -subj "/CN=localhost"
printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' > "$work/ext"
openssl x509 -req -in "$work/server.csr" -CA "$out/ca.pem" -CAkey "$work/ca.key" \
  -CAcreateserial -CAserial "$work/ca.srl" -out "$out/server.pem" -days 36500 -extfile "$work/ext"
