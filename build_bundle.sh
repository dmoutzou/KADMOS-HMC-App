#!/usr/bin/env bash
# ============================================================================
#  Build a ready-to-run KADMOS HMC App bundle for THIS system (macOS or Linux).
#
#  Run it once on a computer of the kind you want to support (e.g. an Apple
#  Silicon Mac, an Intel Mac, a Linux PC):   bash build_bundle.sh
#
#  It downloads Julia 1.11 into ./julia, installs and precompiles every package
#  (including the figure packages) into ./depot, and zips the whole folder to
#  ../KADMOS_HMC_App-<system>.zip. Users unzip it and start the app: no Julia
#  download and no package installation, and it works without internet.
#  Windows bundles are made with build_bundle.bat on a Windows PC.
# ============================================================================
set -e
cd "$(dirname "$0")"
APP_DIR="$PWD"
NAME="KADMOS_HMC_App"

# JULIA_CPU_TARGET: compile the packages for a family of processors (as Julia itself is built), not only
# for the processor of this computer, so the bundle needs no recompilation on the users' computers.
X86_TARGET="generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)"
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)   PLATFORM=macOS-AppleSilicon; export JULIA_CPU_TARGET="apple-m1" ;;
  Darwin-x86_64)  PLATFORM=macOS-Intel;        export JULIA_CPU_TARGET="$X86_TARGET" ;;
  Linux-x86_64)   PLATFORM=Linux-x64;          export JULIA_CPU_TARGET="$X86_TARGET" ;;
  Linux-aarch64)  PLATFORM=Linux-arm64;        export JULIA_CPU_TARGET="generic" ;;
  *) echo "Unsupported system $(uname -s)-$(uname -m)"; exit 1 ;;
esac
# An empty home folder while building, so packages already in this computer's ~/.julia are not
# reused (they would then be missing from the bundle)
BUILD_HOME="$(mktemp -d)"; trap 'rm -rf "$BUILD_HOME"' EXIT
export HOME="$BUILD_HOME"
OUT="$(dirname "$APP_DIR")/$NAME-$PLATFORM.zip"

echo "Building $NAME for $PLATFORM"
mkdir -p "$APP_DIR/depot"          # the launcher uses ./depot when it exists
export KADMOS_LOCAL_JULIA=1        # always the app's own Julia in ./julia, never a system one
start=$(date +%s)
bash "$APP_DIR/kadmos_app.sh" --install-only
echo "Packages installed in $(( $(date +%s) - start )) s."

# Not needed in the bundle: logs, download caches, the old registry clone
rm -rf "$APP_DIR/depot/logs" "$APP_DIR/depot/scratchspaces"/*/downloads 2>/dev/null || true
rm -f "$APP_DIR/plots/install.log"

echo "Creating $OUT ..."
rm -f "$OUT"
# Copy into a folder named $NAME (on macOS a copy-on-write clone: instant, no extra disk space)
STAGE="$(mktemp -d)"; trap 'rm -rf "$BUILD_HOME" "$STAGE"' EXIT
cp -Rc "$APP_DIR" "$STAGE/$NAME" 2>/dev/null || cp -R "$APP_DIR" "$STAGE/$NAME"
rm -rf "$STAGE/$NAME/results" "$STAGE/$NAME/julia.download" "$STAGE/$NAME/PTt_params.dat" "$STAGE/$NAME/Custom_Diff.dat"
find "$STAGE/$NAME" -name .DS_Store -delete
# -y keeps the symbolic links inside Julia; permissions (executable scripts) are kept
(cd "$STAGE" && zip -ryq "$OUT" "$NAME")
echo "Done: $OUT ($(du -h "$OUT" | cut -f1))"
echo "Users unzip it and start the app as usual (see README.md)."
