#!/usr/bin/env bash
# Replace files of the runtime installed on a device with the ones dev/wine.sh
# built, for testing a Wine change without a release:
#
#   dev/push.sh                              everything `dev/wine.sh changed` lists
#   dev/push.sh lib/wine/aarch64-unix/win32u.so ...     just these (runtime paths)
#
# Runs on the machine that has adb (the Mac); the build stays in the Linux VM,
# reached through `orb` when this is not Linux. The app must be debuggable
# (run-as). The installed runtime is sealed read-only and prefixes link into
# it, so files are replaced in place and every prefix sees them at once.
#
# Not a release path: the device then runs a runtime no recipe describes.
# Reinstall the runtime from the app (System page) to get back to the release.
#
# Environment:
#   ANDROID_SERIAL   the device, as for adb
#   AMPHORA_PACKAGE  default app.amphora
#   AMPHORA_VM       OrbStack machine with the build, default bst-amd64
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="${AMPHORA_PACKAGE:-app.amphora}"
OUT="$ROOT/out/dev-push"
REMOTE=/data/local/tmp/amphora-dev-push

in_vm() {
  if [ "$(uname -s)" = Linux ]; then "$@"; else orb -m "${AMPHORA_VM:-bst-amd64}" "$@"; fi
}

in_vm "$ROOT/dev/wine.sh" collect "$OUT" "$@"

# A local build once produced PE files that were all zeros (scripts/runtime.sh
# has the same check for releases).
bad=0
while IFS= read -r -d '' f; do
  rel="${f#"$OUT"/}"
  if ! LC_ALL=C grep -qa '[^\x00]' "$f"; then
    echo "$rel: all zero bytes" >&2; bad=1
  elif [[ "$rel" == lib/wine/*-windows/* ]] && [ "$(head -c 2 "$f")" != MZ ]; then
    echo "$rel: no MZ header" >&2; bad=1
  fi
done < <(find "$OUT" -type f -print0)
[ "$bad" = 0 ] || { echo "dev/push.sh: not pushing a broken build" >&2; exit 1; }

adb shell "rm -rf $REMOTE"
adb push "$OUT" "$REMOTE" | tail -n 1
# One runtime is installed at a time. Directories are sealed (no write
# permission) and files read-only: open the directory, replace the file,
# restore both. Mode 500 for what the loader maps or runs, 400 for PE files.
adb shell "run-as $PACKAGE sh -e -c '
  set -- files/amphora/runtimes/*/
  test \$# -eq 1 -a -d \"\$1\" || { echo \"no single runtime installed in $PACKAGE\" >&2; exit 1; }
  runtime=\"\$1\"
  cd $REMOTE
  find . -type f | while read -r f; do
    f=\"\${f#./}\"
    dir=\"\$OLDPWD/\$runtime\$(dirname \"\$f\")\"
    test -d \"\$dir\" || { echo \"\$f: no such directory in the runtime\" >&2; exit 1; }
    case \"\$f\" in *-windows/*) mode=400 ;; *) mode=500 ;; esac
    chmod u+w \"\$dir\"
    rm -f \"\$dir/\$(basename \"\$f\")\"
    cp \"\$f\" \"\$dir/\" && chmod \$mode \"\$dir/\$(basename \"\$f\")\"
    chmod u-w \"\$dir\"
    echo \"  \$f\"
  done
  echo \"pushed into \$runtime\"
'"
adb shell "rm -rf $REMOTE"
