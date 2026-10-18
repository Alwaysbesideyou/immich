#!/usr/bin/env bash
# Replace MetadataService.getDates() with the maintainer-supplied timezone block.
#
# Why a block splice instead of `git apply`:
#   The upstream function body is expected to drift as Immich evolves. A fuzzy
#   patch either fails loudly with an unusable diff or, worse, applies with
#   offset and produces a subtly different function. This script replaces the
#   whole method between explicit anchors and fails loudly when those anchors
#   move, which is exactly the "needs a human" signal we want.
#
# Anchors and the replacement block live in .github/tz-block/.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
block_dir="${repo_root}/.github/tz-block"
target="${repo_root}/server/src/services/metadata.service.ts"

block_file="${block_dir}/getDates.block.ts"
anchors_file="${block_dir}/getDates.anchors.json"

if [ ! -f "${block_file}" ]; then
  echo "missing block file: ${block_file}" >&2
  exit 1
fi
if [ ! -f "${target}" ]; then
  echo "missing target file: ${target}" >&2
  exit 1
fi

# Read anchors without requiring jq for two plain string values. The anchors
# file is maintained by hand, so keep the parsing strict and single-purpose.
start_anchor="$(grep -o '"startAnchor": *"[^"]*"' "${anchors_file}" | cut -d'"' -f4)"
end_anchor="$(grep -o '"endAnchor": *"[^"]*"' "${anchors_file}" | cut -d'"' -f4)"

if [ -z "${start_anchor}" ] || [ -z "${end_anchor}" ]; then
  echo "could not parse anchors from ${anchors_file}" >&2
  exit 1
fi

python3 - "${target}" "${block_file}" "${start_anchor}" "${end_anchor}" <<'PY'
import re
import sys

target_path, block_path, start_anchor, end_anchor = sys.argv[1:5]

# The anchors file stores JSON-escaped strings; recover the literal text.
start_anchor = start_anchor.encode().decode("unicode_escape")
end_anchor = end_anchor.encode().decode("unicode_escape")

DECL = "  private getDates("
HAS_GEO = "  private hasGeo("
# Capture only the method name, so the check stays readable.
METHOD_DECL = re.compile(r"\n  (?:private|protected) (?:async )?(\w+)\(")

with open(target_path, encoding="utf-8") as fh:
    src = fh.read()
with open(block_path, encoding="utf-8") as fh:
    block = fh.read()

start_idx = src.find(start_anchor)
if start_idx == -1:
    sys.exit("anchor not found: getDates() declaration. Upstream renamed or moved it.")
end_idx = src.find(end_anchor, start_idx)
if end_idx == -1:
    sys.exit("anchor not found: hasGeo() boundary. getDates() no longer ends where expected.")

# The region between the anchors must contain exactly one method declaration,
# and it must be getDates. If upstream inserted or removed a method in that
# span, splicing would silently compress or drop code.
region_methods = METHOD_DECL.findall(src[start_idx:end_idx])
if region_methods != ["getDates"]:
    sys.exit(
        "region between anchors declares %s; expected exactly ['getDates']"
        % (region_methods or "nothing")
    )

# start_anchor is "\n  private getDates(" and end_anchor is
# "\n\n  private hasGeo(". Both are boundary markers whose identifying text must
# survive the splice: only the method body strictly between them is replaced.
# The replacement block ends with the blank-line separator, so the tail starts
# at the hasGeo() declaration itself instead of at the separator, keeping
# exactly one blank line between the two methods.
block_start = start_idx + len(start_anchor) - len(DECL)
head = src[:block_start]

# Skip the separator the end anchor carries; the block supplies its own.
tail_offset = end_idx + len(end_anchor) - len(HAS_GEO)
tail = src[tail_offset:]

if not block.startswith(DECL):
    sys.exit("block file does not start at the getDates() declaration")
if not block.endswith("  }\n\n"):
    sys.exit("block file does not end with the expected boundary")

patched = head + block + tail

# Nothing outside the replaced region may change, whitespace included.
if patched == src:
    sys.exit("splice produced no change; the block is stale relative to upstream")

if "\n\n\n" in patched and "\n\n\n" not in src:
    sys.exit("splice introduced a blank-line run; separator handling is wrong")

if "UTC${dateTimeOriginal.toFormat('ZZ')}" not in patched:
    sys.exit("splice did not produce the expected timezone expression")

if "exifTags.zone ?? null" in patched:
    sys.exit("upstream timezone logic still present; splice was incomplete")

# Structural guards: the surrounding class must be syntactically intact and the
# method inventory must be unchanged apart from the patched body.
for required in (DECL, HAS_GEO, "  private getHeifOrientation(", "export class MetadataService"):
    if required not in patched:
        sys.exit("splice destroyed required code: %s" % required)

if patched.count("  private ") != src.count("  private "):
    sys.exit("method count changed after splice; the boundary is wrong")

before = set(METHOD_DECL.findall(src))
after = set(METHOD_DECL.findall(patched))
if before != after:
    sys.exit(
        "method inventory changed: added=%s removed=%s"
        % (sorted(after - before) or "-", sorted(before - after) or "-")
    )

with open(target_path, "w", encoding="utf-8") as fh:
    fh.write(patched)

print("Applied timezone block to %s (%d bytes -> %d bytes)" % (target_path, len(src), len(patched)))
PY
