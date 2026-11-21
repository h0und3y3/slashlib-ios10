#!/bin/bash
# Запускать на macOS с Xcode:  brew install ldid dpkg  &&  ./build.sh
set -euo pipefail
cd "$(dirname "$0")"
export COPYFILE_DISABLE=1

APP=build/Slashlib.app
DEB_ROOT=build/deb
rm -rf build && mkdir -p "$APP"

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos swiftc Sources/*.swift \
  -module-name Slashlib -sdk "$SDK" -target arm64-apple-ios10.0 \
  -O -swift-version 5 \
  -Xlinker -rpath -Xlinker @executable_path/Frameworks \
  -o "$APP/Slashlib"

cp Resources/Info.plist "$APP/Info.plist"
cp Resources/Icons/*.png "$APP/"      # значок приложения
xcrun ibtool --compile "$APP/LaunchScreen.storyboardc" Resources/LaunchScreen.storyboard \
  --target-device iphone --target-device ipad --minimum-deployment-target 10.0 || true
# Swift-библиотеки внутрь приложения (на iOS 10 системных нет)
xcrun swift-stdlib-tool --copy --platform iphoneos \
  --scan-executable "$APP/Slashlib" --destination "$APP/Frameworks"

ldid -S "$APP/Slashlib"      # фейковая подпись для джейла

mkdir -p "$DEB_ROOT/Applications" "$DEB_ROOT/DEBIAN"
cp -R "$APP" "$DEB_ROOT/Applications/"
cp Resources/control Resources/postinst Resources/postrm "$DEB_ROOT/DEBIAN/"
chmod 755 "$DEB_ROOT/DEBIAN/postinst" "$DEB_ROOT/DEBIAN/postrm"
find "$DEB_ROOT" -name '.DS_Store' -delete

dpkg-deb --root-owner-group -Zgzip -b "$DEB_ROOT" build/ru.slashlib.client_0.7.0_iphoneos-arm.deb
echo "Готово: build/ru.slashlib.client_0.7.0_iphoneos-arm.deb"
