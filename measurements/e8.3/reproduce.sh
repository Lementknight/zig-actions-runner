#!/bin/sh
# E8.3: did pytest-testmon miss a leaf-module edit, or does no test cover it?
#
#   reproduce.sh <workdir>
#
# Unlike every other script here this takes no reading and dispatches no job. E8.3 is not a
# measurement — it asks which of two mechanisms produced an observation, and the answer is a
# selection count, which is the same on any machine. So it runs locally, and it runs the suite four
# times: once to build testmon's database, once unchanged, once after editing a function the suite
# demonstrably calls, and once after editing a function the suite never executes.
#
# Needs a native python3.12+ (an x86_64 interpreter under Rosetta will not load the arm64 extensions
# an editable install builds) and about four minutes.
set -eu
work=${1:?workdir}
ref=7b95e267c867f9e35ee0aba7e637f373522b0e1d
py=${PYTHON:-python3.12}

mkdir -p "$work/src"
cd "$work/src"
[ -d .git ] || git clone -q https://github.com/sqlalchemy/sqlalchemy.git .
git fetch -q --depth 1 origin "$ref" 2> /dev/null || true
git checkout -q "$ref" 2> /dev/null || echo "reproduce: could not pin $ref, using $(git rev-parse --short HEAD)" >&2

cd "$work"
[ -d venv ] || "$py" -m venv venv
./venv/bin/pip -q install "pytest>=7,<10" pytest-xdist pytest-testmon greenlet typing-extensions coverage
./venv/bin/pip -q install -e ./src

# Two paths, so every use of it below must word-split; that is why they are unquoted.
suite="test/base test/sql"
run() { # $1 = what this run is
	printf '\n=== %s ===\n' "$1"
	# shellcheck disable=SC2086 # $suite is two paths and has to split
	(cd src && ../venv/bin/python -m pytest --testmon -q $suite 2>&1 |
		grep -E "selected|passed|deselected in" | tail -2)
}

# `edit <function> <comment>` inserts a statement at the top of a function's body, which changes the
# code block testmon hashes. Not a comment: testmon ignores those, and a change it ignores would
# prove nothing.
edit() {
	( cd src && ../venv/bin/python -I -c "
import sys
p = 'lib/sqlalchemy/util/langhelpers.py'
s = open(p).read()
sig = sys.argv[1]
assert sig in s, sig + ' not found: the file has moved on'
open(p, 'w').write(s.replace(sig, sig + chr(10) + '    _e83_probe = 1  # ' + sys.argv[2], 1))
" "$1" "$2" )
}
revert() { git -C src checkout -- lib/sqlalchemy/util/langhelpers.py; }

revert
run "first run, building testmon's database"
run "again, nothing changed"

# find_matching_paren is called directly by test/base/test_utils.py, so a test covers it.
edit 'def find_matching_paren(text: str, start: int = 0) -> Optional[int]:' 'covered function'
run "after editing a COVERED function in the leaf module"
revert
run "resync after the revert"

# asbool is in the same file and no test in test/base or test/sql executes it.
edit 'def asbool(obj: Any) -> bool:' 'uncovered function'
run "after editing an UNCOVERED function in the same leaf module"
revert

# And the figure that makes the second result unsurprising: how much of the file the suite misses.
printf '\n=== how much of langhelpers.py the suite never executes ===\n'
# shellcheck disable=SC2086 # $suite is two paths and has to split
(cd src && ../venv/bin/python -m coverage run --include="*/util/langhelpers.py" \
	-m pytest -q -p no:cacheprovider $suite > /dev/null 2>&1
../venv/bin/python -I -c "
import ast, json, subprocess
out = subprocess.run(['../venv/bin/python','-m','coverage','json','-o','-',
                      '--include','*/util/langhelpers.py'], capture_output=True, text=True)
f = [v for k, v in json.loads(out.stdout)['files'].items() if k.endswith('langhelpers.py')][0]
executed = set(f['executed_lines'])
tree = ast.parse(open('lib/sqlalchemy/util/langhelpers.py').read())
cov = unc = 0
for n in ast.walk(tree):
    if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)):
        body = [x.lineno for x in ast.walk(n) if hasattr(x, 'lineno') and x.lineno > n.lineno]
        if not body:
            continue
        if any(l in executed for l in body):
            cov += 1
        else:
            unc += 1
print(f'{unc} of {cov + unc} functions are never executed by the suite')
")
revert
