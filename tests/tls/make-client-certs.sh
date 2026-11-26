#!/bin/sh
# Make the client certificates of the TLS tests: a certificate authority for clients, and a
# client certificate that it signs, in the forms that `--cert`, `--key` and `--pass` read. They
# are valid for 100 years. They are for tests only: their private keys are in the repository.
#
#   tests/tls/make-client-certs.sh OUT_DIR
#
# It writes client-ca.pem, which the test server trusts for clients, and:
#   client.pem, client.key       the certificate and its key, in PEM
#   client-both.pem              both in one file
#   client-enc.key               the key, encrypted with the password "secret"
#   client.der, client-key.der   the certificate and its key, in DER
# The key of the authority stays in a temporary folder, because the tests do not need it.
set -eu
out=$1
work=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/ca.key" -out "$out/client-ca.pem" \
  -days 36500 -subj "/CN=securl test client CA" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"
openssl req -newkey rsa:2048 -nodes -keyout "$out/client.key" -out "$work/client.csr" \
  -subj "/CN=securl test client"
printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=clientAuth\n' \
  > "$work/ext"
openssl x509 -req -in "$work/client.csr" -CA "$out/client-ca.pem" -CAkey "$work/ca.key" \
  -CAcreateserial -CAserial "$work/ca.srl" -out "$out/client.pem" -days 36500 -extfile "$work/ext"
cat "$out/client.pem" "$out/client.key" > "$out/client-both.pem"
openssl pkey -in "$out/client.key" -aes256 -passout pass:secret -out "$out/client-enc.key"
openssl x509 -in "$out/client.pem" -outform DER -out "$out/client.der"
openssl pkey -in "$out/client.key" -outform DER -out "$out/client-key.der"
rm -rf "$work"
