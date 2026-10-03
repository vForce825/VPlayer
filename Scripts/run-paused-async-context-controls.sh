#!/usr/bin/env bash
# Compile-only, artifact-local controls. No app/runtime allocation claim.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
stage="$root/Scripts/Support/paused-async-context"
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vplayer-async-controls.XXXXXX")"
trap 'rm -rf "$work"' EXIT
python3 -B "$root/Scripts/Tests/test_paused_async_context_addend.py" \
  "$root/Scripts/inspect-paused-async-contexts.py"
python3 -B "$root/Scripts/Tests/test_paused_async_context_output.py" \
  "$root/Scripts/run-paused-async-context-controls.sh"
status=0

for configuration in Debug Release; do
  log="$work/$configuration.log"
  result=failed
  if python3 "$stage/emit_controls.py" --configuration "$configuration" \
      --output "$work/$configuration" >"$log" 2>&1 \
    && python3 "$root/Scripts/inspect-paused-async-contexts.py" \
      --expected-toolchain-version "$stage/expected-swift-version.txt" \
      --artifact-set "$work/$configuration/artifact-set.json" >>"$log" 2>&1; then
    result=passed
  else
    status=1
  fi
  if ! python3 - "$log" "$configuration" "$result" "$work/$configuration" <<'PY'
import hashlib, json, pathlib, sys
log, configuration, result, directory = sys.argv[1:]
raw = pathlib.Path(log).read_bytes()
limit = 128 * 1024
metadata = dict(kind='control_gate_result', configuration=configuration,
    result=result, log_sha256=hashlib.sha256(raw).hexdigest(), log_bytes=len(raw),
    production_attributed=False, aggregate_or_envelope_proven=False)
body = raw.decode('utf-8', errors='replace')
if result != 'passed':
    # Excerpts expose a new compiler spelling without treating it as validated.
    # At most 32 generated-control IR lines, each capped at 1000 characters.
    remaining = 32
    for path in sorted(pathlib.Path(directory).glob('*.ll')):
        body += '\nUNVALIDATED_CONTROL_IR_EXCERPT: ' + path.name + '\n'
        for line in path.read_text().splitlines():
            if remaining and ('target triple =' in line or 'async_func_pointer' in line
                              or '@swift_task_alloc(' in line):
                body += line[:1000] + (' [excerpt truncated]' if len(line) > 1000 else '') + '\n'
                remaining -= 1
# Bound the complete UTF-8 report, including metadata and excerpts, before
# emitting any success status. Never print a prior passed marker or success-log
# tail when the report itself exceeds the gate's output budget.
report = json.dumps(metadata) + '\n' + body
if len(report.encode('utf-8')) > limit:
    result = 'failed'
    metadata.update(result=result, output_limit_exceeded=True)
    report = json.dumps(metadata) + '\nCONTROL_OUTPUT_LIMIT_EXCEEDED: no truncated acceptance\n'
sys.stdout.write(report)
sys.exit(0 if result == 'passed' else 1)
PY
  then
    status=1
  fi
done

if [[ "$status" == 0 ]]; then
  echo 'PAUSED_ASYNC_CONTEXT_CONTROLS_VALIDATED=Debug,Release'
  echo 'PRODUCTION_RUNTIME_SLAB_OR_PEAK_PROOF=0'
else
  echo 'PAUSED_ASYNC_CONTEXT_CONTROLS_INCOMPLETE=1'
fi
exit "$status"
