#!/usr/bin/env bash
# Builds the release artifacts for BiblioJules on Android.
#
#   ./scripts/release.sh              # the app bundle the Play Store takes
#   ./scripts/release.sh --clean      # sweep build/ first, as after a framework bump
#   ./scripts/release.sh --apk        # also the split APKs, for handing to a phone
#
# Signing material lives in android/keys/, which is not in the repository;
# PUBLISHING.md explains how to create it and what the Console then wants.

set -euo pipefail

cd "$(dirname "$0")/.." # the mobile/ directory, from wherever this is run

clean=false
apk=false
for arg in "$@"; do
    case "$arg" in
        --clean) clean=true ;;
        --apk) apk=true ;;
        -h | --help)
            echo "usage: ./scripts/release.sh [--clean] [--apk]"
            exit 0
            ;;
        *)
            echo "unknown option: $arg"
            exit 1
            ;;
    esac
done

if ! command -v flutter >/dev/null; then
    echo "flutter is not on the path"
    exit 1
fi

# The Gradle release signing config reads these; without them the build would
# fail with a Gradle error that says nothing about the fix.
if [[ ! -f android/keys/keystore.properties || ! -f android/keys/upload-keystore.p12 ]]; then
    cat <<EOF
No signing key yet. Generate the upload keystore once per app:

    keytool -genkeypair -v \\
        -keystore android/keys/upload-keystore.p12 \\
        -storetype PKCS12 \\
        -alias bibliojules \\
        -keyalg RSA -keysize 2048 -validity 3650 \\
        -dname "CN=BiblioJules"

and write its two passwords and key name to android/keys/keystore.properties.
Both files stay out of the repository; see PUBLISHING.md.
EOF
    exit 1
fi

if [[ $clean == true ]]; then
    flutter clean
fi
flutter pub get

# pubspec.yaml holds the version as <version>+<build>; the build number is what
# the Play Console calls a release, and it has to be higher than the last one.
version=$(sed -n 's/^version: *\([0-9][0-9.]*+\([0-9][0-9]*\)\).*$/\1/p' pubspec.yaml)
echo "Building version ${version} (Play build number ${version#*+})"

# The Dart code is minified by R8 already; --obfuscate scrambles the Dart names
# too, and the symbols it splits off de-obfuscate a crash report later.
flutter build appbundle --release --obfuscate --split-debug-info=build/symbols

bundle=build/app/outputs/bundle/release/app-release.aab
echo
echo "App bundle: $(du -h "$bundle" | cut -f1) at $bundle"

if [[ $apk == true ]]; then
    # One APK per architecture, for a phone that is not coming from the Store.
    flutter build apk --split-per-abi --release
    echo
    echo "APKs: build/app/outputs/flutter-apk/"
fi
