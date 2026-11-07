#!/usr/bin/env sh
# Builds the Cocoon DevTools extension (a Flutter web app) and copies the
# compiled output into the cocoon package, next to its config.yaml, so the
# built extension ships with the package DevTools discovers.
set -e
cd "$(dirname "$0")/.."
flutter pub get
dart run devtools_extensions build_and_copy --source=. --dest=../cocoon/extension/devtools
dart run devtools_extensions validate --package=../cocoon
