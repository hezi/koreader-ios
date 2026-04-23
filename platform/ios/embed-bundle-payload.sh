#!/bin/bash
# Post-build hook for the Xcode project.
#
# Xcode has just built the .app shell (a folder with KOReader, Info.plist,
# and signing metadata). We populate it with the Lua frontend, the koreader
# data tree, and the prebuilt dylibs from base/build/, then re-sign every
# dylib with the same identity Xcode used for the app so the bundle
# verifies as a unit at install time.

set -euo pipefail

: "${SRCROOT:?Xcode env var SRCROOT not set; this script must run from a build phase}"
: "${TARGET_BUILD_DIR:?Xcode env var TARGET_BUILD_DIR not set}"
: "${WRAPPER_NAME:?Xcode env var WRAPPER_NAME not set}"

# Override per-config / per-arch if needed; defaults match make/ios.mk.
IOS_ARCH="${IOS_ARCH:-arm64}"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-14.0}"

APP_DIR="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
STAGING="${SRCROOT}/koreader-ios-${IOS_ARCH}-apple-ios${IOS_DEPLOYMENT_TARGET}"
STAGING_KOREADER="${STAGING}/koreader"
LIBS_SRC="${SRCROOT}/base/build/${IOS_ARCH}-apple-ios${IOS_DEPLOYMENT_TARGET}/libs"

if [ ! -d "${STAGING_KOREADER}" ]; then
    echo "error: staging tree not found at ${STAGING_KOREADER}" >&2
    echo "       run \`make TARGET=ios all\` first (or check the pre-build phase)." >&2
    exit 1
fi

if [ ! -d "${LIBS_SRC}" ]; then
    echo "error: prebuilt libs not found at ${LIBS_SRC}" >&2
    exit 1
fi

echo "[*] Embedding payload into ${APP_DIR}"

# --- 1) Copy the asset tree.
# Using `app/` rather than `koreader/` because APFS is case-insensitive by
# default and CFBundleExecutable=KOReader would collide with `koreader/`.
mkdir -p "${APP_DIR}/app"
rsync -aL --delete \
    --exclude '.git' \
    --exclude 'cache' \
    --exclude 'history' \
    --exclude 'screenshots' \
    --exclude 'spec' \
    --exclude 'tools' \
    --exclude '*.dSYM' \
    --exclude 'plugins/SSH.koplugin' \
    --exclude 'plugins/autofrontlight.koplugin' \
    --exclude 'plugins/hello.koplugin' \
    --exclude 'plugins/timesync.koplugin' \
    "${STAGING_KOREADER}/" "${APP_DIR}/app/"

# --- 2) Re-sign every embedded dylib with the same identity as the app.
# Pick the most-resolved identity Xcode passed us, falling back to ad-hoc
# when signing is disabled or no real identity is wired up.
SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"

# CODE_SIGNING_ALLOWED=NO (e.g. CI builds) → ad-hoc.
# Bare "iPhone Developer" / "Apple Development" / etc. without a resolved
# identity also means no real cert is available.
if [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ] \
    || [ -z "${SIGN_IDENTITY}" ] \
    || [ "${SIGN_IDENTITY}" = "iPhone Developer" ] \
    || [ "${SIGN_IDENTITY}" = "Apple Development" ] \
    || [ "${SIGN_IDENTITY}" = "-" ]; then
    SIGN_IDENTITY="-"
    KEYCHAIN_FLAG=""
else
    KEYCHAIN_FLAG="${OTHER_CODE_SIGN_FLAGS:-}"
fi

echo "[*] Re-signing every Mach-O in the bundle with identity: ${SIGN_IDENTITY}"
# We have to sign every .dylib and .so, not just app/libs/ — KOReader
# also dlopens Lua C modules from app/common/ (lpeg.so, rapidjson.so,
# etc.) and per-plugin .so's. iOS refuses any unsigned Mach-O at dlopen
# time ("mapped file has no cdhash").
while IFS= read -r -d '' lib; do
    /usr/bin/codesign \
        --force \
        --sign "${SIGN_IDENTITY}" \
        --timestamp=none \
        ${KEYCHAIN_FLAG} \
        "${lib}" >/dev/null
done < <(find "${APP_DIR}/app" -type f \( -name '*.dylib' -o -name '*.so' \) -print0)

echo "[*] Payload embedded."
