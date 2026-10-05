#!/usr/bin/env bash
# InstantGram v1.10.1 - tidies the analyzer notes of v1.10.0 (no behaviour change).
# Run from the project root:   bash fix_v1101_lints.sh
set -euo pipefail
[ -f lib/services/giphy.dart ] || { echo "ERROR: v1.10.0 is not installed."; exit 1; }
echo "==> Fixing the analyzer notes..."
python3 - . <<'PYX'
import sys
root = sys.argv[1] if len(sys.argv) > 1 else "."
def edit(path, pairs):
    p = root + "/" + path
    s = open(p).read()
    changed = False
    for old, new in pairs:
        if old in s:
            s = s.replace(old, new); changed = True
        elif new not in s:
            print("    WARNING: could not patch", path)
    if changed:
        open(p, "w").write(s)
        print("    fixed", path)
edit("lib/models/story.dart", [("if (StoryOverlay.fromMap(e) case final o?) o,", "?StoryOverlay.fromMap(e),")])
edit("lib/services/giphy.dart", [("if (GifItem.fromJson(e) case final g?) g,", "?GifItem.fromJson(e),")])
edit("lib/services/post_service.dart", [("if (musicId != null) 'musicId': musicId,", "'musicId': ?musicId,")])
edit("lib/services/user_service.dart", [
 ("if (username != null) 'authorUsername': username,", "'authorUsername': ?username,"),
 ("if (photo != null) 'authorPhotoUrl': photo,", "'authorPhotoUrl': ?photo,")])
PYX
echo ""
echo "Done. Next:"
echo "  dart analyze && flutter test"
echo '  git add -A && git commit -m "v1.10.1: analyzer cleanup" && git push'
