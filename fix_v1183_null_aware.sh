#!/usr/bin/env bash
# =============================================================================
# InstantGram - small cleanup: one lint note in test/v1180_test.dart
#   The analyzer suggested the short "?preview" form. Nothing changes in the app,
#   it only makes `dart analyze` print nothing at all.
# Run from the project root:   bash fix_v1183_null_aware.sh
# =============================================================================
set -euo pipefail

[ -f test/v1180_test.dart ] || { echo "ERROR: run this from the Flutter project root (test/v1180_test.dart not found)."; exit 1; }

python3 - test/v1180_test.dart <<'PYX'
import sys
p = sys.argv[1]
s = open(p).read()
old = "  if (preview != null) 'previewUrl': preview,"
new = "  'previewUrl': ?preview,"
if old in s:
    open(p, 'w').write(s.replace(old, new, 1))
    print("    test/v1180_test.dart: cleaned up")
elif new in s:
    print("    test/v1180_test.dart: already cleaned up")
else:
    print("    test/v1180_test.dart: nothing to change")
PYX

echo ""
echo "Done. Run: dart analyze"
exit 0
