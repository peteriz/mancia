.PHONY: build test app run clean

build:
	swift build

test:
	swift test

app:
	./scripts/make_app.sh

run: app
	open build/AI-Edit.app

clean:
	swift package clean
	rm -rf build
