#!/usr/bin/env bash
# InstantGram - GitHub build: install the Android NDK with retries.
# The runner's NDK download sometimes arrives broken ("unknown archive"); this
# adds a step before the APK build that downloads it again until it is whole.
# Run from the project root:   bash fix_ndk_download.sh
set -euo pipefail
WF=.github/workflows/build-apk.yml
[ -f "$WF" ] || { echo "ERROR: $WF not found (run this from the project root)."; exit 1; }
python3 - "$WF" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
MARK = "# instantgram: ndk with retries"
if MARK in s:
    print("    the NDK step is already there")
    sys.exit(0)
lines = s.split("\n")
idx = next((i for i, l in enumerate(lines) if "flutter build apk" in l), None)
if idx is None:
    print("ERROR: no 'flutter build apk' line in the workflow"); sys.exit(1)
# the start of that step: the nearest line above that begins with "- "
start = next(i for i in range(idx, -1, -1) if re.match(r"\s*- ", lines[i]))
ind = re.match(r"(\s*)- ", lines[start]).group(1)
step = f"""{ind}- name: Install Android NDK (with retries)
{ind}  {MARK}
{ind}  run: |
{ind}    SDK="${{ANDROID_SDK_ROOT:-${{ANDROID_HOME:-/usr/local/lib/android/sdk}}}}"
{ind}    NDK=$(grep -rhoP --exclude-dir=test --exclude-dir=tests 'ndkVersion\\s*(:\\s*String)?\\s*=\\s*"\\K[0-9.]+' "$FLUTTER_ROOT/packages/flutter_tools/gradle" 2>/dev/null | head -1 || true)
{ind}    NDK="${{NDK:-28.2.13676358}}"
{ind}    echo "NDK $NDK"
{ind}    for i in 1 2 3 4 5; do
{ind}      if [ -f "$SDK/ndk/$NDK/source.properties" ]; then echo "NDK ready"; exit 0; fi
{ind}      rm -rf "$SDK/ndk/$NDK" "$SDK/.temp" "$SDK/.downloadIntermediates"
{ind}      yes | "$SDK/cmdline-tools/latest/bin/sdkmanager" --install "ndk;$NDK" > /tmp/ndk.log 2>&1 || tail -5 /tmp/ndk.log
{ind}      [ -f "$SDK/ndk/$NDK/source.properties" ] && {{ echo "NDK ready"; exit 0; }}
{ind}      echo "NDK download broken, try $i again in 15 s"; sleep 15
{ind}    done
{ind}    exit 1"""
lines[start:start] = step.split("\n")
open(p, "w").write("\n".join(lines))
print("    added the NDK step before the APK build")
PY
echo "Done. Commit and push; the build downloads the NDK again if it arrives broken."
