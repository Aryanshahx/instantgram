#!/usr/bin/env bash
# =============================================================================
# InstantGram - fixes the Android build: "cannot find symbol FilePickerPlugin"
#
#   file_picker 11.x stopped applying the Kotlin plugin to its own Android module when
#   the project uses Android Gradle Plugin 9 (it expects Kotlin to be built in). Our
#   project has built-in Kotlin off, so the plugin's Kotlin code was never compiled and
#   the Java registrar could not find the class.
#
#   The fix: pin file_picker to 10.3.10, the version that still applies the Kotlin
#   plugin itself, and use that version's Dart call.
#
# Run from the project root:   bash fix_v1183_file_picker.sh
# Then:                        flutter clean && flutter pub get
# =============================================================================
set -euo pipefail

[ -f pubspec.yaml ] || { echo "ERROR: run this from the Flutter project root (pubspec.yaml not found)."; exit 1; }

echo "==> Pinning file_picker to 10.3.10..."
python3 - pubspec.yaml lib/services/device_audio.dart <<'PYX'
import re, sys

# ---- pubspec.yaml -----------------------------------------------------------
p = sys.argv[1]
s = open(p).read()
line = "  file_picker: 10.3.10\n"
if re.search(r"^[ \t]+file_picker:", s, re.M):
    n = re.sub(r"^[ \t]+file_picker:.*$", line.rstrip("\n"), s, flags=re.M)
    if n != s:
        open(p, "w").write(n)
        print("    pubspec.yaml: file_picker pinned to 10.3.10")
    else:
        print("    pubspec.yaml: already pinned")
else:
    m = re.search(r"^dependencies:[ \t]*\r?\n", s, re.M)
    if not m:
        sys.exit("ERROR: no dependencies: section in pubspec.yaml")
    s = s[:m.end()] + line + s[m.end():]
    open(p, "w").write(s)
    print("    pubspec.yaml: file_picker added")

# ---- the one place that calls it -------------------------------------------
q = sys.argv[2]
try:
    d = open(q).read()
except FileNotFoundError:
    print("    WARNING: %s not found (nothing to change there)" % q)
else:
    if "FilePicker.platform.pickFiles(" in d:
        print("    device_audio.dart: already using the 10.x call")
    elif "FilePicker.pickFiles(" in d:
        d = d.replace("FilePicker.pickFiles(", "FilePicker.platform.pickFiles(", 1)
        open(q, "w").write(d)
        print("    device_audio.dart: switched to FilePicker.platform.pickFiles")
    else:
        print("    device_audio.dart: no file_picker call found")
PYX

echo ""
echo "Done. Now run:"
echo "  flutter clean && flutter pub get && dart analyze && flutter test"
echo ""
echo "Then commit and push to start a new APK build:"
echo "  git add -A && git commit -m \"fix: file_picker 10.3.10 so the Android build compiles\" && git push"
exit 0
