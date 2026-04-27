# Building KOReader for iOS / iPadOS

These instructions cover building KOReader as a sideloadable iOS / iPadOS
app from a macOS host. The build cross-compiles against the iOS SDK
shipped with Xcode.

For other targets, see [`Building_targets.md`](Building_targets.md). For
general macOS development setup (the emulator, common prereqs), see
[`Building.md`](Building.md).

## Prerequisites

### macOS + Xcode

You need the full **Xcode** install (App Store or
https://developer.apple.com/xcode/) — the Command-Line Tools alone don't
include the iOS SDK. After installing, run Xcode once to accept the
license, then verify:

```sh
xcrun --sdk iphoneos --show-sdk-path
```

Should print something like `/Applications/Xcode.app/.../iPhoneOS<version>.sdk`.

### Apple ID for sideloading

A free personal team works for personal builds (the resulting app
expires after 7 days; you re-sign by clicking Run again). A paid Apple
Developer Program membership ($99/year) gives you a 1-year cert and
unlocks iCloud Drive containers.

### Homebrew packages

Install everything in one command:

```sh
brew install autoconf automake bash binutils cmake coreutils findutils \
    gettext gnu-getopt libtool make meson nasm ninja pkgconf sdl3 \
    util-linux xcodegen
```

Then put the GNU versions of `make`/`find`/`getopt`/`flock` ahead of the
BSD ones on PATH (KOReader's Makefiles need GNU make ≥ 4.1, GNU
`getopt`, GNU `find`, and `flock` from `util-linux`):

```sh
export PATH="$(brew --prefix)/opt/findutils/libexec/gnubin:$(brew --prefix)/opt/gnu-getopt/bin:$(brew --prefix)/opt/make/libexec/gnubin:$(brew --prefix)/opt/util-linux/bin:${PATH}"
```

Add that line to your shell profile (`~/.zshrc`, `~/.bash_profile`,
etc.) if you're going to be building often.

### Optional: macOS emulator build

If you build the macOS emulator first, the iOS build can reuse its host
LuaJIT to precompile the bundled `.lua` files to bytecode at build
time, knocking 30–50% off cold-launch time on the iOS device:

```sh
make TARGET=macos base
```

This is optional — the build skips precompile silently if no host
LuaJIT is around.

## Quick verification

There's a preflight script that checks for everything above and reports
any gaps in one pass. The build will run it automatically, but you can
run it standalone:

```sh
./platform/ios/check-prereqs.sh
```

If it prints `[check-prereqs] all required tools present`, you're set.
Otherwise it prints a single `brew install` command listing the missing
packages.

## Build

```sh
git clone --recurse-submodules https://github.com/hezi/koreader-ios.git
cd koreader-ios
make TARGET=ios xcodeproj
open KOReader.xcodeproj
```

In Xcode:

1. Select the **KOReader** target in the project navigator.
2. **Signing & Capabilities** tab → check *Automatically manage signing*
   → pick your Team.
3. Plug in your iPhone/iPad and trust the Mac when prompted.
4. Choose your device from the run-destination dropdown.
5. Hit ⌘R.

The first launch on the device will require trusting your developer
profile in **Settings → General → VPN & Device Management** on the
phone.

## Headless / CI build

To validate the build without going through Xcode (e.g. as a CI smoke
test, or to verify changes compile before plugging in a device):

```sh
make TARGET=ios xcodeproj
xcodebuild -project KOReader.xcodeproj -scheme KOReader \
    -configuration Debug -destination 'generic/platform=iOS' \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

The resulting `.app` bundle is under
`~/Library/Developer/Xcode/DerivedData/KOReader-*/Build/Products/Debug-iphoneos/KOReader.app`
and won't install on a device (no signing) but will pass structural
validation.

## What's actually built

- **One main exec** (`KOReader`) — compiled from `platform/ios/ios_loader.m`
  + `ios_filepicker.m`, links `libluajit` and `libSDL3`.
- **One monolithic dylib** (`libkoreader-monolibtic.dylib`) — every
  thirdparty C/C++ library KOReader uses, statically linked into a
  single ~17 MiB shared library so iOS does one dyld load + signature
  check at launch instead of 30+.
- **`libluajit.dylib`** — separate so SDL3's iOS launcher can find its
  symbols at startup.
- **`libSDL3.0.dylib`** — separate, holds iOS-specific UIKit code.
- **`app/`** — the Lua frontend tree, all `.lua` files precompiled to
  bytecode (if a host LuaJIT was available).

## Limitations

- **No JIT.** iOS forbids W^X memory pages without a special
  entitlement. We build LuaJIT in interpreter-only mode. KOReader feels
  responsive but heavier Lua codepaths (e.g. cover-browser metadata
  extraction) are slower than on macOS — the cover browser plugin is
  patched to time-slice extraction across `UIManager` ticks rather than
  blocking the UI.
- **PDF reflow (KOPT mode) is disabled.** `libk2pdfopt`'s willuslib
  helpers call `system()`, which iOS marks as unavailable. We patch
  those calls to return 0 at build time so the library compiles, but
  reflow itself is non-functional. Plain PDF rendering via mupdf works.
- **Background extraction can't fork.** iOS sandboxing rejects
  `fork()`. `runInSubProcess` runs work inline on the main thread on
  iOS, with a `mkstemp`-backed file replacing the pipe for callers that
  need bidirectional communication.
- **iCloud Drive container** for the app's own folder needs a paid Apple
  Developer membership. The in-app cloud-folder picker (which can
  read/browse iCloud Drive, Dropbox, Google Drive, etc. via iOS' native
  document picker) works on a free personal team.
- **Simulator builds are untested.** The `IOS_PLATFORM=iphonesimulator`
  parameter exists in `make/ios.mk` but `base/` would need to be
  rebuilt against the simulator SDK — we haven't wired up an XCFramework.

## Troubleshooting

**`make: *** missing separator. Stop.`** or **`Recipe commences before first target`**

You're hitting macOS' BSD `make` (3.81) instead of GNU `make`. Run the
PATH export from the prereqs section above. Verify with `make --version`
— it should say `GNU Make 4.x` or higher.

**`Could not find Meson`** / **`meson: command not found`**

`brew install meson` (or use the full prereqs list above; meson is in
it).

**`flock: command not found`**

Provided by `util-linux`. Run `brew install util-linux` and add
`$(brew --prefix)/opt/util-linux/bin` to PATH (the export above does
this).

**`xcodegen: command not found`**

`brew install xcodegen`. It's in the full prereqs list above.

**`xcrun: error: SDK "iphoneos" cannot be located`**

You have only the Command-Line Tools, not Xcode. Install Xcode from the
App Store. Then `sudo xcode-select -s /Applications/Xcode.app`.

**Build succeeds but the app crashes on launch with a Lua error**

Likely a stale build artefact. Wipe the per-target build dir and rerun:

```sh
rm -rf base/build/arm64-apple-ios14.0
make TARGET=ios xcodeproj
```

**Cover browser triggers "Start-up of background extraction job failed"**

Shouldn't happen anymore (we patch around it on iOS), but if it does,
the cover browser is still functional — file browsing works, you just
won't see embedded cover thumbnails for new books.

**iOS warns about my dev profile when I tap the app icon**

Settings → General → VPN & Device Management → trust your developer
profile. iOS only asks once per device per Apple ID.

## Reporting build issues

If you hit a problem not covered above, open an issue at
https://github.com/hezi/koreader-ios/issues with:

- The output of `./platform/ios/check-prereqs.sh`
- Your macOS + Xcode versions (`sw_vers` + `xcodebuild -version`)
- The first error line from the build log
