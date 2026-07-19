#!/bin/bash
# Compile and run Mimo's unit tests.
#
# Each test in mac/tests/ is its own `@main` executable, so they cannot be
# linked together — every test needs its own subset of the app sources. Each
# test declares that subset itself, on the first line:
#
#   // sources: custom_pet.swift character_sheet.swift
#   // compile-only: reason        (optional — compiled but never executed)
#
# Keeping the declaration next to the test means adding a test touches one
# file instead of two. A test with no `// sources:` line fails loudly.
#
#   mac/test.sh              # compile + run every unit test
#   mac/test.sh custom_pet   # only tests whose name matches the filter
set -uo pipefail
cd "$(dirname "$0")"
source ./common.sh

FILTER="${1:-}"
OUT="${TMPDIR:-/private/tmp}/mimo-tests"
mkdir -p "$OUT" "$MODULE_CACHE"

# test name -> app sources it needs, read from the test's own `// sources:` line
test_sources() {
  local declaration
  declaration="$(grep -m1 '^// sources:' "tests/$1.swift" 2>/dev/null)" || return 1
  echo "${declaration#// sources:}"
}

# tests marked `// compile-only:` are built but never executed here
compile_only() {
  grep -q '^// compile-only:' "tests/$1.swift" 2>/dev/null
}

frameworks=()
for framework in "${APP_FRAMEWORKS[@]}"; do frameworks+=(-framework "$framework"); done

pass=0; fail=0; failed_names=()
for path in tests/*.swift; do
  name="$(basename "$path" .swift)"
  [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]] && continue

  if ! sources="$(test_sources "$name")"; then
    echo "✗ $name — missing '// sources:' declaration on its first line"
    fail=$((fail + 1)); failed_names+=("$name"); continue
  fi

  binary="$OUT/$name"
  # shellcheck disable=SC2086
  if ! swiftc -module-cache-path "$MODULE_CACHE" $sources "$path" -o "$binary" \
       "${frameworks[@]}" 2>"$OUT/$name.log"; then
    echo "✗ $name — compile failed"
    sed 's/^/    /' "$OUT/$name.log"
    fail=$((fail + 1)); failed_names+=("$name"); continue
  fi

  if compile_only "$name"; then
    echo "· $name — compiled (not run)"
    pass=$((pass + 1)); continue
  fi

  # tests resolve fixture paths like `mac/assets/...` relative to the repo root
  if (cd .. && "$binary") >"$OUT/$name.out" 2>&1; then
    echo "✓ $name"
    pass=$((pass + 1))
  else
    echo "✗ $name — failed"
    sed 's/^/    /' "$OUT/$name.out"
    fail=$((fail + 1)); failed_names+=("$name")
  fi
done

echo
if [ "$fail" -eq 0 ]; then
  echo "all green — $pass passed"
else
  echo "$fail failed (${failed_names[*]}), $pass passed"
  exit 1
fi
