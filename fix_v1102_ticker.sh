#!/usr/bin/env bash
# InstantGram v1.10.2 - silences the last analyzer note (TickerMode.of is deprecated only in
# newer Flutter versions; it still works). No behaviour change.
# Run from the project root:   bash fix_v1102_ticker.sh
set -euo pipefail
F=lib/widgets/inline_video.dart
[ -f "$F" ] || { echo "ERROR: $F not found. Run this from the project root."; exit 1; }
python3 - "$F" <<'PYX'
import sys
p = sys.argv[1]
s = open(p).read()
marker = "// ignore: deprecated_member_use"
old = "    _ticking = TickerMode.of("
if marker + "\n" + old in s:
    print("    already fixed")
elif old in s:
    s = s.replace(old, "    " + marker + "\n" + old, 1)
    open(p, "w").write(s)
    print("    fixed " + p)
else:
    sys.exit("ERROR: could not find the line to fix")
PYX
echo ""
echo "Done. Next:"
echo "  dart analyze"
echo '  git add -A && git commit -m "v1.10.2: analyzer cleanup" && git push'
