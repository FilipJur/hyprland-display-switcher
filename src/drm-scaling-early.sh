#!/bin/sh
# Set DRM scaling mode=Full aspect(3) on connected connectors.
# Columns: id encoder status name ... — id is $1, status is $3.
for id in $(modetest -c 2>/dev/null | awk '$3=="connected" {print $1}'); do
  modetest -w "${id}:scaling mode:3" 2>/dev/null || true
done
modetest -c 2>/dev/null | grep -A 4 "scaling mode" | head -n 8 || true
