.PHONY: build test app run clean

build:
	swift build

test:
	scripts/test.sh

app:
	scripts/build-app.sh

run: app
	open "build/L’Atelier.app"

clean:
	rm -rf .build build
