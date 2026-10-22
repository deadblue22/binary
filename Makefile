DIST := $(CURDIR)/dist

.PHONY: all server app ios test clean

all: server app

# binaryd (TypeScript, official Claude Agent SDK); run with server/bin/binaryd
server:
	cd server && npm install --no-audit --no-fund && npm run build

# dist/Binary.app
app:
	OUT=$(DIST) client/scripts/build-app.sh

# The iOS app, for the simulator (needs Xcode and xcodegen); see the README for devices.
ios:
	client/scripts/build-ios.sh

test:
	cd server && npm test
	cd client && swift build

clean:
	rm -rf $(DIST) client/.build server/dist client/iOS/build client/iOS/Binary.xcodeproj
