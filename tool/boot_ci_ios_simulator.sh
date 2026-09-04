#!/bin/sh

set -eu

simulator_id=$(
  xcrun simctl list devices booted |
    sed -n 's/.*(\([0-9A-F-][0-9A-F-]*\)) (Booted).*/\1/p' |
    head -n 1
)

if [ -z "$simulator_id" ]; then
  simulator_id=$(
    xcrun simctl list devices available |
      sed -n 's/.*iPhone.*(\([0-9A-F-][0-9A-F-]*\)) (Shutdown).*/\1/p' |
      head -n 1
  )
  if [ -z "$simulator_id" ]; then
    echo "No available iPhone Simulator was found." >&2
    exit 1
  fi
  xcrun simctl boot "$simulator_id" >&2
fi

xcrun simctl bootstatus "$simulator_id" -b >&2
printf '%s\n' "$simulator_id"
