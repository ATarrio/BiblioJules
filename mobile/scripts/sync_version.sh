#!/usr/bin/env bash
# Regenerates lib/src/core/version.g.dart from the version in pubspec.yaml.
#
# The About screen reads kAppVersion from that generated file, so run this
# whenever the version (or build number) in pubspec.yaml changes. The release
# script calls it automatically; `flutter test test/version_test.dart` fails if
# the two ever drift apart.
set -euo pipefail

cd "$(dirname "$0")/.." # the mobile/ directory, from wherever this is run

# pubspec.yaml holds the version as <version>[+<build>]; the About screen shows
# only the semantic part, without the Play build number.
version=$(sed -n 's/^version: *\([0-9][0-9.]*\)\(+[0-9][0-9]*\)\{0,1\}.*$/\1/p' pubspec.yaml)

if [[ -z "$version" ]]; then
    echo "could not read version from pubspec.yaml" >&2
    exit 1
fi

cat > lib/src/core/version.g.dart <<EOF
// This file is generated from pubspec.yaml by scripts/sync_version.sh.
// Do not edit by hand.

const String kAppVersion = '$version';
EOF

echo "version.g.dart: ${version}"
