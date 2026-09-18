#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

exec "$script_dir/install-release-binary.sh" \
  rtk \
  rtk-ai/rtk \
  rtk-x86_64-apple-darwin.tar.gz \
  rtk
