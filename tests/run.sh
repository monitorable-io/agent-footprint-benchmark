#!/usr/bin/env bash
# The whole test suite: shellcheck on every shell file, then the Python unit tests.
set -euo pipefail
cd "$(dirname "$0")/.."
shopt -s nullglob
files=(lib/*.sh base/*.sh agents/*/install.sh sink/*.sh load/*.sh tests/*.sh)
[[ -f bench ]] && files+=(bench)
if ((${#files[@]})); then
  shellcheck -x "${files[@]}"
  echo "shellcheck: ${#files[@]} files clean"
fi
if compgen -G "tests/test_*.py" > /dev/null; then
  python3 -I -m unittest discover -s tests -v
else
  echo "0 tests"
fi
