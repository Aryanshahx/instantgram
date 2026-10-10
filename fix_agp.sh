#!/usr/bin/env bash
# Run from the project root (folder with pubspec.yaml).
# Downgrades AGP 9 -> 8.11.1 (Flutter's Gradle plugin isn't compatible with AGP 9 yet).
set -e
[ -f pubspec.yaml ] && [ -d android ] || { echo "Run from Flutter project root."; exit 1; }

S=android/settings.gradle.kts
W=android/gradle/wrapper/gradle-wrapper.properties
P=android/gradle.properties
A=android/app/build.gradle.kts

# 1) AGP + Kotlin versions
sed -i -E 's|(id\("com.android.application"\) version )"[^"]+"|\1"8.11.1"|' "$S"
sed -i -E 's|(id\("org.jetbrains.kotlin.android"\) version )"[^"]+"|\1"2.2.20"|' "$S"

# 2) Gradle 8.14
sed -i -E 's|gradle-[0-9.]+-(all\|bin)\.zip|gradle-8.14-all.zip|' "$W"

# 3) Remove AGP 9-only flags
sed -i -E '/android\.newDsl|android\.builtInKotlin|newDsl flag|builtInKotlin flag/d' "$P"

# 4) AGP 8 needs the Kotlin plugin applied in the app module
if ! grep -q 'org.jetbrains.kotlin.android' "$A"; then
  sed -i 's|id("com.android.application")|id("com.android.application")\n    id("org.jetbrains.kotlin.android")|' "$A"
fi

echo "Done. Review with: git diff"
echo "Then: git add -A android && git commit -m 'Downgrade AGP to 8.11.1' && git push"
