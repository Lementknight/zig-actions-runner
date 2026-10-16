#!/bin/sh
# Type-checks the model of the step cache. Needs only Agda (brew install agda):
# there is no standard library to install, and every module is --safe, so a
# clean run is a complete proof of what the modules state.
set -e
cd "$(dirname "$0")"
exec agda -i . Everything.agda "$@"
