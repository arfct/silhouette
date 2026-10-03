DERIVED := build
# Local runs use the Debug configuration: a separate bundle id
# (com.artifact.Silhouette.dev) so TCC treats it as its own app.
APP     := $(DERIVED)/Build/Products/Debug/Silhouette.app

.PHONY: project build run install uninstall clean

project:
	xcodegen generate --quiet

build: project
	xcodebuild -project Silhouette.xcodeproj -scheme Silhouette -configuration Debug \
	  -derivedDataPath $(DERIVED) -allowProvisioningUpdates build

# Run from the build folder. Keying and the preview work; the virtual camera
# needs the app in /Applications (see install).
run: build
	open "$(APP)"

# System extensions only activate from /Applications. Installs the notarized
# Developer ID export so the installed app keeps one stable signature.
install: export
	rm -rf /Applications/Silhouette.app
	ditto $(EXPORT)/Silhouette.app /Applications/Silhouette.app
	open /Applications/Silhouette.app

# Deleting the app makes macOS remove its camera extension (it asks once).
uninstall:
	rm -rf /Applications/Silhouette.app

clean:
	rm -rf $(DERIVED) Silhouette.xcodeproj

# ---- Distribution (Developer ID + notarization) ----------------------------
# One-time setup:
#   1. Create a "Developer ID Application" certificate (Xcode → Settings →
#      Accounts → Manage Certificates → +). Only the Account Holder can.
#   2. xcrun notarytool store-credentials GreenScreen --apple-id you@example.com \
#        --team-id TVA9Z8LD95 --password <app-specific password>
NOTARY_PROFILE ?= GreenScreen   # name used with notarytool store-credentials
ARCHIVE := $(DERIVED)/Silhouette.xcarchive
EXPORT  := $(DERIVED)/export
DIST    := dist/Silhouette.zip

.PHONY: archive export notarize dist

archive: project
	xcodebuild -project Silhouette.xcodeproj -scheme Silhouette -configuration Release \
	  -derivedDataPath $(DERIVED) -archivePath $(ARCHIVE) -allowProvisioningUpdates archive

export: archive
	rm -rf $(EXPORT)
	xcodebuild -exportArchive -archivePath $(ARCHIVE) -exportPath $(EXPORT) \
	  -exportOptionsPlist dist/ExportOptions.plist -allowProvisioningUpdates

notarize: export
	ditto -c -k --keepParent --sequesterRsrc $(EXPORT)/Silhouette.app $(DIST)
	xcrun notarytool submit $(DIST) --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple $(EXPORT)/Silhouette.app
	ditto -c -k --keepParent --sequesterRsrc $(EXPORT)/Silhouette.app $(DIST)
	spctl --assess --type execute -v $(EXPORT)/Silhouette.app

dist: notarize
	@echo "Distributable build: $(DIST)"

## App Store Connect / TestFlight: same archive, App Store signing, uploaded straight from here.
## Needs an App Store Connect app record for com.artifact.Silhouette and the team's account in Xcode.
## Each upload needs a new build number; the version (MARKETING_VERSION) stays put,
## because changing it starts a new App Review version.
bump-build:
	@n=$$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\([0-9]*\)"/\1/p' project.yml | head -1); \
	sed -i '' "s/CURRENT_PROJECT_VERSION: \"$$n\"/CURRENT_PROJECT_VERSION: \"$$((n+1))\"/" project.yml; \
	echo "Build number $$n -> $$((n+1))"

testflight: bump-build archive
	xcodebuild -exportArchive -archivePath $(ARCHIVE) -exportPath build/appstore \
	  -exportOptionsPlist dist/ExportOptionsAppStore.plist -allowProvisioningUpdates
