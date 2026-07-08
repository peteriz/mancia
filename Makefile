.PHONY: build test app release dmg run clean

SWIFT := ./scripts/swift.sh

build:
	$(SWIFT) build

test:
	$(SWIFT) test

app:
	./scripts/make_app.sh

release:
	@if [ -z "$(CODESIGN_ID)" ]; then echo 'error: set CODESIGN_ID="Developer ID Application: Your Name (TEAMID)" for release builds'; exit 1; fi
	REQUIRE_SIGNING=1 ./scripts/make_app.sh

dmg:
	./scripts/make_dmg.sh

run: app
	open build/Mancia.app

clean:
	$(SWIFT) package clean
	rm -rf build
