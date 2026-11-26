# DiskVitals Swift 앱을 빌드하고 .app 묶음으로 만드는 Makefile
.PHONY: all build app run clean

all: app

build:
	swift build -c release

app:
	./build-app.sh

run: build
	$$(swift build -c release --show-bin-path)/DiskVitals

clean:
	rm -rf .build build bin DiskVitals.app DiskVitals.dmg
