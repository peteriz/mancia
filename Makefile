.PHONY: build test app release dmg run rerun shot clean

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

# Quit, reset the Accessibility grant, rebuild, and relaunch.
rerun:
	./scripts/rebuild_and_run.sh

# Redraw the README's hero image from the shipping ribbon view.
shot:
	$(SWIFT) run Mancia --shoot docs/assets/mancia-ribbon.png

clean:
	$(SWIFT) package clean
	rm -rf build
