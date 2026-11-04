#!/bin/sh
# Builds out/quiet-home.apk from settings.conf. Needs Java 17 and the Android SDK (a platform and build-tools).
#   macOS:  brew install openjdk@17 && brew install --cask android-commandlinetools
#           sdkmanager "platforms;android-34" "build-tools;34.0.0"
#
#   sh build.sh                                  uses settings.conf, tiles/ and backgrounds/ here
#   SETTINGS=../my-tv/settings.conf sh build.sh  uses your own settings file instead; tiles/ and
#                                                backgrounds/ folders next to it are added on top
set -e
[ -n "$SETTINGS" ] && SETTINGS=$(cd "$(dirname "$SETTINGS")" && pwd)/$(basename "$SETTINGS")
cd "$(dirname "$0")"

CONF=${SETTINGS:-settings.conf}
[ -f "$CONF" ] || { echo "Settings file not found: $CONF" >&2; exit 1; }
CONF_DIR=$(cd "$(dirname "$CONF")" && pwd)
# The value of one setting: the last "name = value" line for it.
setting() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF" | tail -1 | tr -d '\r' | sed 's/[[:space:]]*$//'; }

NAME=$(setting name); NAME=${NAME:-Quiet Home}
APP_ID=$(setting app_id); APP_ID=${APP_ID:-com.abouhilalbadr.quiethome}
echo "$APP_ID" | grep -Eq '^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$' \
  || { echo "app_id must look like com.yourname.home (letters, digits, dots): $APP_ID" >&2; exit 1; }
CODE_PACKAGE=com.abouhilalbadr.quiethome

[ -n "$JAVA_HOME" ] || for j in /opt/homebrew/opt/openjdk@17 /usr/local/opt/openjdk@17 /usr/lib/jvm/java-17-openjdk-amd64 \
    /Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home; do [ -d "$j" ] && JAVA_HOME=$j && break; done
[ -n "$JAVA_HOME" ] && export PATH="$JAVA_HOME/bin:$PATH"
SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
[ -n "$SDK" ] || for d in /opt/homebrew/share/android-commandlinetools "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do [ -d "$d" ] && SDK=$d && break; done
# build-tools 34 and platform 34 if they're there, otherwise the newest installed.
newest() { ls -d "$1"/* 2>/dev/null | sort -V | tail -1; }
BT=$SDK/build-tools/34.0.0; [ -d "$BT" ] || BT=$(newest "$SDK/build-tools")
JAR=$SDK/platforms/android-34/android.jar; [ -f "$JAR" ] || JAR=$(newest "$SDK/platforms")/android.jar
[ -f "$JAR" ] && [ -x "$BT/aapt2" ] || { echo "Android SDK not found. Set ANDROID_HOME, and install a platform and build-tools (see the top of build.sh)." >&2; exit 1; }

rm -rf out; mkdir -p out/classes out/dex out/assets/bg out/assets/tiles out/res-gen/values

# What goes inside the app: the settings, the background pictures and the tile art.
cp "$CONF" out/assets/settings.conf
for dir in . "$CONF_DIR"; do
  for f in "$dir"/backgrounds/*.jpg "$dir"/backgrounds/*.jpeg "$dir"/backgrounds/*.png "$dir"/backgrounds/*.webp; do
    [ -f "$f" ] && cp "$f" out/assets/bg/
  done
  for f in "$dir"/tiles/*.png; do [ -f "$f" ] && cp "$f" out/assets/tiles/; done
done

# The app's name, from settings.conf.
xml_name=$(printf '%s' "$NAME" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\\"/g; s/'"'"'/\\'"'"'/g')
printf '<resources><string name="app_name">%s</string></resources>\n' "$xml_name" > out/res-gen/values/strings.xml

"$BT/aapt2" compile --dir res -o out/res.zip
"$BT/aapt2" compile --dir out/res-gen -o out/res-gen.zip
set -- -o out/base.apk -I "$JAR" --manifest AndroidManifest.xml --min-sdk-version 21 --target-sdk-version 34 -A out/assets
[ "$APP_ID" = "$CODE_PACKAGE" ] || set -- "$@" --rename-manifest-package "$APP_ID"
"$BT/aapt2" link "$@" out/res.zip out/res-gen.zip

javac -nowarn -Xlint:-options -source 1.8 -target 1.8 -bootclasspath "$JAR:$BT/core-lambda-stubs.jar" \
  -d out/classes $(find src -name "*.java")
"$BT/d8" --min-api 21 --release --lib "$JAR" --output out/dex $(find out/classes -name '*.class')
cp out/base.apk out/unsigned.apk; (cd out/dex && zip -q ../unsigned.apk classes.dex)
"$BT/zipalign" -f 4 out/unsigned.apk out/aligned.apk

# A signing key is made on first build. Keep key.jks: updates must be signed with the same key.
# (Releases are signed with their own key: set KEYSTORE and KEYSTORE_PASS.)
KS=${KEYSTORE:-key.jks}; PASS=${KEYSTORE_PASS:-quiethome}
[ -f "$KS" ] || keytool -genkeypair -keystore "$KS" -storepass "$PASS" -keypass "$PASS" -alias quiethome \
  -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Quiet Home" >/dev/null 2>&1
"$BT/apksigner" sign --ks "$KS" --ks-pass "pass:$PASS" --out out/quiet-home.apk out/aligned.apk
rm -f out/quiet-home.apk.idsig
echo "Built out/quiet-home.apk ($NAME, $APP_ID)"
