#!/usr/bin/env bash
#
# build-ota.sh -- OfficeAdmin Game ad-hoc OTA build + publish.
#
# Mirrors the canonical OfficeAdmin pipeline (officeadmin-books/ios-app/build-ota.sh),
# steps 7 (archive + ad-hoc sign) and 8 (publish to the oa-ota R2 bucket). The game
# is a plain native Xcode project, so the canonical script's Capacitor steps 2-6
# (cap copy/sync, pod install, preflight gate) do not apply. macOS build box only.
#
# It ALWAYS, IN ORDER:
#   1. keychain prep (aiva-build keychain)
#   2. clean unsigned Release build (generic iOS device)
#   3. stage the .app + embed the Ad Hoc provisioning profile
#   4. sign with the distribution cert carried by the profile (derived, not
#      hardcoded), minimal ad-hoc entitlements, --generate-entitlement-der
#   5. package the IPA
#   6. publish IPA + bumped manifest.plist to oa-ota R2 under game/ and verify
#      the public URLs return 200
#
# The Ad Hoc profile comes from `fastlane ios adhoc_profile` (sigh --adhoc, all
# devices -- Mike's iPhone). Signs with the Apple Distribution identity the
# profile carries; the cert SHA is derived from the profile's first
# DeveloperCertificate exactly like the canonical script, so a profile
# regenerated against another distribution cert still installs.
#
set -euo pipefail

# ---------------------------------------------------------------- paths
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo root
PROJ="$HERE/OfficeAdminGame.xcodeproj"
SCHEME="OfficeAdminGame"
BUILD="$HERE/build"

# ---------------------------------------------------------------- signing / publish config
TEAM_ID="${TEAM_ID:-6D4T7VB2AF}"
BUNDLE_ID="${BUNDLE_ID:-com.officeadmin.game}"
APP_TITLE="${APP_TITLE:-OfficeAdmin Game}"
BUILD_KC="${BUILD_KC:-$HOME/Library/Keychains/aiva-build.keychain-db}"
BUILD_KC_PW="${BUILD_KC_PW:-aiva-build-2026}"
ADHOC_PROFILE="${ADHOC_PROFILE:-$BUILD/OfficeAdminGame-AdHoc.mobileprovision}"
ADHOC_ENTITLEMENTS="${ADHOC_ENTITLEMENTS:-$BUILD/adhoc.entitlements.plist}"

# oa-ota R2 (CF account 8e83fee9 -- the one bound to the public r2.dev domain),
# same bucket/account/credential source as the canonical build-ota.sh.
R2_ACCOUNT="${R2_ACCOUNT:-8e83fee9ba5b2bf423d5ffddaaee74c6}"
R2_BUCKET="${R2_BUCKET:-oa-ota}"
R2_PUBLIC="${R2_PUBLIC:-https://pub-a13361910152405ab5b70b01e8f9426c.r2.dev}"
R2_PREFIX="${R2_PREFIX:-game}"
CF_EMAIL="${CF_EMAIL:-mikejshaffer@gmail.com}"

# nohup/non-interactive runs: pull the CF global key from ~/.zshrc if not in env
if [ -z "${CLOUDFLARE_API_KEY:-}" ] && [ -f "$HOME/.zshrc" ]; then
  eval "$(grep -m1 '^export CLOUDFLARE_API_KEY=' "$HOME/.zshrc" || true)"
fi
# CLOUDFLARE_API_KEY: global API key for the R2 REST API (worker secret store).

IPA="$BUILD/OfficeAdminGame-adhoc.ipa"
OUTAPP="$BUILD/OfficeAdminGame-adhoc.app"
DD="$BUILD/adhoc-derived"
VERSION_STAMP="$(date +%Y%m%d%H%M)"
BUILD_NUMBER="${BUILD_NUMBER:-$VERSION_STAMP}"
MARKETING_VERSION="${MARKETING_VERSION:-0.1.0}"

say()  { printf '\n=== %s ===\n' "$*"; }
die()  { printf '\nABORT: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ============================================================ 1. keychain prep
say "[1] keychain prep"
have xcodebuild || die "xcodebuild not found -- the build/sign/publish half MUST run on the macOS build box"
[ -f "$ADHOC_PROFILE" ] || die "ad-hoc provisioning profile not found: $ADHOC_PROFILE (run: fastlane ios adhoc_profile -- it carries Mike's device UDIDs)"
mkdir -p "$BUILD"
security list-keychains -d user -s "$BUILD_KC" "$HOME/Library/Keychains/login.keychain-db"
security default-keychain -d user -s "$BUILD_KC"
security unlock-keychain -p "$BUILD_KC_PW" "$BUILD_KC"
security set-key-partition-list -S apple-tool:,apple:,codesign: -k "$BUILD_KC_PW" "$BUILD_KC" >/dev/null 2>&1 || true
restore_kc() { security default-keychain -d user -s "$HOME/Library/Keychains/login.keychain-db"; }
trap restore_kc EXIT

# ============================================================ 2. clean unsigned Release build
say "[2] clean unsigned Release build (build $BUILD_NUMBER)"
rm -rf "$DD"
xcodebuild -project "$PROJ" -scheme "$SCHEME" -configuration Release \
  -destination "generic/platform=iOS" -derivedDataPath "$DD" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" MARKETING_VERSION="$MARKETING_VERSION" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build 2>&1 | tail -5
APPSRC="$DD/Build/Products/Release-iphoneos/OfficeAdminGame.app"
[ -d "$APPSRC" ] || die "unsigned build produced no OfficeAdminGame.app"

# ============================================================ 3. stage app + embed ad-hoc profile
say "[3] stage app + embed ad-hoc profile"
rm -rf "$OUTAPP"
cp -R "$APPSRC" "$OUTAPP"
cp "$ADHOC_PROFILE" "$OUTAPP/embedded.mobileprovision"

# Minimal ad-hoc entitlements (the game has no push/associated-domains/memory
# capabilities; those OfficeAdmin keys do not apply). codesign embeds EXACTLY
# this file's keys, so generate it fresh from the profile's own team + bundle id
# rather than committing a copy that can drift.
if [ ! -f "$ADHOC_ENTITLEMENTS" ]; then
  cat > "$ADHOC_ENTITLEMENTS" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>application-identifier</key><string>${TEAM_ID}.${BUNDLE_ID}</string>
  <key>com.apple.developer.team-identifier</key><string>${TEAM_ID}</string>
  <key>get-task-allow</key><false/>
</dict></plist>
ENT
  echo "  generated minimal ad-hoc entitlements: $ADHOC_ENTITLEMENTS"
fi

# Derive the codesign identity (cert SHA1) from the profile's first
# DeveloperCertificate, so the app is signed with a cert its OWN embedded
# profile actually contains (iOS rejects the install, 0xe8008015, otherwise).
# Same mechanism as the canonical build-ota.sh. Every call site is
# `$(cert_sha_for_profile … || true)` -- see the set -e note there.
cert_sha_for_profile() {
  [ -f "$1" ] || return 1
  /usr/bin/python3 - "$1" <<'PY'
import plistlib, hashlib, subprocess, sys
raw = subprocess.run(["security", "cms", "-D", "-i", sys.argv[1]], capture_output=True).stdout
try:
    d = plistlib.loads(raw)
    print(hashlib.sha1(bytes(d["DeveloperCertificates"][0])).hexdigest().upper())
except Exception:
    sys.exit(1)
PY
}

echo "  profile devices:"
security cms -D -i "$ADHOC_PROFILE" 2>/dev/null \
  | /usr/bin/python3 -c 'import plistlib,sys; d=plistlib.load(sys.stdin); devs=d.get("ProvisionedDevices",[]); print("    %d device(s)" % len(devs)); sys.exit(0 if devs else 1)' \
  || die "the ad-hoc profile ($ADHOC_PROFILE) contains NO devices -- Mike's iPhone must be in it. Re-run: fastlane ios adhoc_profile"

# ============================================================ 4. sign frameworks, extensions, app
say "[4] sign frameworks, then app extensions, then the app"
app_sign_cert="$(cert_sha_for_profile "$ADHOC_PROFILE" || true)"
[ -n "$app_sign_cert" ] || die "could not derive a signing cert from $ADHOC_PROFILE"
echo "    main-app/frameworks cert: $app_sign_cert (from $(basename "$ADHOC_PROFILE"))"
if [ -d "$OUTAPP/Frameworks" ]; then
  for fw in "$OUTAPP"/Frameworks/*.framework; do
    [ -d "$fw" ] || continue
    codesign --force --keychain "$BUILD_KC" --sign "$app_sign_cert" --timestamp=none "$fw"
  done
fi
# Embedded app extensions sign INSIDE-OUT (own profile + entitlements BEFORE the
# outer app). The game currently ships no PlugIns/; the loop is the canonical
# guard in case one is added.
if [ -d "$OUTAPP/PlugIns" ]; then
  die "the game now embeds app extensions -- each .appex needs its OWN ad-hoc profile (see the canonical build-ota.sh step 7.4); nothing was signed"
fi
codesign --force --keychain "$BUILD_KC" --sign "$app_sign_cert" --timestamp=none \
  --entitlements "$ADHOC_ENTITLEMENTS" --generate-entitlement-der "$OUTAPP"
codesign --verify --deep --strict "$OUTAPP" && echo "  codesign verify OK"

# ============================================================ 5. package IPA
say "[5] package IPA"
WORK="$(mktemp -d)"
mkdir -p "$WORK/Payload"
cp -R "$OUTAPP" "$WORK/Payload/OfficeAdminGame.app"
( cd "$WORK" && /usr/bin/zip -qry "$IPA" Payload )
rm -rf "$WORK"
ls -la "$IPA"

# ============================================================ 6. publish to oa-ota R2 (game/)
say "[6] publish to oa-ota R2 (${R2_BUCKET}/${R2_PREFIX}/, build $BUILD_NUMBER)"
: "${CLOUDFLARE_API_KEY:?CLOUDFLARE_API_KEY not set -- global CF API key for the R2 REST API (worker secret store)}"
have curl || die "curl not found"

MANIFEST="$BUILD/manifest.plist"
cat > "$MANIFEST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>items</key><array><dict>
  <key>assets</key><array><dict>
    <key>kind</key><string>software-package</string>
    <key>url</key><string>${R2_PUBLIC}/${R2_PREFIX}/OfficeAdminGame-adhoc.ipa</string>
  </dict></array>
  <key>metadata</key><dict>
    <key>bundle-identifier</key><string>${BUNDLE_ID}</string>
    <key>bundle-version</key><string>${BUILD_NUMBER}</string>
    <key>kind</key><string>software</string>
    <key>title</key><string>${APP_TITLE}</string>
  </dict>
</dict></array></dict></plist>
PLIST
if have plutil; then plutil -lint "$MANIFEST" >/dev/null || die "manifest.plist failed plutil lint"; fi

r2_put() {  # r2_put <local-file> <object-key> <content-type>
  local file="$1" key="$2" ctype="$3"
  echo "  PUT $key ($ctype)"
  curl -fsS -X PUT \
    -H "X-Auth-Email: ${CF_EMAIL}" \
    -H "X-Auth-Key: ${CLOUDFLARE_API_KEY}" \
    -H "Content-Type: ${ctype}" \
    --data-binary "@${file}" \
    "https://api.cloudflare.com/client/v4/accounts/${R2_ACCOUNT}/r2/buckets/${R2_BUCKET}/objects/${key}" \
    >/dev/null || die "R2 PUT failed for $key"
}

r2_put "$IPA"      "${R2_PREFIX}/OfficeAdminGame-adhoc.ipa" "application/octet-stream"
r2_put "$MANIFEST" "${R2_PREFIX}/manifest.plist"            "text/xml"

echo "  verify public URLs return 200:"
for path in "${R2_PREFIX}/manifest.plist" "${R2_PREFIX}/OfficeAdminGame-adhoc.ipa"; do
  code="$(curl -s -o /dev/null -w '%{http_code}' "${R2_PUBLIC}/${path}")"
  printf '    %-38s %s\n' "$path" "$code"
  [ "$code" = "200" ] || die "$path did not return 200 (got $code)"
done

say "DONE -- OfficeAdmin Game OTA build $BUILD_NUMBER published"
echo "Install link: itms-services://?action=download-manifest&url=${R2_PUBLIC}/${R2_PREFIX}/manifest.plist"
