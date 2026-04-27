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

# Generate KOReader.xcodeproj at the repo root from platform/ios/project.yml.
# Depends on `all` so the staging tree + base/build/<machine>/libs/ exist
# (the project's pre-build script also calls `make TARGET=ios base`, but
# having them present at generation time avoids confusing first-time errors).
xcodeproj: ios-check-prereqs all
	xcodegen generate \
		--spec $(IOS_DIR)/project.yml \
		--project $(CURDIR) \
		--project-root $(CURDIR)
	@echo
	@echo "Generated $(CURDIR)/KOReader.xcodeproj"
	@echo "Open it in Xcode, set your Team under Signing & Capabilities,"
	@echo "then Run on a connected device (or a simulator if libs are simulator-built)."

PHONY += ios-check-prereqs xcodeproj
