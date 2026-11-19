#!/usr/bin/env bash
# KADMOS HMC App launcher (macOS / Linux):  ./kadmos_app.sh   (or: bash kadmos_app.sh)
#  - Uses Julia 1.11 (the version the app was built and tested with).
#  - If Julia 1.11 is not found, downloads it once into the "julia" folder next to this script
#    (about 250 MB, nothing is installed elsewhere on the computer).
#  - The first start installs the Julia packages (internet, several minutes).
cd "$(dirname "$0")" || exit 1
APP_DIR="$PWD"
JULIA_VERSION=1.11.9
CHANNEL=1.11

# Ready-made bundle (made with build_bundle.sh): use the packages shipped in ./depot.
# The trailing ":" keeps Julia's own standard-library caches.
if [ -d "$APP_DIR/depot" ]; then
  export JULIA_DEPOT_PATH="$APP_DIR/depot:"
fi

download_julia() {
  local url
  case "$(uname -s)" in
    Darwin)
      # Apple Silicon also when this shell runs under Rosetta
      if [ "$(uname -m)" = "arm64" ] || [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ]; then
        url="mac/aarch64/$CHANNEL/julia-$JULIA_VERSION-macaarch64.tar.gz"
      else
        url="mac/x64/$CHANNEL/julia-$JULIA_VERSION-mac64.tar.gz"
      fi ;;
    Linux)
      case "$(uname -m)" in
        x86_64)        url="linux/x64/$CHANNEL/julia-$JULIA_VERSION-linux-x86_64.tar.gz" ;;
        aarch64|arm64) url="linux/aarch64/$CHANNEL/julia-$JULIA_VERSION-linux-aarch64.tar.gz" ;;
        *) echo "Unsupported processor: $(uname -m). Install Julia $CHANNEL from https://julialang.org/downloads/"; return 1 ;;
      esac ;;
    *) echo "Unsupported system: $(uname -s)"; return 1 ;;
  esac
  url="https://julialang-s3.julialang.org/bin/$url"
  echo "Julia $CHANNEL was not found on this computer."
  echo "Downloading Julia $JULIA_VERSION into the app folder (about 250 MB, once)..."
  rm -rf "$APP_DIR/julia.download" && mkdir -p "$APP_DIR/julia.download" || return 1
  if ! curl -fL --progress-bar -o "$APP_DIR/julia.download/julia.tar.gz" "$url"; then
    echo "Download failed. Check the internet connection and run the app again."
    rm -rf "$APP_DIR/julia.download"; return 1
  fi
  echo "Unpacking..."
  if ! tar -xzf "$APP_DIR/julia.download/julia.tar.gz" -C "$APP_DIR/julia.download"; then
    echo "Could not unpack Julia."; rm -rf "$APP_DIR/julia.download"; return 1
  fi
  rm -rf "$APP_DIR/julia"
  mv "$APP_DIR/julia.download/julia-$JULIA_VERSION" "$APP_DIR/julia" && rm -rf "$APP_DIR/julia.download"
  echo "Julia $JULIA_VERSION is ready."
  echo
}

is_111() { "$@" --startup-file=no -e 'exit(VERSION.major == 1 && VERSION.minor == 11 ? 0 : 3)' >/dev/null 2>&1; }
# Name of a Julia 1.11 channel that Juliaup has already installed (asking `julia +1.11` directly would
# make Juliaup download it, or ask a question, when it is not installed)
juliaup_111() {
  command -v juliaup >/dev/null 2>&1 || return 1
  juliaup status 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^1\.11(\.[0-9]+)?$/) { print $i; exit } }'
}

export PATH="$PATH:$HOME/.juliaup/bin"
JUP_CHANNEL="$(juliaup_111)"
if [ -x "$APP_DIR/julia/bin/julia" ]; then
  JULIA=("$APP_DIR/julia/bin/julia")                       # downloaded earlier / bundled
elif [ -z "$KADMOS_LOCAL_JULIA" ] && [ -n "$JUP_CHANNEL" ] && is_111 julia +"$JUP_CHANNEL"; then
  JULIA=(julia +"$JUP_CHANNEL")                            # Juliaup that already has 1.11
elif [ -z "$KADMOS_LOCAL_JULIA" ] && command -v julia >/dev/null 2>&1 && is_111 julia; then
  JULIA=(julia)                                            # a Julia 1.11 on the PATH
else
  download_julia || { echo "Press Enter to close."; read -r _; exit 1; }
  JULIA=("$APP_DIR/julia/bin/julia")
fi

exec "${JULIA[@]}" --threads=auto,1 --project="$APP_DIR" "$APP_DIR/KADMOS_App.jl" "$@"
