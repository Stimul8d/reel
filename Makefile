APP     := reel
BUILD   := build
SRC     := $(wildcard Sources/Reel/*.swift)
OVERLAY := $(BUILD)/overlay.yaml

# The CLT on this machine ships a stale 2023 module.modulemap next to
# bridging.modulemap in /Library/Developer/CommandLineTools/usr/include/swift.
# Both define SwiftBridging and every clang module build dies on the
# redefinition, behind a misleading "this SDK is not supported" line. This
# overlay swaps the stale file for an empty one at compile time. Map the single
# FILE, not the directory: a directory remap breaks SwiftShims lookup.
# Real fix (needs sudo): sudo mv $(STALE) ~/module.modulemap.bak
STALE   := /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
OVERLAY_FLAGS := $(if $(wildcard $(STALE)),-vfsoverlay $(OVERLAY) -Xcc -ivfsoverlay -Xcc $(abspath $(OVERLAY)),)

FLAGS := -O -swift-version 5 -parse-as-library -target arm64-apple-macosx26.0 \
         -module-cache-path $(BUILD)/modcache \
         -framework SwiftUI -framework AppKit -framework Speech \
         -framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia \
         -framework CoreImage -framework CoreText -framework VideoToolbox \
         $(OVERLAY_FLAGS)

BIN := $(BUILD)/$(APP)

$(BIN): $(SRC) $(OVERLAY)
	swiftc $(FLAGS) -o $@ $(SRC)

$(OVERLAY):
	@mkdir -p $(BUILD)
	@: > $(BUILD)/empty.modulemap
	@printf '{ "version": 0, "roots": [ { "name": "%s", "type": "file", "external-contents": "%s" } ] }\n' \
	  "$(STALE)" "$(abspath $(BUILD)/empty.modulemap)" > $@

build: $(BIN)

clean:
	rm -rf $(BUILD)

.PHONY: build clean

## bundle: a real .app, which this needs twice over. ScreenCaptureKit is gated
## behind Screen Recording, and TCC attributes a bare binary run from a terminal
## to the terminal app rather than to us.
##
## SIGN WITH A REAL IDENTITY, NOT AD-HOC. TCC pins its grant to the code
## requirement, and for an ad-hoc signature that requirement is the cdhash, which
## changes on every build, so every rebuild silently revokes screen recording.
## The only symptom is SCStream error -3801 "the user declined TCCs", a lie.
## The cert below is shared with Scribe; if it already exists this is a no-op.
##   make signing-identity   (once, per machine)
APPDIR    := $(BUILD)/Reel.app
INSTALLED := $(HOME)/Applications/Reel.app
IDENTITY  ?= Huntley Local Dev

bundle: $(BIN)
	@rm -rf $(APPDIR)
	@mkdir -p $(APPDIR)/Contents/MacOS $(APPDIR)/Contents/Resources
	@cp $(BIN) $(APPDIR)/Contents/MacOS/reel
	@cp Resources/Info.plist $(APPDIR)/Contents/Info.plist
	@$(BIN) --makeicon $(BUILD) >/dev/null
	@iconutil -c icns $(BUILD)/AppIcon.iconset -o $(APPDIR)/Contents/Resources/AppIcon.icns
	@codesign --force --options runtime --entitlements Resources/Reel.entitlements --sign "$(IDENTITY)" $(APPDIR) 2>/dev/null \
	  || { echo "no '$(IDENTITY)' identity: run make signing-identity"; exit 1; }
	@echo "built $(APPDIR)"

## install: TCC keys on where the app lives, so it needs one home.
install: bundle
	@mkdir -p $(HOME)/Applications
	@pkill -f "Reel.app/Contents/MacOS/reel" 2>/dev/null || true
	@rm -rf $(INSTALLED)
	@cp -R $(APPDIR) $(INSTALLED)
	@echo "installed $(INSTALLED)"

## signing-identity: a self-signed code signing cert, so TCC grants survive rebuilds
signing-identity:
	@security find-identity -v -p codesigning | grep -q "$(IDENTITY)" && echo "already have '$(IDENTITY)'" && exit 0 || true
	@tmp=$$(mktemp -d); \
	printf '[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=%s\nO=huntley.house\n[v3]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' "$(IDENTITY)" > $$tmp/c.cnf; \
	openssl req -x509 -newkey rsa:2048 -keyout $$tmp/k.pem -out $$tmp/c.pem -days 3650 -nodes -config $$tmp/c.cnf 2>/dev/null; \
	openssl pkcs12 -export -out $$tmp/i.p12 -inkey $$tmp/k.pem -in $$tmp/c.pem -passout pass:x -name "$(IDENTITY)" 2>/dev/null; \
	security import $$tmp/i.p12 -k $(HOME)/Library/Keychains/login.keychain-db -P x -T /usr/bin/codesign >/dev/null; \
	security add-trusted-cert -r trustRoot -p codeSign -k $(HOME)/Library/Keychains/login.keychain-db $$tmp/c.pem; \
	rm -rf $$tmp
	@security find-identity -v -p codesigning

## run: launch the installed app but keep its output in this terminal.
## -n is required: without it open refuses args when an instance is running.
ARGS ?=
run: install
	open -n -W $(INSTALLED) --stdout $$(tty) --stderr $$(tty) --args $(ARGS)

probe: $(BIN)
	$(BIN) --probe

.PHONY: bundle install signing-identity run probe
