#!/bin/sh
# Type-checks the model of the step cache. Every module is --safe and nothing here uses the standard
# library, so a clean run is a complete proof of what the modules state.
#
# Agda's version matters: constructs that one release accepts another rejects, so CI pins one
# (AGDA_VERSION in .github/workflows/ci.yml) and this script prefers the same one. It takes the first
# of $AGDA, `agda-<pinned version>` on PATH, or `agda`, and says which it used.
set -eu
cd "$(dirname "$0")"

want=$(sed -n 's/^[[:space:]]*AGDA_VERSION:[[:space:]]*"\{0,1\}\([0-9][0-9.]*\)"\{0,1\}.*/\1/p' \
	../.github/workflows/ci.yml | head -n 1)

if [ -n "${AGDA:-}" ]; then
	agda=$AGDA
elif [ -n "$want" ] && command -v "agda-$want" > /dev/null 2>&1; then
	agda="agda-$want"
elif command -v agda > /dev/null 2>&1; then
	agda=agda
else
	echo "proofs: no agda on PATH. Install Agda ${want:-(see .github/workflows/ci.yml)}; proofs/README.md says how to get the pinned build." >&2
	exit 1
fi

have=$("$agda" --version 2>/dev/null | sed -n '1s/^Agda version \([0-9][0-9.]*\).*/\1/p')
if [ -n "$want" ] && [ "$have" != "$want" ]; then
	echo "proofs: warning: agda $have here, CI pins $want; results may differ." >&2
fi

echo "proofs: checking with $agda ($have)" >&2
exec "$agda" -i . Everything.agda "$@"
