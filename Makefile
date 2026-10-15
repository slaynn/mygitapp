.PHONY: build test app run debug install update icon clean

build:
	swift build

test:
	swift test

app:
	scripts/bundle.sh release

run: app
	open build/MyGitApp.app

# Faster iteration: debug build, launched from the bundle.
debug:
	scripts/bundle.sh debug
	open build/MyGitApp.app

install: app
	rm -rf /Applications/MyGitApp.app
	cp -R build/MyGitApp.app /Applications/

# Latest release built by GitHub Actions, without compiling locally.
update:
	scripts/install-latest.sh

icon:
	rm -f assets/AppIcon.icns
	scripts/bundle.sh debug

clean:
	rm -rf .build build
