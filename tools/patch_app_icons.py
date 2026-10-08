"""Adds the switchable launcher icons to android/app/src/main/AndroidManifest.xml.

The MAIN/LAUNCHER entry moves from MainActivity onto one <activity-alias> per icon
(only "Classic" is on at first). Safe to run again. Run from the project root.
"""
import re
import sys

MARK = "<!-- instantgram app icons -->"
IDS = ["classic", "midnight", "sunset", "ocean", "mono", "gold"]
P = sys.argv[1] if len(sys.argv) > 1 else "android/app/src/main/AndroidManifest.xml"


def main():
    try:
        s = open(P).read()
    except FileNotFoundError:
        print("    WARNING: AndroidManifest.xml not found; the App icon setting will say it is not available.")
        return
    if MARK in s:
        print("    AndroidManifest.xml: app icons already there")
        return
    act = re.search(r'<activity\b[^>]*android:name="([^"]*MainActivity)"[^>]*>.*?</activity>', s, re.S)
    if not act:
        print("    WARNING: MainActivity not found in AndroidManifest.xml; app icons skipped.")
        return
    block = act.group(0)
    launcher = None
    for f in re.finditer(r"[ \t]*<intent-filter\b[^>]*>.*?</intent-filter>[ \t]*\n?", block, re.S):
        t = f.group(0)
        if "android.intent.action.MAIN" in t and "android.intent.category.LAUNCHER" in t:
            launcher = f
            break
    if not launcher:
        print("    WARNING: no launcher entry on MainActivity; app icons skipped.")
        return
    app = re.search(r"<application\b[^>]*>", s, re.S)
    head = app.group(0) if app else ""

    def attr(name, default):
        m = re.search(r'android:%s="([^"]*)"' % name, head)
        return m.group(1) if m else default

    label = attr("label", "InstantGram")
    icon = attr("icon", "@mipmap/ic_launcher")
    round_icon = attr("roundIcon", "")
    target = act.group(1)
    new_block = block[: launcher.start()] + block[launcher.end():]
    aliases = ["", "        " + MARK]
    for i in IDS:
        name = "Icon" + i[0].upper() + i[1:]
        ic = icon if i == "classic" else "@mipmap/ig_icon_" + i
        rnd = ('\n            android:roundIcon="%s"' % round_icon) if (i == "classic" and round_icon) else ""
        aliases.append(
            '        <activity-alias\n'
            '            android:name="${applicationId}.%s"\n'
            '            android:targetActivity="%s"\n'
            '            android:enabled="%s"\n'
            '            android:exported="true"\n'
            '            android:label="%s"\n'
            '            android:icon="%s"%s>\n'
            '            <intent-filter>\n'
            '                <action android:name="android.intent.action.MAIN" />\n'
            '                <category android:name="android.intent.category.LAUNCHER" />\n'
            '            </intent-filter>\n'
            '        </activity-alias>' % (name, target, "true" if i == "classic" else "false", label, ic, rnd)
        )
    s = s[: act.start()] + new_block + "\n".join(aliases) + s[act.end():]
    open(P, "w").write(s)
    print("    AndroidManifest.xml: added %d app icons" % len(IDS))


main()
