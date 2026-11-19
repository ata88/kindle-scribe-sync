#!/usr/bin/env bash
# On CI failure: commit the build log to the `ci-logs` branch so it can be read with plain git.
set +e
LOG="${1:-build.log}"
NAME="${2:-${GITHUB_JOB:-job}}"
OUT="$(mktemp -d)/${GITHUB_SHA:-local}-${NAME}.txt"
{
  echo "commit ${GITHUB_SHA} job ${GITHUB_JOB} run ${GITHUB_RUN_ID}"
  sw_vers 2>/dev/null; xcodebuild -version 2>/dev/null
  echo; echo "== errors =="
  grep -E "error:|fatal error|Fatal error|failed|FAILED" "$LOG" 2>/dev/null | grep -v "^\s*$" | awk '!seen[$0]++' | head -300
  echo; echo "== tail =="
  tail -500 "$LOG" 2>/dev/null
} > "$OUT"
cd "$(mktemp -d)"
git init -q
git remote add origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
if git fetch -q --depth 1 origin ci-logs; then git checkout -q -b ci-logs FETCH_HEAD; else git checkout -q --orphan ci-logs; fi
cp "$OUT" .
git add "$(basename "$OUT")"
git -c user.name=ci -c user.email=ci@users.noreply.github.com commit -q -m "build log ${GITHUB_SHA}"
# several jobs publish at the same time: retry on a rejected push; never fail the job over a log
for i in 1 2 3 4 5; do
  git push -q origin ci-logs && exit 0
  sleep $((i * 3))
  git pull -q --rebase origin ci-logs
done
echo "warning: could not publish ${NAME}" >&2
exit 0
