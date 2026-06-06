.PHONY: certs app install clean

# Mint the self-signed signing cert and regenerate the pinned leaf hash.
certs:
	./scripts/gen-cert.sh

# Build + assemble + sign Sprout.app into build/.
app:
	./scripts/bundle.sh

# Build the app, then hand off to the user to install + approve the helper.
install: app
	@echo ""
	@echo "Built build/Sprout.app."
	@echo "1. Copy it to /Applications (or run it in place)."
	@echo "2. Launch it; the app registers the helper via SMAppService,"
	@echo "   triggering one admin auth prompt (Touch ID / password)."
	@echo "3. If status shows 'Needs approval', open System Settings >"
	@echo "   General > Login Items and enable Sprout."

clean:
	rm -rf build
