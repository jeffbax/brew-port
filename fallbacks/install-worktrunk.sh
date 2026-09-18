#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

exec "$script_dir/install-release-binary.sh" \
  worktrunk \
  max-sixty/worktrunk \
  worktrunk-x86_64-apple-darwin.tar.xz \
  wt
