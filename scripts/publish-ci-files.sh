#!/usr/bin/env bash
# Copy a folder of CI artifacts (e.g. screenshots) to the ci-logs branch under PREFIX/<sha>/.
set +e
SRC="$1"; PREFIX="${2:-shots}"
[ -d "$SRC" ] || exit 0
SRC="$(cd "$SRC" && pwd)"
cd "$(mktemp -d)"
git init -q
git remote add origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
if git fetch -q --depth 1 origin ci-logs; then git checkout -q -b ci-logs FETCH_HEAD; else git checkout -q --orphan ci-logs; fi
mkdir -p "$PREFIX/${GITHUB_SHA}"
cp -R "$SRC"/. "$PREFIX/${GITHUB_SHA}/"
git add "$PREFIX"
git -c user.name=ci -c user.email=ci@users.noreply.github.com commit -q -m "$PREFIX ${GITHUB_SHA}"
for i in 1 2 3 4 5; do git push -q origin ci-logs && exit 0; sleep $((i * 3)); git pull -q --rebase origin ci-logs; done
echo "warning: could not publish ${PREFIX}" >&2
exit 0
