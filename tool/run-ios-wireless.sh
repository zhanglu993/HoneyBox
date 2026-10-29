#!/bin/sh
# Flutter 3.47.0 requires flutter-3.47.0-ios-wireless.patch for CoreDevice
# discovery to honor this port instead of matching the iPhone display name.
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$task_root"
exec env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  -u http_proxy -u https_proxy -u all_proxy \
  flutter run --debug --device-vmservice-port 54321 "$@"
