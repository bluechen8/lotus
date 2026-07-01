#!/usr/bin/env bash

# $lic$
# Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
#
# This file is part of Lotus. Lotus is free software; you can redistribute it
# and/or modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation, version 2.

set -u

freqs=(180)

pids=()
fail=0

launch() {
  log="$1"
  shift

  (
    echo "=== Starting $log ==="
    time scons -j60 "$@"
  ) > "${log}.log" 2>&1 &

  pids+=($!)
  echo "Launched $log (pid=$!)"
}

for freq in "${freqs[@]}"; do
  for tiles in 1 4 8 32 36; do
    args=(
      --cfg=serial
      --tiles="$tiles"
      --coresPerTile=8
      --devices=8
      --frequency="$freq"
      --tasksPerTile=2048
    )

    launch "launched_build_t${tiles}_c8_f${freq}" "${args[@]}" hw-xclbin
  done

  for sw in 2 4; do
    launch "build_t64_c4_f${freq}_sw${sw}" \
      --cfg=serial \
      --tiles=64 \
      --coresPerTile=4 \
      --devices=8 \
      --frequency="$freq" \
      --tasksPerTile=1024 \
      --tilesPerSwitchPort="$sw" \
      --tilesPerMemChannel=2 \
      --l2CacheSizeKb=128 \
      --l2CacheBanks=2 \
      hw-xclbin
  done
done

for pid in "${pids[@]}"; do
  wait "$pid" || fail=1
done

exit "$fail"
