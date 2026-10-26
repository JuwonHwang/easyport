#!/bin/bash
# EasyPort 설치 스크립트.
#   curl -fsSL https://raw.githubusercontent.com/JuwonHwang/easyport/main/install.sh | bash
# GitHub Releases의 최신 EasyPort.zip을 받아 ~/Applications에 설치하고 실행한다.
# EASYPORT_ZIP 환경 변수에 로컬 zip 경로를 주면 내려받지 않고 그 파일로 설치한다.
set -euo pipefail

REPO="JuwonHwang/easyport"
URL="https://github.com/$REPO/releases/latest/download/EasyPort.zip"
DEST="$HOME/Applications/EasyPort.app"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "EasyPort는 macOS에서만 실행돼요." >&2
    exit 1
fi
major=$(sw_vers -productVersion | cut -d. -f1)
if [ "$major" -lt 14 ]; then
    echo "EasyPort는 macOS 14 이상이 필요해요. 현재 버전: $(sw_vers -productVersion)" >&2
    exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [ -n "${EASYPORT_ZIP:-}" ]; then
    cp "$EASYPORT_ZIP" "$tmp/EasyPort.zip"
else
    echo "내려받는 중: $URL"
    curl -fsSL "$URL" -o "$tmp/EasyPort.zip"
fi
ditto -x -k "$tmp/EasyPort.zip" "$tmp"
if [ ! -d "$tmp/EasyPort.app" ]; then
    echo "zip 안에 EasyPort.app이 없어요." >&2
    exit 1
fi

# 실행 중이면 종료한다. EasyPort는 종료할 때 자신이 띄운 포워딩용 ssh도 정리한다.
if pgrep -x EasyPort >/dev/null; then
    pkill -x EasyPort || true
    sleep 1
fi

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
mv "$tmp/EasyPort.app" "$DEST"
# 브라우저로 받은 zip을 직접 넘긴 경우를 대비해 격리 속성을 지운다.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

open "$DEST"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$DEST/Contents/Info.plist")
echo "EasyPort $version 설치 완료: $DEST"
echo "메뉴바의 네트워크 아이콘을 눌러 시작해요."
