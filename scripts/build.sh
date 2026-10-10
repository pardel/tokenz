#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
build_dir="${TOKENZ_BUILD_DIR:-$PWD/.build}"
export CLANG_MODULE_CACHE_PATH="$build_dir/clang-cache"
./scripts/build-icon.sh
swift build -c release --arch arm64 --arch x86_64 --disable-sandbox --scratch-path "$build_dir" --cache-path "$build_dir/cache"
app="$PWD/dist/Tokenz.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
binary_dir="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path --scratch-path "$build_dir" --cache-path "$build_dir/cache")"
cp "$binary_dir/Tokenz" "$app/Contents/MacOS/Tokenz"
# The Info.plist is the Xcode one (project.yml) with its build settings resolved.
setting() { sed -n "s/^ *$1: *//p" project.yml | head -1 }
sed -e 's/$(DEVELOPMENT_LANGUAGE)/en/' -e 's/$(PRODUCT_NAME)/Tokenz/g' -e 's/$(EXECUTABLE_NAME)/Tokenz/' \
    -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/dev.pardel.tokenz/' -e "s/\$(MARKETING_VERSION)/$(setting MARKETING_VERSION)/" \
    -e "s/\$(CURRENT_PROJECT_VERSION)/$(setting CURRENT_PROJECT_VERSION)/" \
    -e "s/\$(MACOSX_DEPLOYMENT_TARGET)/$(setting macOS | tr -d '\"')/" Resources/Info.plist > "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp scripts/tokenz-statusline.sh "$app/Contents/Resources/tokenz-statusline.sh"
codesign --force --sign - "$app"
print "Built $app"
