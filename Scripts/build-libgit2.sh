#!/bin/bash
# Builds libgit2 as a universal static xcframework for bundling into Beckit.
#
# Why bundle it at all: the process-based git backend needs /usr/bin/git, which
# on a clean Mac is a stub that pops the "install command line developer tools"
# dialog the first time a writer syncs. Bundling libgit2 removes that dependency
# entirely — the app carries its own git.
#
# Run this once; the output is committed as a binary artifact or rebuilt in CI.
#
# Requires: cmake (brew install cmake)
# Usage: Scripts/build-libgit2.sh [version]

set -euo pipefail

VERSION="${1:-v1.9.0}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Vendor"
SOURCE="$VENDOR/libgit2"
DEPLOYMENT_TARGET="26.0"

if ! command -v cmake >/dev/null 2>&1; then
    echo "error: cmake is required. Install it with: brew install cmake" >&2
    exit 1
fi

mkdir -p "$VENDOR"

if [ ! -d "$SOURCE" ]; then
    git clone --depth 1 --branch "$VERSION" \
        https://github.com/libgit2/libgit2.git "$SOURCE"
else
    git -C "$SOURCE" fetch --depth 1 origin "$VERSION"
    git -C "$SOURCE" checkout --quiet FETCH_HEAD
fi

# Build one slice per architecture, then lipo them together. Beckit ships
# universal so a single download runs on both Apple silicon and Intel.
SLICES=()
for ARCH in arm64 x86_64; do
    BUILD="$VENDOR/build-$ARCH"
    rm -rf "$BUILD"

    cmake -S "$SOURCE" -B "$BUILD" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTS=OFF \
        -DBUILD_CLI=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DUSE_SSH=OFF \
        -DREGEX_BACKEND=regcomp_l \
        -DUSE_HTTPS=SecureTransport \
        -DUSE_SHA1=CollisionDetection \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON

    cmake --build "$BUILD" --config Release --parallel
    SLICES+=("$BUILD/libgit2.a")
done

UNIVERSAL="$VENDOR/libgit2-universal.a"
lipo -create "${SLICES[@]}" -output "$UNIVERSAL"

rm -rf "$VENDOR/libgit2.xcframework"
xcodebuild -create-xcframework \
    -library "$UNIVERSAL" \
    -headers "$SOURCE/include" \
    -output "$VENDOR/libgit2.xcframework"

rm -f "$UNIVERSAL"
rm -rf "$VENDOR/build-arm64" "$VENDOR/build-x86_64"

echo
echo "Built $VENDOR/libgit2.xcframework"
echo "Architectures: $(lipo -archs "$VENDOR/libgit2.xcframework"/*/libgit2.a 2>/dev/null || echo 'see xcframework')"
echo
echo "Next: add it to Package.swift as a binaryTarget and make BeckitGit depend"
echo "on it, then implement LibGit2Repository against the GitRepository protocol."
