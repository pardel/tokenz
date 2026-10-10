#!/bin/zsh
# Cut a Homebrew release: a GitHub release on this repo with the zip
# attached, and the cask in pardel/homebrew-tap pointing at it.
#
#   scripts/release.sh            zip the stapled dist/Tokenz.app, compute the
#                                 sha256, write Casks/tokenz.rb in the tap checkout
#   scripts/release.sh --publish  also create the GitHub release v<version> on
#                                 pardel/tokenz with the zip, commit the cask and push
#
# Before this: Xcode > Product > Archive, Organizer > Distribute App >
# Direct Distribution, and export the notarised app into dist/. It refuses
# an unstapled app: a zip that Gatekeeper rejects is worse than no release.
#
#   TOKENZ_APP  the exported app, default dist/Tokenz.app
#   TOKENZ_TAP  the homebrew-tap checkout, default ../homebrew-tap
set -euo pipefail
cd "${0:A:h:h}"

APP="${TOKENZ_APP:-dist/Tokenz.app}"
REPO="pardel/tokenz"
TAP="${TOKENZ_TAP:-../homebrew-tap}"
VERSION="$(sed -n 's/^ *MARKETING_VERSION: *//p' project.yml | head -1)"
TAG="v$VERSION"
ZIP="dist/Tokenz-$VERSION.zip"
CASK="$TAP/Casks/tokenz.rb"

test -d "$APP" || { print -u2 "no $APP; export a notarised build from the Xcode Organizer into dist/"; exit 1; }
test -d "$TAP/Casks" || { print -u2 "no tap checkout at $TAP (set TOKENZ_TAP)"; exit 1; }
built="$(defaults read "${APP:A}/Contents/Info.plist" CFBundleShortVersionString)"
[[ $built == "$VERSION" ]] || { print -u2 "$APP is $built, project.yml says $VERSION; archive again"; exit 1; }
grep -q "^## $VERSION " CHANGELOG.md || { print -u2 "CHANGELOG.md has no '## $VERSION ' section"; exit 1; }
xcrun stapler validate "$APP" >/dev/null 2>&1 || { print -u2 "$APP is not stapled; export a notarised build from the Xcode Organizer into dist/"; exit 1; }
spctl -a -t exec "$APP" 2>/dev/null || { print -u2 "Gatekeeper rejects $APP"; exit 1; }

mkdir -p dist
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$SHA/" packaging/tokenz.rb.template > "$CASK"

print "version: $VERSION"
print "sha256:  $SHA"
print "url:     https://github.com/$REPO/releases/download/$TAG/Tokenz-$VERSION.zip"
print "zip:     $ZIP"
print "cask:    $CASK"
(cd "$TAP" && git --no-pager diff --stat -- Casks/tokenz.rb)

if [[ "${1:-}" != "--publish" ]]; then
    print "dry run. To publish: scripts/release.sh --publish"
    exit 0
fi

# The release hangs off the version tag, which must already be on GitHub.
git ls-remote --exit-code --tags origin "$TAG" >/dev/null || { print -u2 "tag $TAG is not on origin; git push origin $TAG first"; exit 1; }
# Release notes: this version's section of CHANGELOG.md.
NOTES="$(awk -v v="## $VERSION " 'index($0, v) == 1 {on = 1; next} /^## / {on = 0} on' CHANGELOG.md)"
print "== creating release $TAG on $REPO"
gh release create "$TAG" "$ZIP" --repo "$REPO" --title "Tokenz $VERSION" --notes "$NOTES"
print "== committing and pushing the cask"
(cd "$TAP" && git add Casks/tokenz.rb && git commit -m "tokenz $VERSION" && git push)
print "released: brew install pardel/tap/tokenz   (brew upgrade tokenz for existing installs)"
