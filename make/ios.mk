IOS_DIR = $(PLATFORM_DIR)/ios

define UPDATE_PATH_EXCLUDES +=
plugins/SSH.koplugin
plugins/autofrontlight.koplugin
plugins/hello.koplugin
plugins/timesync.koplugin
tools
endef

# Preflight: bail out early with a single message listing every missing
# brew package + the PATH export, instead of failing one tool at a time
# during the build (see hezi/koreader-ios#1).
ios-check-prereqs:
	@$(CURDIR)/platform/ios/check-prereqs.sh

update: ios-check-prereqs all
	$(CURDIR)/platform/ios/do_ios_bundle.sh $(INSTALL_DIR)

# Bundle identifier baked into Info.plist. Must match
# PRODUCT_BUNDLE_IDENTIFIER in platform/ios/project.yml.
IOS_BUNDLE_ID ?= rocks.koreader.ios

# CFBundleShortVersionString has to be a dotted numeric string; the raw
# `git describe` output (v2026.03-70-gabc123_2026-04-27) is not, and iOS
# rejects the bundle at install time. Split the describe into the tag and
# the commits-ahead count: v2026.03-70-g... -> 2026.03.70 / build 70.
KO_VER_PARTS := $(subst -, ,$(patsubst v%,%,$(VERSION)))
IOS_SHORT_VERSION := $(word 1,$(KO_VER_PARTS)).$(or $(word 2,$(KO_VER_PARTS)),0)
IOS_BUNDLE_VERSION := $(or $(word 2,$(KO_VER_PARTS)),0)

# platform/ios/Info.plist is gitignored and generated. project.yml points
# INFOPLIST_FILE at it, so it must exist before xcodegen runs -- a fresh
# clone has only Info.plist.in.
$(IOS_DIR)/Info.plist: $(IOS_DIR)/Info.plist.in
	@echo "Generating $@ (version $(IOS_SHORT_VERSION), build $(IOS_BUNDLE_VERSION), id $(IOS_BUNDLE_ID))"
	@sed -e 's|@BUNDLE_ID@|$(IOS_BUNDLE_ID)|g' \
	     -e 's|@SHORT_VERSION@|$(IOS_SHORT_VERSION)|g' \
	     -e 's|@BUNDLE_VERSION@|$(IOS_BUNDLE_VERSION)|g' \
	     -e 's|@VERSION@|$(IOS_SHORT_VERSION)|g' \
	     $< > $@

# Generate KOReader.xcodeproj at the repo root from platform/ios/project.yml.
# Depends on `all` so the staging tree + base/build/<machine>/libs/ exist
# (the project's pre-build script also calls `make TARGET=ios base`, but
# having them present at generation time avoids confusing first-time errors).
xcodeproj: ios-check-prereqs all $(IOS_DIR)/Info.plist
	xcodegen generate \
		--spec $(IOS_DIR)/project.yml \
		--project $(CURDIR) \
		--project-root $(CURDIR)
	@echo
	@echo "Generated $(CURDIR)/KOReader.xcodeproj"
	@echo "Open it in Xcode, set your Team under Signing & Capabilities,"
	@echo "then Run on a connected device (or a simulator if libs are simulator-built)."

PHONY += ios-check-prereqs xcodeproj
