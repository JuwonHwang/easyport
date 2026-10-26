#!/bin/bash
# EasyPort.app을 빌드한다. `./build.sh install`은 ~/Applications에 복사하고 실행한다.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/EasyPort.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/EasyPort "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
echo "빌드 완료: $APP"

if [ "${1:-}" = "install" ]; then
    DEST="$HOME/Applications/EasyPort.app"
    pkill -x EasyPort 2>/dev/null && sleep 1 || true
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    open "$DEST"
    echo "설치 및 실행: $DEST"
fi
