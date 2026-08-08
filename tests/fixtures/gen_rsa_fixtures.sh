#!/bin/sh
# Regenerates the RSA test fixtures. The key generated here is a TEST KEY
# ONLY -- it is committed on purpose and must never sign a real manifest.
set -eu
cd "$(dirname "$0")"

if [ ! -f test_key.pem ]; then
  openssl genrsa -out test_key.pem 2048
fi
openssl rsa -in test_key.pem -noout -modulus \
  | sed 's/^Modulus=//' > test_modulus.txt

printf 'The quick brown fox jumps over the lazy dog\n' > rsa_msg.txt
openssl dgst -sha256 -sign test_key.pem -out rsa_sig_good.bin rsa_msg.txt

echo "fixtures written"
