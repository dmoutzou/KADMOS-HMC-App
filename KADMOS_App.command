#!/bin/bash
# macOS: double-click this file to start the KADMOS HMC App (it opens a Terminal window).
# The first time, macOS may ask for permission: see "Starting on macOS" in README.md.
cd "$(dirname "$0")" || exit 1
bash ./kadmos_app.sh "$@"
status=$?
if [ $status -ne 0 ]; then echo; echo "The app stopped (code $status). Press Enter to close this window."; read -r _; fi
exit $status
