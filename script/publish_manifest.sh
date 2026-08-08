#!/bin/sh
# Regenerates and signs manifest.txt. Run from the repo root after
# committing plugin changes; commit the manifest it writes.
set -eu

KEY="${MM_UPDATER_KEY:-$HOME/.config/mm-scripts/updater_key.pem}"
[ -f "$KEY" ] || { echo "signing key not found: $KEY" >&2; exit 1; }

# id|xml|files (first file must be the xml itself; order is cosmetic)
PLUGINS='
f973af093e715dece34dc25f|MM_GMCP_Mapper_GMCP.xml|MM_GMCP_Mapper_GMCP.xml mm_mapper.lua
28149d6efdbd4bbf5340453f|path_locator.xml|path_locator.xml
9f3c2a8b1d4e5f6071829a4b|ooc_wiki.xml|ooc_wiki.xml ooc_wiki.lua mm_http.lua
a493febe0ad0d44295ab78eb|mm_pastebin.xml|mm_pastebin.xml mm_pastebin.lua mm_http.lua
a8e5cfb9554e916edd66f8d1|mm_updater.xml|mm_updater.xml mm_updater.lua mm_crypto.lua mm_http.lua
'

if echo "$PLUGINS" | grep -q FILL_; then
  echo "unfilled plugin IDs in PLUGINS" >&2
  exit 1
fi

# every distributed file must exist before anything is hashed or signed
echo "$PLUGINS" | while IFS='|' read -r id xml files; do
  [ -n "$id" ] || continue
  for f in $files; do
    [ -f "$f" ] || { echo "missing file: $f" >&2; exit 1; }
  done
done || exit 1

# serial: UTC date + 2-digit same-day counter, strictly increasing
today=$(date -u +%Y%m%d)
old=$(grep '^serial ' manifest.txt 2>/dev/null | cut -d' ' -f2 || true)
if [ -n "${old:-}" ] && [ "${old%??}" = "$today" ]; then
  nn=${old#"$today"}
  nn=${nn#0}                  # "07" -> "7": avoids octal in $(( ))
  nn=$(( nn + 1 ))
  [ "$nn" -le 99 ] || { echo "serial counter exhausted for today" >&2; exit 1; }
  serial=$(printf '%s%02d' "$today" "$nn")
else
  serial="${today}00"
fi

body=$(mktemp)
trap 'rm -f "$body"' EXIT
{
  printf 'mm-manifest 1\n'
  printf 'serial %s\n' "$serial"
  echo "$PLUGINS" | while IFS='|' read -r id xml files; do
    [ -n "$id" ] || continue
    printf 'plugin %s %s\n' "$id" "$xml"
    for f in $files; do
      printf 'file %s %s %s\n' "$f" \
        "$(shasum -a 256 "$f" | cut -d' ' -f1)" \
        "$(wc -c < "$f" | tr -d ' ')"
    done
  done
} > "$body"

sig=$(openssl dgst -sha256 -sign "$KEY" "$body" | openssl base64 -A)
cat "$body" > manifest.txt
printf 'signature %s\n' "$sig" >> manifest.txt

luajit script/verify_manifest.lua manifest.txt
