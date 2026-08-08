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

# Two validly signed manifests with consecutive serials, for the
# rollback-protection tests. Bodies must end with a newline; the signature
# covers every byte of the body file.
make_manifest() {
  out="$1"; serial="$2"
  {
    printf 'mm-manifest 1\n'
    printf 'serial %s\n' "$serial"
    printf 'plugin aaaaaaaaaaaaaaaaaaaaaaaa demo_plugin.xml\n'
    printf 'file demo_plugin.xml %s 11\n' \
      "$(printf 'demo-xml-v1' | shasum -a 256 | cut -d' ' -f1)"
    printf 'file demo_module.lua %s 11\n' \
      "$(printf 'demo-lua-v1' | shasum -a 256 | cut -d' ' -f1)"
  } > "$out.body"
  sig=$(openssl dgst -sha256 -sign test_key.pem "$out.body" | openssl base64 -A)
  cat "$out.body" > "$out"
  printf 'signature %s\n' "$sig" >> "$out"
  rm "$out.body"
}
make_manifest manifest_a.txt 2026010100
make_manifest manifest_b.txt 2026010101

echo "fixtures written"
