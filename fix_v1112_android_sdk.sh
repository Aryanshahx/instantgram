#!/usr/bin/env bash
# Fixes the APK build error from v1.11.0:
#   ":agora_rtc_engine is currently compiled against android-31"
# The call plugin compiles against whatever android/build.gradle(.kts) says (default 31).
# This tells it to use Android 36. Run from the project root:  bash fix_v1112_android_sdk.sh
set -euo pipefail
python3 - <<'PYX'
import os, re, sys
kts = "android/build.gradle.kts"
grv = "android/build.gradle"
if os.path.exists(kts):
    path, snippet = kts, (
        "// InstantGram: the call plugin (agora) reads this to compile against a modern Android API.\n"
        "if (!extra.has(\"compileSdkVersion\")) {\n    extra[\"compileSdkVersion\"] = 36\n}\n\n")
elif os.path.exists(grv):
    path, snippet = grv, (
        "// InstantGram: the call plugin (agora) reads this to compile against a modern Android API.\n"
        "if (!ext.has('compileSdkVersion')) {\n    ext.compileSdkVersion = 36\n}\n\n")
else:
    sys.exit("ERROR: android/build.gradle(.kts) not found. Run this from the Flutter project root.")
s = open(path, encoding="utf-8").read()
if "InstantGram: the call plugin" in s:
    print("    %s: already fixed" % path)
    sys.exit(0)
lines = s.split("\n")
has_plugins = any(re.match(r"^plugins\s*\{", l) for l in lines)
idx = None
if not has_plugins:
    for i, l in enumerate(lines):
        if re.match(r"^(allprojects|subprojects|rootProject|val |tasks\.|gradle\.)", l):
            idx = i
            break
if idx is None:
    out = s.rstrip("\n") + "\n\n" + snippet
else:
    out = "\n".join(lines[:idx]) + ("\n" if idx else "") + snippet + "\n".join(lines[idx:])
open(path, "w", encoding="utf-8").write(out)
print("    %s: compileSdkVersion 36 set for plugins" % path)
PYX
echo "Done. Now:  git add -A && git commit -m \"v1.11.2: android sdk for calls\" && git push"
