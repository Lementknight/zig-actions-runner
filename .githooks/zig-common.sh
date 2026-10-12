# Shared by the Zig git hooks (sourced, not run). See README.md, "Git hooks".
# shellcheck shell=bash

root=$(git rev-parse --show-toplevel)

say() { printf 'zig-hooks: %s\n' "$*" >&2; }

# The Zig version CI uses, from .github/workflows/ci.yml.
ci_zig_version() {
	sed -n 's/^[[:space:]]*ZIG_VERSION:[[:space:]]*"\{0,1\}\([0-9][0-9.]*\)"\{0,1\}.*/\1/p' "$root/.github/workflows/ci.yml" | head -n 1
}

# Zig must be installed once Zig code changed; a different version than CI's is only a warning.
require_zig() {
	local want have
	want=$(ci_zig_version)
	if ! command -v zig >/dev/null 2>&1; then
		say "Zig code changed, but zig is not on PATH. Install Zig ${want:-(see .github/workflows/ci.yml)}, or skip once with --no-verify."
		exit 1
	fi
	have=$(zig version)
	if [ -n "$want" ] && [ "$have" != "$want" ]; then
		say "warning: zig $have here, CI uses $want; results may differ."
	fi
}

skip_hint() {
	say "to skip once: git $1 --no-verify (or SKIP_ZIG_HOOKS=1 git $1)"
}
