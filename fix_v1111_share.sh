#!/usr/bin/env bash
# Fixes the two share.dart errors (SharePlus / ShareParams not found) from v1.11.0.
# Run from the project root:   bash fix_v1111_share.sh
set -euo pipefail
F="lib/core/share.dart"
[ -f "$F" ] || { echo "ERROR: run this from the Flutter project root ($F not found)."; exit 1; }
python3 - "$F" <<'PYX'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
new = "  // ignore: deprecated_member_use\n  await Share.share(link);\n"
if "await Share.share(link);" in s:
    print("    share.dart: already fixed")
elif "SharePlus.instance.share(ShareParams(text: link));" in s:
    s = s.replace("  await SharePlus.instance.share(ShareParams(text: link));\n", new)
    open(p, "w", encoding="utf-8").write(s)
    print("    share.dart: fixed")
else:
    sys.exit("ERROR: unexpected content in share.dart")
PYX
echo "Done. Now:  dart analyze"
