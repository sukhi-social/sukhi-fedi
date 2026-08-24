#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# One job before handing over to DeployEx: make sure the distribution
# certificates exist.
#
# DeployEx's own release boots Erlang distribution over mutual TLS
# unconditionally — its rel/env.sh writes /tmp/inet_tls.conf and passes
# `-proto_dist inet_tls`, whether or not any certificate is there. With
# none, the node cannot start distribution at all and DeployEx never
# comes up. Upstream's installers generate the pair from cloud-init; we
# generate it here, on first boot.
#
# Nothing outside this container ever sees these files. Both ends of the
# only connection they protect — DeployEx and the release it supervises —
# live in here, and the app joins by reading the same /tmp/inet_tls.conf
# (see combined/rel/env.sh.eex). So a fresh pair per volume is fine.
set -eu

CERT_DIR="${DEPLOYEX_OTP_TLS_CERT_PATH:-/var/lib/deployex/certs}"

if [ ! -f "$CERT_DIR/deployex.crt" ]; then
  echo "[deployex-entrypoint] generating distribution certificates in $CERT_DIR"
  mkdir -p "$CERT_DIR"
  cd "$CERT_DIR"
  umask 077

  # Same shape as upstream's tls-distribution-certs script: a secp256r1
  # root, one leaf that is both the server and the client half.
  openssl ecparam -name prime256v1 -genkey -noout -out ca.key
  openssl req -x509 -new -key ca.key -sha256 -days 3650 \
    -subj "/CN=sukhi-deployex-ca" -out ca.crt

  cat > leaf.cnf <<'CNF'
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = DNS:deployex, DNS:localhost
CNF

  openssl ecparam -name prime256v1 -genkey -noout -out deployex.key
  openssl req -new -key deployex.key -subj "/CN=deployex" -out deployex.csr
  openssl x509 -req -in deployex.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -days 3650 -sha256 -extfile leaf.cnf -out deployex.crt
  rm -f deployex.csr leaf.cnf

  chmod 644 ca.crt deployex.crt
  cd - >/dev/null
fi

exec /opt/deployex/bin/deployex start
