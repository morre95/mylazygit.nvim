#!/bin/sh
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
export NVIM_LOG_FILE="$test_dir/nvim.log"
# Isolate fixtures from global signing, hooks, aliases, rerere and Git context.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_CONFIG GIT_CONFIG_COUNT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
nvim --headless -u NONE -i NONE -c "lua dofile('tests/repository_session.lua')"
