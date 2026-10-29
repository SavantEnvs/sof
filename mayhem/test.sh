#!/usr/bin/env bash
#
# mayhem/test.sh — RUN SOF's own host unit tests (cmocka, built by mayhem/build.sh with normal flags).
# Every test executable prints TAP (`ok N - name` / `not ok N - name`). Each executable must exist, exit 0
# and report AT LEAST the number of passing tests recorded below; a missing executable, a failing test,
# or a neutered binary that prints nothing therefore all fail the suite.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}


UT_TESTS="
src/audio/buffer/buffer_copy 5
src/audio/buffer/buffer_new 1
src/audio/buffer/buffer_wrap 1
src/audio/buffer/buffer_write 2
src/audio/component/comp_set_state 67
src/audio/dcblock/dcblock_math_test 6
src/audio/dcblock/dcblock_process 3
src/audio/drc/drc_math_test 3
src/audio/eq_fir/eq_fir_process 6
src/audio/eq_iir/eq_iir_process 6
src/audio/mixer/mixer 10
src/audio/mux/demux_copy 27
src/audio/mux/mux_copy 27
src/audio/mux/mux_get_processing_function 4
src/audio/pcm_converter/pcm_float_generic 9
src/audio/pipeline/pipeline_connect_upstream 9
src/audio/pipeline/pipeline_free 2
src/audio/pipeline/pipeline_new 1
src/audio/selector/selector_test 16
src/audio/volume/volume_process 9
src/lib/alloc/alloc 46
src/lib/fast-get/fast-get-tests 4
src/lib/lib/rstrcmp 12
src/lib/lib/rstrlen 6
src/math/arithmetic/a_law_codec 2
src/math/arithmetic/mu_law_codec 2
src/math/auditory/auditory 10
src/math/dct/dct 2
src/math/fft/dft3 1
src/math/fft/fft 9
src/math/fft/fft_multi 1
src/math/matrix/matrix 4
src/math/window/window 4
"

UT_DIR="$SRC/build_ut/test/cmocka"
passed=0 failed=0 skipped=0
while read -r rel min; do
  [ -n "$rel" ] || continue
  exe="$UT_DIR/$rel"
  if [ ! -x "$exe" ]; then echo "FAIL $rel: test executable missing (mayhem/build.sh builds it)"; failed=$((failed + 1)); continue; fi
  out=$(cd "$(dirname "$exe")" && timeout 600 "$exe" 2>&1 </dev/null); rc=$?
  ok=$(printf '%s\n' "$out" | grep -cE '^ok [0-9]+ ' || true)
  nok=$(printf '%s\n' "$out" | grep -cE '^not ok [0-9]+ ' || true)
  skip=$(printf '%s\n' "$out" | grep -cE '^ok [0-9]+ .*# SKIP' || true)
  pass=$((ok - skip))
  short=0; [ "$pass" -lt "$min" ] && short=$((min - pass))
  bad=$((nok + short)); [ "$rc" -ne 0 ] && [ "$bad" -eq 0 ] && bad=1
  echo "$([ "$bad" -eq 0 ] && echo PASS || echo FAIL) $rel: rc=$rc ok=$ok not_ok=$nok skipped=$skip (need >= $min)"
  [ "$bad" -ne 0 ] && printf '%s\n' "$out" | grep -E '^not ok ' | head -5
  passed=$((passed + pass)); failed=$((failed + bad)); skipped=$((skipped + skip))
done <<< "$UT_TESTS"

emit_ctrf "cmocka-tap" "$passed" "$failed" "$skipped"
