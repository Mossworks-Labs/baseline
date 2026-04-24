#!/usr/bin/env bash
# Patches the OneUptime Helm chart schema to allow:
#   - Parent chart's global values (hostname, ingressPort, etc.)
#   - Helm condition gate "enabled" property
# Run after: helm dependency update /stacks/baseline
set -euo pipefail

CHART_DIR="${1:-$(dirname "$0")/..}"
CHART_TGZ="$CHART_DIR/charts/oneuptime-"*.tgz

if ! ls $CHART_TGZ 1>/dev/null 2>&1; then
  echo "No oneuptime chart found in $CHART_DIR/charts/ — run helm dependency update first"
  exit 1
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

tar xzf $CHART_TGZ -C "$TMPDIR"

python3 -c "
import json, sys
schema_path = '$TMPDIR/oneuptime/values.schema.json'
with open(schema_path, 'r') as f:
    s = json.load(f)
# Allow parent chart's global values to pass through
if 'global' in s.get('properties', {}):
    s['properties']['global'].pop('additionalProperties', None)
# Allow Helm condition gate 'enabled' property
s.get('properties', {})['enabled'] = {'type': 'boolean'}
# Allow any extra top-level properties from parent charts
s.pop('additionalProperties', None)
with open(schema_path, 'w') as f:
    json.dump(s, f, indent=2)
"

tar czf $CHART_TGZ -C "$TMPDIR" oneuptime/
echo "Patched OneUptime schema in $(basename $CHART_TGZ)"
