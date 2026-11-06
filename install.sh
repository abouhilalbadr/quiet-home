#!/bin/sh
# Installs Quiet Home on your TV and makes it the default home screen. Only needs adb.
#
#   sh install.sh <TV_IP>                          your TV apps, picked for you
#   sh install.sh <TV_IP> "com.netflix.ninja,com.google.android.youtube.tv"
#   sh install.sh <TV_IP> "" "bluetooth,sound,picture"   adds settings shortcuts by the clock
#
# Uses out/quiet-home.apk if you built it (sh build.sh), otherwise downloads the latest release.
# Built with your own settings file? Pass it the same way: SETTINGS=../my-tv/settings.conf sh install.sh <TV_IP>
set -e
[ -n "$SETTINGS" ] && SETTINGS=$(cd "$(dirname "$SETTINGS")" && pwd)/$(basename "$SETTINGS")
cd "$(dirname "$0")"
# The app ID from settings.conf (or SETTINGS=<your file>), so a renamed copy is found too.
CONF=${SETTINGS:-settings.conf}
APP=$( [ -f "$CONF" ] && sed -n 's/^[[:space:]]*app_id[[:space:]]*=[[:space:]]*//p' "$CONF" | tail -1 | tr -d '\r' | sed 's/[[:space:]]*$//')
APP=${APP:-com.abouhilalbadr.quiethome}
ME=$APP/com.abouhilalbadr.quiethome.MainActivity
DISABLED=/data/local/tmp/quiet-home-disabled.txt

TARGET="$1"; APPS="$2"; QUICK="$3"
[ -n "$TARGET" ] || { echo "Usage: sh install.sh <TV_IP> [\"app1,app2,...\"] [\"bluetooth,sound,picture\"]" >&2; exit 1; }
command -v adb >/dev/null 2>&1 || {
  echo "adb is missing. Install it first:" >&2
  echo "  Mac:     brew install android-platform-tools" >&2
  echo "  Windows: https://developer.android.com/tools/releases/platform-tools" >&2
  exit 1; }

# An IP gets :5555 added; an adb serial (like emulator-5554) is used as is.
case "$TARGET" in
  *.*.*.*:*) TV=$TARGET ;;
  *.*.*.*)   TV=$TARGET:5555 ;;
  *)         TV=$TARGET ;;
esac
case "$TV" in *:*) adb connect "$TV" >/dev/null || true ;; esac

state=$(adb -s "$TV" get-state 2>&1 || true)
case "$state" in
  device) ;;
  *unauthorized*) echo "Your TV is asking \"Allow debugging?\". Press Allow (tick \"Always allow\"), then run this again." >&2; exit 1 ;;
  *) echo "Can't reach $TV. Check the TV is on, on the same Wi-Fi, and has USB/network debugging turned on." >&2; exit 1 ;;
esac

APK=out/quiet-home.apk
if [ ! -f "$APK" ]; then
  APK=$(mktemp -d)/quiet-home.apk
  echo "Downloading Quiet Home…"
  curl -fsSL -o "$APK" https://github.com/abouhilalbadr/quiet-home/releases/latest/download/quiet-home.apk \
    || { echo "No release to download yet. Build it first: sh build.sh" >&2; exit 1; }
  APP=com.abouhilalbadr.quiethome; ME=$APP/com.abouhilalbadr.quiethome.MainActivity
fi

echo "Installing… If your TV shows a Google Play Protect message, follow it on the TV to allow the install."
if ! out=$(adb -s "$TV" install -r "$APK" 2>&1); then
  case "$out" in
    *UPDATE_INCOMPATIBLE*) echo "Replacing an older copy signed with a different key…"
                           adb -s "$TV" uninstall "$APP" >/dev/null; adb -s "$TV" install "$APK" ;;
    *) echo "$out" >&2; exit 1 ;;
  esac
fi

if [ -n "$APPS" ] || [ -n "$QUICK" ]; then
  # The stamp makes the app apply this list once, even if Android later replays this start.
  set -- --es stamp "$(date +%s)"
  [ -n "$APPS" ] && set -- "$@" --es apps "\"$APPS\""
  [ -n "$QUICK" ] && set -- "$@" --es quick "\"$QUICK\""
  adb -s "$TV" shell am start -n "$ME" "$@" >/dev/null
fi

sh_tv() { adb -s "$TV" shell "$@" | tr -d '\r'; }
current_home() { sh_tv cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME | tail -1; }
is_me() { case "$(current_home)" in "$APP"/*) return 0 ;; esac; return 1; }

# Make it the default home: the role (Android 10+) and the classic way.
if [ "$(sh_tv getprop ro.build.version.sdk)" -ge 29 ]; then
  sh_tv cmd role add-role-holder --user 0 android.app.role.HOME "$APP" >/dev/null 2>&1 || true
fi
sh_tv cmd package set-home-activity "$ME" >/dev/null 2>&1 || true

# Known TV home screens that are safe to turn off.
LAUNCHERS="com.google.android.tvlauncher com.google.android.apps.tv.launcherx com.google.android.leanbacklauncher
  com.mitv.tvhome com.amazon.tv.launcher"

# Only known launchers get turned off. Settings, setup and System UI also answer Home, and
# the TV needs them to start, so they, unknown apps and anything always running stay on.
# (Google TV's setup helper is the one exception, handled below.)
is_launcher() {
  case "$1" in
    "$APP"|com.android.settings|com.android.tv.settings|com.android.systemui|com.android.provision) return 1 ;;
    *setup*|*wraith*|*provision*|*systemui*|*tvcenter*|*.tv.framework*|*.tvinput*) return 1 ;;
  esac
  case " $(echo $LAUNCHERS) " in *" $1 "*) ;; *) return 1 ;; esac
  # If we can't read its flags, or it always runs, leave it on.
  flags=$(sh_tv dumpsys package "$1" 2>/dev/null | grep -m1 'pkgFlags=\[') || return 1
  case "$flags" in *PERSISTENT*) return 1 ;; esac
  return 0
}

# Most TVs' own launchers still win when you press Home. The fix is to turn them off
# (not uninstall). We save what we turned off on the TV, so undo.sh can turn it back on.
if ! is_me; then
  others=""
  for p in $(sh_tv cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null \
      | grep / | sed 's|/.*||; s/^ *//' | sort -u); do
    if is_launcher "$p"; then others="$others $p"; continue; fi
    case "$p" in "$APP"|com.android.settings|com.android.tv.settings) ;; *) echo "Leaving $p on: it may be needed for your TV to start." ;; esac
  done
  others=$(echo $others | tr ' ' '\n')
  if [ -n "$others" ]; then
    echo "Your TV's own home screen keeps taking over:"
    echo "$others" | sed 's/^/  /'
    answer=${YES:+y}
    if [ -z "$answer" ]; then
      printf "Turn it off so Home opens your new home screen? You can undo this with undo.sh. [y/N] "
      read answer </dev/tty || answer=n
    fi
    case "$answer" in
      y|Y|yes)
        for p in $others; do
          sh_tv pm disable-user --user 0 "$p" >/dev/null && sh_tv "echo $p >> $DISABLED"
        done
        # Android saves this a few seconds later. Restarting before then can undo it.
        echo "Saving the change on the TV, this takes 15 seconds…"
        sleep 15
        sh_tv cmd package set-home-activity "$ME" >/dev/null 2>&1 || true ;;
      *) echo "Left it on. Your TV may keep opening its own home screen." ;;
    esac
  fi
fi

# Google TV: with its launcher off, the setup helper answers Home ahead of every other app,
# because system apps can outrank the rest, and it brings the launcher back. So on Google TV
# alone it has to go off too. Anywhere else, setup apps stay on.
HELPER=com.google.android.tungsten.setupwraith
LAUNCHER=com.google.android.apps.tv.launcherx
case "$(current_home)" in
  "$HELPER"/*)
    echo "Google TV's setup helper now answers the Home button: $HELPER"
    answer=${YES:+y}
    if [ -z "$answer" ]; then
      printf "Turn it off too, so Home opens your new home screen? You can undo this with undo.sh. [y/N] "
      read answer </dev/tty || answer=n
    fi
    case "$answer" in
      y|Y|yes)
        # Noted before the change: the connection can drop right after it.
        sh_tv "echo $HELPER >> $DISABLED"
        sh_tv pm disable-user --user 0 "$HELPER" >/dev/null
        echo "Saving the change on the TV, this takes 15 seconds…"
        sleep 15
        tries=0
        until [ "$(adb -s "$TV" get-state 2>/dev/null)" = device ] || [ "$tries" -ge 24 ]; do
          [ "$tries" -eq 0 ] && echo "The TV dropped its connection. Waiting up to 2 minutes for it…"
          tries=$((tries + 1)); sleep 5
          case "$TV" in *:*) adb connect "$TV" >/dev/null 2>&1 || true ;; esac
        done
        if [ "$(adb -s "$TV" get-state 2>/dev/null)" != device ]; then
          echo "The TV hasn't reconnected yet. It usually comes back by itself. Press Home on the remote, then run: sh check.sh $TARGET --fix" >&2
          exit 1
        fi
        sh_tv cmd role add-role-holder --user 0 android.app.role.HOME "$APP" >/dev/null 2>&1 || true
        sh_tv cmd package set-home-activity "$ME" >/dev/null 2>&1 || true ;;
      *)
        echo "Left it on and turned Google TV's own home screen back on."
        sh_tv pm enable "$LAUNCHER" >/dev/null
        sh_tv "sed -i /$LAUNCHER/d $DISABLED" ;;
    esac ;;
esac

adb -s "$TV" shell input keyevent KEYCODE_HOME
if is_me; then
  echo "Done. Press Home on your remote to see it."
else
  echo "Installed, but your TV still opens its own home screen. If it asks which home screen to use, pick Quiet Home and choose Always."
fi
