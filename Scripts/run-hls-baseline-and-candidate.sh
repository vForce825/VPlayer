#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
# Two separately bounded <=300-second runs, identical bytes and device. No retries.
set -euo pipefail
candidate="$(git rev-parse --show-toplevel)"
cd "$candidate"
head="${1:?Exact candidate SHA required}"
[[ "$head" =~ ^[0-9a-f]{40}$ && "$(git rev-parse HEAD)" == "$head" ]]
old=36f9f00044db05b707e25ea470b0da3cec62682c
root="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/hls-comparison.XXXXXX")"
echo "HLS_COMPARISON_DIRECTORY=$root"
# Actual Swift observations must pass the shared report predicates before either
# source/player window starts. Candidate products are reused for the later run.
VPLAYER_HLS_ACCEPTANCE_DERIVED_DATA="$root/CandidateDerivedData" \
  ./Scripts/run-persistent-hls-acceptance.sh --controls-only --duration-seconds 300 \
  --head "$head" --output "$root/native-controls.json"
git worktree add --detach "$root/old-writer" "$old"
# Only test harness, build manifest and synthetic resources may overlay old code.
python3 - "$candidate" "$root/old-writer" "$root/overlay.sha256" <<'PY'
import hashlib,json,pathlib,shutil,sys
source,target,output=map(pathlib.Path,sys.argv[1:])
def digest_file(path):
 digest=hashlib.sha256()
 with path.open('rb') as stream:
  for chunk in iter(lambda:stream.read(1024*1024),b''): digest.update(chunk)
 return digest.hexdigest()
paths=['Scripts/bootstrap.sh','project.yml','VPlayerHLSAcceptance.xctestplan','Scripts/run-persistent-hls-acceptance.sh',
 'Scripts/Support/configure-hls-acceptance.py','Scripts/Support/persistent_hls_acceptance.py',
 'Scripts/Support/bind-hls-acceptance-testplan.py']
paths += [str(path.relative_to(source)) for path in sorted((source/'Tests/VPlayerHLSAcceptanceTests').rglob('*')) if path.is_file()]
manifest={}
for relative in paths:
 path=source/relative
 assert not path.is_symlink()
 destination=target/relative; destination.parent.mkdir(parents=True,exist_ok=True)
 shutil.copy2(path,destination); manifest[relative]=digest_file(path)
for relative in ['Tests/Fixtures/HLSAcceptance','Tests/Fixtures/SourcePlanning']:
 shutil.copytree(source/relative,target/relative,dirs_exist_ok=True)
 for path in sorted((source/relative).rglob('*')):
  if path.is_file(): manifest[str(path.relative_to(source))]=digest_file(path)
assert (source/'Vendor/FFmpeg/ffmpeg.lock.json').read_bytes()==(target/'Vendor/FFmpeg/ffmpeg.lock.json').read_bytes()
(target/'Vendor/FFmpeg/Artifacts').symlink_to(source/'Vendor/FFmpeg/Artifacts',target_is_directory=True)
encoded=json.dumps(manifest,sort_keys=True,separators=(',',':')).encode()
output.write_text(hashlib.sha256(encoded).hexdigest()+'\n')
(output.parent/'overlay-manifest.json').write_bytes(encoded)
print('BASELINE_OVERLAY_SHA256='+output.read_text().strip())
PY
cd "$root/old-writer"
# Old production files remain exactly at the approved source commit/tree.
git diff --exit-code HEAD -- Sources Vendor ci_scripts
./Scripts/bootstrap.sh --generate
python3 Scripts/Support/bind-hls-acceptance-testplan.py
# Freeze the final generated overlay, including the authentic XcodeGen project.
python3 - "$root/overlay-manifest.json" "$root/overlay.sha256" <<'PYOVERLAY'
import hashlib,json,pathlib,subprocess,sys
manifest=json.loads(pathlib.Path(sys.argv[1]).read_text())
def digest_file(path):
 digest=hashlib.sha256()
 with pathlib.Path(path).open('rb') as stream:
  for chunk in iter(lambda:stream.read(1024*1024),b''): digest.update(chunk)
 return digest.hexdigest()
allowed_prefixes=('VPlayer.xcodeproj/','Tests/VPlayerHLSAcceptanceTests/','Tests/Fixtures/HLSAcceptance/','Tests/Fixtures/SourcePlanning/')
changed=subprocess.check_output(['git','diff','--name-only','HEAD'],text=True).splitlines()
assert all(path in manifest or path.startswith(allowed_prefixes) for path in changed), 'Non-test baseline overlay is prohibited'
paths=set(manifest) | {str(path) for path in pathlib.Path('VPlayer.xcodeproj').rglob('*') if path.is_file()}
manifest={path:digest_file(path) for path in sorted(paths)}
encoded=json.dumps(manifest,sort_keys=True,separators=(',',':')).encode()
pathlib.Path(sys.argv[1]).write_bytes(encoded)
pathlib.Path(sys.argv[2]).write_text(hashlib.sha256(encoded).hexdigest()+'\n')
print('FINAL_BASELINE_OVERLAY_SHA256='+pathlib.Path(sys.argv[2]).read_text().strip())
PYOVERLAY
./Scripts/run-persistent-hls-acceptance.sh --record-baseline --duration-seconds 300 \
  --head "$old" --overlay-sha256 "$(cat "$root/overlay.sha256")" --output "$root/baseline.json"
cd "$candidate"
python3 Scripts/Support/persistent_hls_acceptance.py freeze "$root/baseline.json" --output "$root/frozen-baseline.json"
chmod a-w "$root/frozen-baseline.json"
echo "FROZEN_BASELINE_SHA256=$(shasum -a 256 "$root/frozen-baseline.json" | awk '{print $1}')"
VPLAYER_HLS_ACCEPTANCE_DERIVED_DATA="$root/CandidateDerivedData" \
  ./Scripts/run-persistent-hls-acceptance.sh --duration-seconds 300 --head "$head" \
  --baseline "$root/frozen-baseline.json" --output "$root/candidate.json"
# Print measured, public-synthetic evidence; keep native media job-local.
cat "$root/frozen-baseline.json" "$root/candidate.json" "$root/candidate.json.verdict.json"
