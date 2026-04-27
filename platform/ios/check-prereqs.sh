#!/bin/bash
# Preflight: scan for every tool the iOS build needs and report all
# missing ones in a single pass. Without this, the build fails one tool
# at a time (the user fixes flock, restarts, hits 'meson not found',
# fixes that, restarts, etc. — see hezi/koreader-ios#1).

set -uo pipefail

missing_brew=()
notes=()

# Detect Homebrew first — almost everything below comes from there.
if ! command -v brew >/dev/null 2>&1; then
    cat >&2 <<'EOF'
[check-prereqs] Homebrew is not installed but is required to bring in
the iOS build prereqs. Install it from https://brew.sh/ and re-run.
EOF
    exit 1
fi

BREW_PREFIX="$(brew --prefix)"

# A "missing" check has two parts: the package name to brew-install, and a
# probe (command name OR file path) to determine presence. We keep the two
# separate so we can suggest a single composite `brew install` line.
need() {
    local probe="$1" pkg="$2" kind="${3:-cmd}"
    case "$kind" in
        cmd) command -v "$probe" >/dev/null 2>&1 && return 0 ;;
        file) [ -e "$probe" ] && return 0 ;;
    esac
    missing_brew+=("$pkg")
}

# Tools provided by individual brew packages.
need cmake          cmake
need ninja          ninja
need meson          meson
need nasm           nasm
need pkgconf        pkgconf  # also satisfies pkg-config
need autoreconf     autoconf
need automake       automake
# Brew installs libtool as `glibtool`/`glibtoolize`; the unprefixed names
# are only on PATH if libtool/libexec/gnubin is added explicitly.
if ! command -v glibtoolize >/dev/null 2>&1 && ! command -v libtoolize >/dev/null 2>&1; then
    missing_brew+=(libtool)
fi
need msgfmt         gettext
need xcodegen       xcodegen

# GNU coreutils on macOS install with a `g` prefix (gln, gcp, …) unless the
# user has put `coreutils/libexec/gnubin` ahead of /usr/bin on PATH. Our
# build needs `gln` (the `ln -snfr` flavour KOReader's Makefile uses).
need gln            coreutils

# GNU findutils → gfind. Build script uses GNU find features.
need gfind          findutils

# GNU getopt for `make/macos.mk`-style script utilities.
need "${BREW_PREFIX}/opt/gnu-getopt/bin/getopt" gnu-getopt file

# util-linux provides `flock`, used by koenv.sh to serialize concurrent
# git submodule fetches. This is the one that bit @gingerbeardman in #1.
need "${BREW_PREFIX}/opt/util-linux/bin/flock" util-linux file

# SDL3 headers/lib — the iOS target builds its own copy under base/build,
# but several upstream cmake projects probe for a system one with pkg-config
# and emit warnings without it. Recommended but not strictly required.
if ! [ -d "${BREW_PREFIX}/opt/sdl3" ]; then
    notes+=("recommended: brew install sdl3 (silences cmake warnings)")
fi

# GNU make >= 4.1 needs to be ahead of /usr/bin/make on PATH. macOS ships
# BSD make 3.81 which doesn't support the syntax KOReader's Makefiles use.
make_version=$(/usr/bin/env make --version 2>/dev/null | head -1)
if [[ "${make_version}" != *"GNU Make"* ]] || [[ "${make_version}" =~ "GNU Make 3." ]]; then
    # macOS ships BSD make 3.81 — too old for KOReader's Makefiles.
    # Brew has it but installs into make/libexec/gnubin (so /usr/bin/make
    # wins by default).
    if ! [ -x "${BREW_PREFIX}/opt/make/libexec/gnubin/make" ]; then
        missing_brew+=(make)
    fi
    # When the gnubin path isn't on PATH, the generic PATH-export
    # warning below will catch it — no need for a second message.
fi

# Path-flavour notes for the GNU tools that need to be ahead of the BSD
# versions on PATH. coreutils is intentionally NOT here — KOReader's
# Makefile calls those via the `g`-prefixed names (gln, gfind), so
# /opt/homebrew/bin alone is enough.
need_path_export=0
for opt in findutils gnu-getopt make util-linux; do
    if [ -d "${BREW_PREFIX}/opt/${opt}" ]; then
        case "$opt" in
            coreutils|findutils|make)
                gnubin="${BREW_PREFIX}/opt/${opt}/libexec/gnubin"
                ;;
            *)
                gnubin="${BREW_PREFIX}/opt/${opt}/bin"
                ;;
        esac
        case ":${PATH}:" in
            *":${gnubin}:"*) ;;
            *) need_path_export=1 ;;
        esac
    fi
done

# Xcode + iOS SDK.
if ! command -v xcrun >/dev/null 2>&1; then
    notes+=("xcrun not found — install Xcode (or 'xcode-select --install') for the iOS SDK")
elif ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    notes+=("Xcode Command-Line Tools alone don't include the iOS SDK; install full Xcode from the App Store")
fi

# Report.
if [ ${#missing_brew[@]} -gt 0 ]; then
    # Deduplicate while preserving order.
    seen=""
    deduped=()
    for pkg in "${missing_brew[@]}"; do
        case " ${seen} " in *" ${pkg} "*) ;; *) deduped+=("$pkg"); seen="${seen} ${pkg}" ;; esac
    done

    echo "" >&2
    echo "[check-prereqs] missing brew packages:" >&2
    for pkg in "${deduped[@]}"; do echo "  - ${pkg}" >&2; done
    echo "" >&2
    echo "Install them with one command:" >&2
    echo "  brew install ${deduped[*]}" >&2
    echo "" >&2
fi

if [ "${need_path_export}" -eq 1 ]; then
    echo "[check-prereqs] some Homebrew GNU tools are installed but not on PATH." >&2
    echo "Add this line to your shell profile (or run it now in this shell):" >&2
    echo "" >&2
    echo "  export PATH=\"${BREW_PREFIX}/opt/findutils/libexec/gnubin:${BREW_PREFIX}/opt/gnu-getopt/bin:${BREW_PREFIX}/opt/make/libexec/gnubin:${BREW_PREFIX}/opt/util-linux/bin:\${PATH}\"" >&2
    echo "" >&2
fi

if [ ${#notes[@]} -gt 0 ]; then
    for n in "${notes[@]}"; do
        echo "[check-prereqs] ${n}" >&2
    done
fi

# Exit non-zero if anything blocking is missing. PATH export issues alone
# don't block — we just warn — because some users put GNU tools on PATH via
# different means (asdf, mise, manual install).
if [ ${#missing_brew[@]} -gt 0 ]; then
    exit 1
fi

echo "[check-prereqs] all required tools present"
