# Thoria — archive / TestFlight pipeline.
#
# The app's user-visible name is "Thoria" (CFBundleDisplayName, set in
# ios/project.yml). The repo, the Xcode target, the scheme and the bundle ID
# are still "AudioNote" — the bundle ID cannot change, because the App Store
# Connect record and its provisioning profile are bound to it.
#
# Xcode names the exported IPA after CFBundleName, so the IPA is Thoria.ipa
# even though the app inside it is AudioNote.app. Keep IPA below in sync with
# ios/project.yml's CFBundleName.
#
# This app is signed with a DIFFERENT Apple Developer account than the
# drasif project, so nothing here reuses that project's credentials:
#
#   Team / bundle ID : 25FH23Q3GA (Hongtao Wang) / info.karsa.app.ios.audionote
#   ASC API key      : this account's own key (see Prerequisites) — the drasif
#                      account's key cannot see or upload this app.
#
# Prerequisites (one-time, on the account that owns team 25FH23Q3GA):
#
#   1. Xcode signed in with an account that has access to team 25FH23Q3GA.
#      `archive` and `-exportArchive` both pass -allowProvisioningUpdates, so
#      Xcode creates the Apple Distribution certificate and the App Store
#      provisioning profile on demand. This is already satisfied on this
#      machine: the IPA that `make ipa` produced on 2026-11-04 is signed with
#      "Apple Distribution: Hongtao Wang (25FH23Q3GA)" and carries the
#      "iOS Team Store Provisioning Profile: info.karsa.app.ios.audionote".
#
#   2. An App Store Connect API key with the App Manager role:
#        appstoreconnect.com → Users and Access → Integrations
#          → App Store Connect API → create key → download AuthKey_<KEYID>.p8
#        The key this project uses is 3Q68WNN5JG (issuer 40bf00a7-a2e1-4319-aadc-bb8eaae2ab76),
#        kept at ~/.asc/Hongtao_Wang/team_key/ and also at ~/.private_keys/.
#
#   3. An App Store Connect app record for info.karsa.app.ios.audionote.
#      ASC rejects a build whose bundle ID has no app record. The record
#      exists (app id 6830571230, named "Thoria" — the same name the app
#      shows on device).
#
# Usage:
#   make ipa                → archive + export
#                            output: ios/build/export/Thoria.ipa
#   make tf BUILD=2         → the same IPA, uploaded to TestFlight
#   make tf BUILD=2 VERSION=1.0.1
#   make upload             → upload the IPA that is already there, no rebuild
#   make clean
#
# The build number is explicit on purpose: ASC rejects a duplicate build
# number inside one train, and this project's version numbers live in
# ios/project.yml (XcodeGen is the source of truth), so nothing here
# rewrites the project file.
#
# Do NOT pass CODE_SIGN_IDENTITY on the command line. The target signs the
# archive with "Apple Development" (ios/project.yml pins it), and Xcode then
# rejects a command-line identity override with "conflicting provisioning
# settings". That is fine: the export step re-signs the archive for
# distribution with the team's "Apple Distribution" certificate and the App
# Store provisioning profile, both of which -allowProvisioningUpdates creates
# on demand. The exported IPA ends up distribution-signed
# (get-task-allow = false) even though the archive is not.

.PHONY: ipa tf upload clean check-asc

# Prerequisites run left to right, so the credential check happens before the
# (slow) archive rather than after it.
.NOTPARALLEL:

TEAM_ID    ?= 25FH23Q3GA
SCHEME     ?= AudioNote
PROJECT    ?= ios/AudioNote.xcodeproj
BUILD_DIR  ?= ios/build
ARCHIVE    ?= $(BUILD_DIR)/AudioNote.xcarchive
EXPORT_DIR ?= $(BUILD_DIR)/export
IPA        ?= $(EXPORT_DIR)/Thoria.ipa
EXPORT_PLIST ?= ios/exportOptions-appstore.plist
ARCHIVE_LOG ?= $(BUILD_DIR)/archive.log
EXPORT_LOG  ?= $(BUILD_DIR)/export.log

# Version and build number default to what ios/project.yml declares.
VERSION ?= $(shell awk '/MARKETING_VERSION/ {gsub(/[" ]/,"",$$2); print $$2; exit}' ios/project.yml)
BUILD     ?= $(shell awk '/CURRENT_PROJECT_VERSION/ {gsub(/[" ]/,"",$$2); print $$2; exit}' ios/project.yml)

# App Store Connect API key — this app's account, not drasif's.
# Key id and issuer are public identifiers (the private key is not: it stays in
# ~/.private_keys/ or ~/.asc/). Override on the command line if the key is
# rotated: make tf BUILD=2 ASC_API_KEY_ID=<KEYID> ASC_API_ISSUER=<uuid>
ASC_API_KEY_ID ?= 3Q68WNN5JG
ASC_API_ISSUER ?= 40bf00a7-a2e1-4319-aadc-bb8eaae2ab76
ASC_KEY_PATH   ?= $(shell ls $(HOME)/.asc/*/team_key/AuthKey_$(ASC_API_KEY_ID).p8 $(HOME)/.private_keys/AuthKey_$(ASC_API_KEY_ID).p8 2>/dev/null | head -1)
# Name of the App Store Connect app record — also the on-device display name.
ASC_APP_NAME   ?= Thoria

# The xcodebuild output is thousands of lines; a terminal that renders all of it
# can lose the process mid-archive. Send it to a log and print only the verdict.
ipa:
	@mkdir -p $(BUILD_DIR)
	@rm -rf $(ARCHIVE) $(EXPORT_DIR)
	@echo "→ Archiving $(SCHEME) $(VERSION) ($(BUILD))… log: $(ARCHIVE_LOG)"
	@xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -configuration Release -destination 'generic/platform=iOS' \
	  -archivePath $(ARCHIVE) archive \
	  -allowProvisioningUpdates \
	  DEVELOPMENT_TEAM=$(TEAM_ID) \
	  CODE_SIGN_STYLE=Automatic \
	  MARKETING_VERSION=$(VERSION) \
	  CURRENT_PROJECT_VERSION=$(BUILD) \
	  > $(ARCHIVE_LOG) 2>&1 \
	  || { echo "ARCHIVE FAILED — tail of $(ARCHIVE_LOG):"; tail -30 $(ARCHIVE_LOG); exit 1; }
	@echo "→ Exporting IPA…"
	@xcodebuild -exportArchive \
	  -archivePath $(ARCHIVE) \
	  -exportOptionsPlist $(EXPORT_PLIST) \
	  -exportPath $(EXPORT_DIR) \
	  -allowProvisioningUpdates \
	  > $(EXPORT_LOG) 2>&1 \
	  || { echo "EXPORT FAILED — tail of $(EXPORT_LOG):"; tail -30 $(EXPORT_LOG); exit 1; }
	@test -f $(IPA) || { echo "EXPORT FAILED: no $(IPA)"; exit 1; }
	@ls -lh $(IPA)

# Upload only — reuses the IPA `make ipa` already produced. Useful when the
# archive is slow: build once, upload as many times as needed.
upload: check-asc
	@test -f $(IPA) || { echo "No IPA at $(IPA) — run 'make ipa' first"; exit 1; }
	IPA_PATH=$(abspath $(IPA)) \
	ASC_API_KEY_ID=$(ASC_API_KEY_ID) \
	ASC_API_ISSUER=$(ASC_API_ISSUER) \
	ASC_KEY_PATH=$(ASC_KEY_PATH) \
	fastlane ios upload
	@echo "→ Uploaded. Track processing: appstoreconnect.apple.com → My Apps → $(ASC_APP_NAME) → TestFlight"

tf: check-asc ipa upload

# Fails before the archive if this app's own App Store Connect credentials are
# missing. The drasif account's key belongs to a different team and cannot
# upload this app, so it is never a fallback here.
check-asc:
	@test -n "$(ASC_API_KEY_ID)" || { \
	  echo "ASC_API_KEY_ID is not set — this app needs an App Store Connect API key"; \
	  echo "from its own account (team $(TEAM_ID)), not the drasif account's."; \
	  echo "Usage: make tf BUILD=2 ASC_API_KEY_ID=<KEYID> ASC_API_ISSUER=<issuer-uuid>"; \
	  exit 1; }
	@test -n "$(ASC_API_ISSUER)" || { \
	  echo "ASC_API_ISSUER is not set (the issuer UUID from the ASC Integrations page)"; \
	  echo "Usage: make tf BUILD=2 ASC_API_KEY_ID=<KEYID> ASC_API_ISSUER=<issuer-uuid>"; \
	  exit 1; }
	@test -f "$(ASC_KEY_PATH)" || { \
	  echo "ASC key not found at $(ASC_KEY_PATH)"; \
	  echo "cp AuthKey_$(ASC_API_KEY_ID).p8 ~/.private_keys/ && chmod 600 ~/.private_keys/AuthKey_$(ASC_API_KEY_ID).p8"; \
	  exit 1; }

clean:
	rm -rf $(BUILD_DIR)
