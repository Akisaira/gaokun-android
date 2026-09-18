#!/usr/bin/env bash
# Clone the reference trees listed in CLAUDE.md into refs/.
#
# Shallow, single-branch: these are read-only references to grep against,
# not trees we develop in. Total ~2.3 GB.
#
#     bash scripts/clone-refs.sh
#
# Re-running is safe — existing clones are skipped.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)/refs"
mkdir -p "$ROOT"
cd "$ROOT" || exit 1

# dir|url|branch    (branches verified against the remotes 2026-08-13)
REPOS="
linux-gaokun|https://github.com/right-0903/linux-gaokun|main
matebook-e-go-linux|https://github.com/whitelewi1-ctrl/matebook-e-go-linux|master
boot-works|https://github.com/matalama80td3l/matebook-e-go-boot-works|main
aospm-device-sdm845|https://github.com/aospm/android_device_generic_sdm845|main
aospm-manifests|https://github.com/aospm/android_local_manifests|main
aospm-system-core|https://github.com/aospm/platform_system_core|master
aospm-tinyhal|https://github.com/aospm/tinyhal|master
jhovold-linux|https://github.com/jhovold/linux|wip/sc8280xp-6.16
egotouchrev-linux|https://github.com/chiyuki0325/EGoTouchRev-Linux|main
gaokun-buildbot|https://github.com/KawaiiHachimi/linux-gaokun-buildbot|main
egotouchrev-rebuild|https://github.com/awarson2233/EGoTouchRev-rebuild|main
libcamera|https://gitlab.freedesktop.org/camera/libcamera.git|master
lineage-sepolicy|https://github.com/LineageOS/android_system_sepolicy|lineage-23.0
"

echo "=== clone start ==="

echo "$REPOS" | while IFS='|' read -r dir url branch; do
    [ -z "$dir" ] && continue

    if [ -d "$dir/.git" ]; then
        echo "SKIP   $dir (already present)"
        continue
    fi

    echo "CLONE  $dir  <- $url @ $branch"
    # autocrlf=false: CRLF conversion would corrupt kernel patches and shell scripts.
    # longpaths=true: the Linux tree has paths past the 260-char Win32 limit.
    # symlinks=false: avoids needing Developer Mode / admin on Windows.
    git -c core.autocrlf=false \
        -c core.longpaths=true \
        -c core.symlinks=false \
        clone --depth 1 --single-branch --branch "$branch" \
        "$url" "$dir" 2>&1 | tail -5

    if [ -d "$dir/.git" ]; then
        echo "OK     $dir"
    else
        echo "FAIL   $dir"
    fi
done

echo "=== clone done ==="
du -sh "$ROOT"/* 2>/dev/null
