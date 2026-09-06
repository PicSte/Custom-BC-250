#!/usr/bin/env bash
#
# Lint everything shellcheck can reach. Used by CI and by hand.

set -euo pipefail
cd -- "$(dirname -- "$(readlink -f -- "$0")")/.."

status=0

echo "==> bc250ctl, libraries, modules"
shellcheck -x -e SC1091 bc250ctl install.sh lib/*.sh modules/*.sh || status=1

echo "==> data files"
shellcheck -s bash sources.env profiles/*.env || status=1

echo "==> tests and mocks"
shellcheck -e SC1091 tests/helper.bash tests/lint.sh || status=1
shellcheck tests/mocks/* || status=1

exit "$status"
