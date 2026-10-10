#!/usr/bin/env bash
# Run from the project root (the folder that contains pubspec.yaml)
set -e

FILE="android/build.gradle.kts"

if [ ! -f pubspec.yaml ] || [ ! -d android ]; then
  echo "Error: run this from the Flutter project root."
  exit 1
fi

[ -f "$FILE" ] && cp "$FILE" "$FILE.bak"

cat > "$FILE" <<'GRADLE'
plugins {
    id("com.android.application") apply false
    id("org.jetbrains.kotlin.android") apply false
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}
GRADLE

echo "Fixed $FILE (backup: $FILE.bak)"
echo "Now run:"
echo "  git add android/build.gradle.kts && git commit -m 'Fix root gradle script' && git push"
