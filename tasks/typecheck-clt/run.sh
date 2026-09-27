#!/bin/bash
# Typecheck the whole Codenotch module with the Command Line Tools alone.
#
# Not a substitute for `make test` — it compiles, it does not run anything, and
# it cannot build the app: the Command Line Tools ship no `actool`, no
# `xcodebuild` and no XCTest (`swift test` fails with "no such module
# 'XCTest'"). It exists because Xcode did not fit on the machine this was
# written on, and a per-file `swiftc -parse` misses exactly the errors that
# matter — a call site referring to something out of scope typechecks fine on
# its own and fails the moment the module is assembled.
#
# Five files are left out because they cannot be fed to `swiftc` without the
# package graph Xcode resolves: four import Sparkle or SwiftNIO, one reaches
# the vendored zstd decoder through the bridging header. `stubs.swift` stands
# in for the handful of symbols the other 193 refer to across that seam — so a
# change to any of those five is invisible here and needs a real build.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT" || exit 1

SDK=$(xcrun --sdk macosx --show-sdk-path) || exit 1
LIST="$HERE/.files.txt"
find Sources -name '*.swift' \
  ! -path 'Sources/App/Updater.swift' \
  ! -path 'Sources/PhoneLink/PhoneLinkServer.swift' \
  ! -path 'Sources/PhoneLink/PhoneLinkRequestHandler.swift' \
  ! -path 'Sources/Sessions/OllamaRelayServer.swift' \
  ! -path 'Sources/Providers/ClaudeDesktopUsageCache.swift' > "$LIST"
echo "$HERE/stubs.swift" >> "$LIST"

OUT="$HERE/.out.txt"
swiftc -typecheck -sdk "$SDK" -target arm64-apple-macos15.0 @"$LIST" 2>"$OUT"
errors=$(grep -cE "^[^ ]*:[0-9]+:[0-9]+: error:" "$OUT")
echo "fichiers : $(wc -l < "$LIST" | tr -d ' ')   erreurs : $errors"
grep -E "^[^ ]*:[0-9]+:[0-9]+: error:" "$OUT" | sort -u
[ "$errors" -eq 0 ]
