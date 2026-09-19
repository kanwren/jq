#!/usr/bin/env nix-shell
#!nix-shell -i bash -p bash hyperfine python3

set -eu

TS="$(date -u +"%Y%m%d%H%M%SZ")"
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

RUNS=${RUNS:-20}
WARMUP=${WARMUP:-5}

RESULTS_DIR=${RESULTS_DIR:-benchmark-results/interpreter/"$TS"}
DATA_DIR=$(mktemp -d "${TMPDIR:-/tmp}/jq-bench-data.XXXXXX")

cleanup() { rm -rf "$DATA_DIR"; }
trap cleanup EXIT INT TERM

command -v hyperfine >/dev/null 2>&1 || {
  echo "hyperfine is required to run these benchmarks" >&2
  exit 127
}

mkdir -p "$RESULTS_DIR"

python3 - "$DATA_DIR/data.json" <<'PY'
import json
import sys

items = []
for i in range(30000):
    items.append({
        "id": i,
        "active": i % 3 != 0,
        "a": {"b": i},
        "values": [(i * j) % 101 for j in range(1, 8)],
    })

with open(sys.argv[1], "w") as f:
    json.dump({"items": items}, f)
PY

hyperfine --style basic --warmup "$WARMUP" --runs "$RUNS" \
  --export-markdown "$RESULTS_DIR/results.md" \
  --command-name baseline-index "bash -lc '$ROOT/jq-baseline -n '\''reduce range(0;2000000) as \$i (0; ({a:{b:1}} | .a.b))'\'''" \
  --command-name candidate-index "bash -lc '$ROOT/jq-candidate -n '\''reduce range(0;2000000) as \$i (0; ({a:{b:1}} | .a.b))'\'''" \
  --command-name baseline-each "bash -lc '$ROOT/jq-baseline -n '\''[range(0;200000)] | reduce .[] as \$x (0; . + \$x)'\'''" \
  --command-name candidate-each "bash -lc '$ROOT/jq-candidate -n '\''[range(0;200000)] | reduce .[] as \$x (0; . + \$x)'\'''" \
  --command-name baseline-loadv "bash -lc '$ROOT/jq-baseline -n '\''reduce range(0;3000000) as \$i (0; \$i)'\'''" \
  --command-name candidate-loadv "bash -lc '$ROOT/jq-candidate -n '\''reduce range(0;3000000) as \$i (0; \$i)'\'''" \
  --command-name baseline-try "bash -lc '$ROOT/jq-baseline -n '\''reduce range(0;700000) as \$i (0; try error(\$i) catch .)'\'''" \
  --command-name candidate-try "bash -lc '$ROOT/jq-candidate -n '\''reduce range(0;700000) as \$i (0; try error(\$i) catch .)'\'''" \
  --command-name baseline-data "bash -lc '$ROOT/jq-baseline '\''.items | map(select(.active) | .a.b + (.values | add)) | add'\'' $DATA_DIR/data.json'" \
  --command-name candidate-data "bash -lc '$ROOT/jq-candidate '\''.items | map(select(.active) | .a.b + (.values | add)) | add'\'' $DATA_DIR/data.json'" \
  --command-name baseline-path "bash -lc '$ROOT/jq-baseline -n '\''reduce range(0;300000) as \$i (0; ({a:{b:1}} | path(.a.b) | length))'\'''" \
  --command-name candidate-path "bash -lc '$ROOT/jq-candidate -n '\''reduce range(0;300000) as \$i (0; ({a:{b:1}} | path(.a.b) | length))'\'''" \
  --command-name baseline-tail "bash -lc '$ROOT/jq-baseline -n '\''def f(\$n): if \$n == 0 then 0 else f(\$n - 1) end; f(300000)'\'''" \
  --command-name candidate-tail "bash -lc '$ROOT/jq-candidate -n '\''def f(\$n): if \$n == 0 then 0 else f(\$n - 1) end; f(300000)'\'''" \
  --command-name baseline-smallcall "bash -lc '$ROOT/jq-baseline -n '\''def g(\$x): \$x + 1; reduce range(0;1000000) as \$i (0; g(\$i))'\'''" \
  --command-name candidate-smallcall "bash -lc '$ROOT/jq-candidate -n '\''def g(\$x): \$x + 1; reduce range(0;1000000) as \$i (0; g(\$i))'\'''"

cat > "$RESULTS_DIR/README.txt" <<EOF
Runs: $RUNS
Warmup: $WARMUP
EOF
