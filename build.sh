#!/bin/bash
# EasyPort.app을 빌드한다.
#   ./build.sh            현재 아키텍처로 build/EasyPort.app 생성
#   ./build.sh install    빌드 후 ~/Applications에 복사하고 실행
#   ./build.sh release    arm64와 x86_64 유니버설로 빌드하고 build/EasyPort.zip 생성.
#                         VERSION 환경 변수가 있으면 앱 버전으로 쓴다 (예: VERSION=0.2.0).
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"
APP=build/EasyPort.app

if [ "$MODE" = "release" ]; then
    # Command Line Tools에는 xcbuild가 없어 --arch를 여러 개 줄 수 없으므로 아키텍처별로 빌드해 합친다.
    for arch in arm64 x86_64; do
        swift build -c release --triple "$arch-apple-macosx14.0"
    done
    mkdir -p build
    lipo -create -output build/EasyPort \
        .build/arm64-apple-macosx/release/EasyPort \
        .build/x86_64-apple-macosx/release/EasyPort
    BINARY=build/EasyPort
else
    swift build -c release
    BINARY=.build/release/EasyPort
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/EasyPort"
cp Resources/Info.plist "$APP/Contents/"
if [ -n "${VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
codesign --force --sign - "$APP"
echo "빌드 완료: $APP ($(lipo -archs "$APP/Contents/MacOS/EasyPort"))"

case "$MODE" in
    install)
        DEST="$HOME/Applications/EasyPort.app"
        pkill -x EasyPort 2>/dev/null && sleep 1 || true
        rm -rf "$DEST"
        mkdir -p "$HOME/Applications"
        cp -R "$APP" "$DEST"
        open "$DEST"
        echo "설치 및 실행: $DEST"
        ;;
    release)
        rm -f build/EasyPort.zip
        ditto -c -k --keepParent "$APP" build/EasyPort.zip
        echo "배포 파일: build/EasyPort.zip"
        ;;
esac
