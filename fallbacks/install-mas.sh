#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
destination="${MACPORTS_BREWFILE_MAS_DESTINATION:-/usr/local/bin/mas}"

exec "$script_dir/install-release-binary.sh" \
  mas \
  mas-cli/mas \
  'mas-{version}-x86_64.pkg' \
  package \
  "$destination"
