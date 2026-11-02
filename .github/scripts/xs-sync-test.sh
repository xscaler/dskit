#!/usr/bin/env bash
# Table tests for the mirror and main sync helpers in xs-sync.sh. No network, no
# GitHub token. Run: .github/scripts/xs-sync-test.sh
# shellcheck disable=SC2034,SC2154,SC2310,SC2317,SC2329 # helpers run in && and || on purpose, mock functions are called indirectly, names are set by the sourced script
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export XS_SYNC_SOURCE_ONLY=1
# shellcheck source=/dev/null
source "${here}/xs-sync.sh"
set +e

fail=0
pass=0

# expect <name> <want> <got>
expect() {
  if [[ "$2" == "$3" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"
  fi
}

# own heads: a fork PR named like ours is never counted
expect "own heads" "$(printf 'sync/upstream-20260101\nfeature/x')" "$(printf '%s' '[{"headRefName":"sync/upstream-20260101","isCrossRepository":false},{"headRefName":"sync/upstream-1","isCrossRepository":true},{"headRefName":"feature/x","isCrossRepository":false}]' | xs_own_heads)"

# branch names the sync may write
for b in sync/upstream-20261102 rehearsal-sync/main-123; do
  branch_name_ok "${b}" && r=yes || r=no
  expect "branch ok ${b}" yes "${r}"
done
for b in main upstream/main sync/ 'sync/a;b' sync/../main release/x; do
  branch_name_ok "${b}" && r=yes || r=no
  expect "branch refused ${b}" no "${r}"
done

# retry with backoff
cf="$(mktemp)"
echo 0 > "${cf}"
flaky() { local n; n=$(($(cat "${cf}") + 1)); echo "${n}" > "${cf}"; ((n >= 3)); }
XS_RETRY_SLEEP=0 retry 5 flaky
expect "retry until success" "3" "$(cat "${cf}")"
echo 0 > "${cf}"
XS_RETRY_SLEEP=0 retry 2 false
expect "retry gives up" "1" "$?"
rm -f "${cf}"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT
in_repo() {
  local d="$1"
  shift
  OUT="$(cd "${d}" && "$@" 2>&1)"
  RC=$?
}

# ---------------------------------------------------------------------------
# main state: main is upstream main plus the patch set (our own xs-* files)
# ---------------------------------------------------------------------------
repo="${scratch}/state"
G() { git -C "${repo}" "$@"; }
git init -q -b up "${repo}"
printf 'a\nb\nc\nd\ne\nf\n' > "${repo}/f.txt"
G add f.txt && G commit -q -m u0
G checkout -q -b main
mkdir -p "${repo}/.github/scripts" "${repo}/.github/workflows"
echo script > "${repo}/.github/scripts/xs-sync.sh"
echo workflow > "${repo}/.github/workflows/xs-sync.yml"
G add -A && G commit -q -m "patch"
G checkout -q up
printf 'a\nb\nc\nd\ne\nf\ng\n' > "${repo}/f.txt" && G commit -q -am u1
printf 'a\nb\nc\nd\ne\nf\ng\nh\n' > "${repo}/f.txt" && G commit -q -am u2
st() { (cd "${repo}" && xs_main_state "$1" "$2"); }
# base <main> <up>: the base the analysis finds, and the foreign paths
base_of() { (cd "${repo}" && xs_main_analyze "$1" "$2"; printf '%s|%s' "$(git rev-parse --short "${XS_BASE}")" "${XS_BAD[*]}"); }
short() { G rev-parse --short "$1"; }

expect "patched main, upstream moved: behind" behind "$(st main up)"
expect "patched main, base is the old upstream commit" "$(short up~2)|" "$(base_of main up)"
expect "patched main, upstream not moved: current" current "$(st main up~2)"
G checkout -q -b plain up
expect "main equal to upstream main: current" current "$(st plain up)"
# main merged upstream main (the sync PR merged with a merge commit)
G checkout -q -b merged main
G merge -q --no-ff -m "merge" up~1 > /dev/null 2>&1
expect "merged sync: behind when upstream moved again" behind "$(st merged up)"
expect "merged sync: base is the merged upstream commit" "$(short up~1)|" "$(base_of merged up)"
expect "merged sync: current at the merged commit" current "$(st merged up~1)"
# squash merge of the sync PR: one commit, no upstream ancestry
G checkout -q -b squashed main
G checkout up~1 -- f.txt && G commit -q -m squash
expect "squash merged sync: base found by content" "$(short up~1)|" "$(base_of squashed up)"
expect "squash merged sync: behind when upstream moved again" behind "$(st squashed up)"
expect "squash merged sync: current at the squashed commit" current "$(st squashed up~1)"
# rebase merge: the patch commit replayed on upstream main
G checkout -q -b rebased up~1
GIT_COMMITTER_DATE="2031-01-01T00:00:00" G cherry-pick main > /dev/null
expect "rebase merged sync: base" "$(short up~1)|" "$(base_of rebased up)"
expect "rebase merged sync: behind" behind "$(st rebased up)"
expect "rebase merged sync: current" current "$(st rebased up~1)"
# main changes a path outside the patch set
G checkout -q -b own main
echo own > "${repo}/own.txt" && G add own.txt && G commit -q -m "own file"
expect "non-patch file on main: diverged" diverged "$(st own up)"
expect "diverged lists the path" "$(short up~2)|own.txt" "$(base_of own up)"
G checkout -q -b own2 main
printf 'changed\n' > "${repo}/f.txt" && G commit -q -am "own edit"
expect "edit of an upstream file: diverged" diverged "$(st own2 up)"
expect "edit of an upstream file: path listed" "$(short up~2)|f.txt" "$(base_of own2 up)"
G checkout -q -b own3 main
echo x > "${repo}/.github/workflows/other.yml" && G add -A && G commit -q -m "other workflow"
expect "non-xs workflow on main: diverged" diverged "$(st own3 up)"
expect "non-xs workflow listed" "$(short up~2)|.github/workflows/other.yml" "$(base_of own3 up)"
# an own file on top of a squash merge: only the own file is listed
G checkout -q -b own4 squashed
echo own > "${repo}/own.txt" && G add own.txt && G commit -q -m "own file"
expect "own file after a squash merge: diverged" diverged "$(st own4 up)"
expect "own file after a squash merge: only it is listed" "$(short up~1)|own.txt" "$(base_of own4 up)"

# ---------------------------------------------------------------------------
# mirror against local repositories
# ---------------------------------------------------------------------------
up="${scratch}/up.git"
org="${scratch}/origin.git"
work="${scratch}/work"
git init -q --bare -b main "${up}"
git init -q --bare -b main "${org}"
git init -q -b main "${work}"
git -C "${work}" remote add origin "${org}"
git -C "${work}" remote add up "${up}"
echo 1 > "${work}/x" && git -C "${work}" add x && git -C "${work}" commit -q -m c1
git -C "${work}" tag v1
git -C "${work}" tag v1-xs.0
git -C "${work}" push -q up main v1 v1-xs.0 2> /dev/null
git -C "${work}" branch feature
git -C "${work}" push -q up feature 2> /dev/null
export XS_UPSTREAM_URL="${up}" XS_PUSH_TOKEN=x
in_repo "${work}" cmd_mirror --dry-run
expect "mirror dry run pushes nothing" "0" "$(git -C "${org}" for-each-ref | wc -l)"
expect "mirror dry run lists main and the tag" "yes yes" "$(grep -q 'branch main' <<<"${OUT}" && echo yes || echo no) $(grep -q 'new tags: 1' <<<"${OUT}" && echo yes || echo no)"
in_repo "${work}" cmd_mirror
expect "mirror rc" 0 "${RC}"
expect "mirror pushes upstream/main and tags only" "refs/heads/upstream/main refs/tags/v1" "$(git -C "${org}" for-each-ref --format='%(refname)' | paste -sd' ')"
expect "mirror upstream/main sha" "$(git -C "${work}" rev-parse main)" "$(git -C "${org}" rev-parse refs/heads/upstream/main)"
# a new upstream commit moves upstream/main, an old tag is never moved
echo 2 > "${work}/x" && git -C "${work}" commit -q -am c2
git -C "${work}" push -q up main 2> /dev/null
git -C "${work}" tag -f v1 > /dev/null 2>&1
git -C "${work}" push -q -f up v1 2> /dev/null
in_repo "${work}" cmd_mirror
expect "mirror follows main" "$(git -C "${work}" rev-parse main)" "$(git -C "${org}" rev-parse refs/heads/upstream/main)"
expect "mirror never moves a tag" "no" "$([[ "$(git -C "${org}" rev-parse refs/tags/v1)" == "$(git -C "${work}" rev-parse main)" ]] && echo yes || echo no)"
unset XS_UPSTREAM_URL XS_PUSH_TOKEN


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016 # backticks are the input
expect "neutralize" "$(printf "@\xe2\x80\x8buser \xe2\x80\xb9b\xe2\x80\xba 'x' 'y")" "$(printf '%s' '@user <b> `x` ```y' | xs_neutralize)"
expect "pr state open wins" "open 3" "$(echo '[{"number":2,"state":"MERGED","isCrossRepository":false},{"number":3,"state":"OPEN","isCrossRepository":false}]' | xs_pr_state)"
expect "pr state merged" "merged 2" "$(echo '[{"number":2,"state":"MERGED","isCrossRepository":false},{"number":4,"state":"CLOSED","isCrossRepository":false}]' | xs_pr_state)"
expect "pr state closed" "closed 4" "$(echo '[{"number":4,"state":"CLOSED","isCrossRepository":false}]' | xs_pr_state)"
expect "pr state fork ignored" "none" "$(echo '[{"number":5,"state":"OPEN","isCrossRepository":true}]' | xs_pr_state)"
expect "pr state none" "none" "$(echo '[]' | xs_pr_state)"
for p in .github/workflows/xs-sync.yml .github/scripts/xs-sync.sh; do
  xs_path_allowed "${p}" && r=yes || r=no
  expect "allowed ${p}" yes "${r}"
done
for p in .github/workflows/test-build.yml .github/CODEOWNERS ring/ring.go; do
  xs_path_allowed "${p}" && r=yes || r=no
  expect "not allowed ${p}" no "${r}"
done
printf '1\t.github/workflows/xs-sync.yml\tactive\n2\t.github/workflows/test-build.yml\tactive\n3\t.github/workflows/old.yml\tdisabled_manually\n4\tdynamic/x\tactive\n5\t.github/workflows/xs-evil.yml.txt\tactive\n' > "${scratch}/wf"
expect "workflows to disable" "$(printf '2\t.github/workflows/test-build.yml\n5\t.github/workflows/xs-evil.yml.txt')" "$(xs_workflows_to_disable < "${scratch}/wf")"
export GITHUB_REPOSITORY=x/y
DISABLED="${scratch}/disabled"
: > "${DISABLED}"
gh() {
  case "$*" in
    *"--paginate"*) cat "${scratch}/wf" ;;
    *"--method PUT"*) echo "$4" >> "${DISABLED}" ;;
    *) ;;
  esac
}
in_repo "${scratch}" cmd_disable_workflows
expect "disable-upstream-workflows disables only those" "0 repos/x/y/actions/workflows/2/disable repos/x/y/actions/workflows/5/disable" "${RC} $(paste -sd' ' "${DISABLED}")"
unset -f gh

# ---------------------------------------------------------------------------
# main build (the API is mocked; refs live in the scratch repository)
# ---------------------------------------------------------------------------
G checkout -q -b upgh up
mkdir -p "${repo}/.github/workflows"
echo a > "${repo}/.github/workflows/a@b<c>.yml"
G add -A && G commit -q -m "upstream workflow"
G update-ref refs/remotes/origin/main main
G update-ref refs/remotes/origin/upstream/main upgh
G checkout -q main
mainsha="$(G rev-parse main)"
maintree="$(G rev-parse "main^{tree}")"
upsha="$(G rev-parse upgh)"
oldup="$(G rev-parse up~2)"
oldbot="$(G rev-parse up~1)"
expect "github changes list the upstream workflow, neutralised, without xs files" "added .github/workflows/a@​b‹c›.yml" "$(cd "${repo}" && xs_github_changes up~2 upgh | xs_neutralize)"
REFSET="${scratch}/refset"
COMMENTS="${scratch}/comments"
PRBODY="${scratch}/prbody"
COMMITS="${scratch}/commits"
OPENHEADS=""
STATE="none"
BRANCHTIP="${oldbot}"
BOTINFO=""
MARKED=0
: > "${REFSET}"
: > "${COMMENTS}"
: > "${COMMITS}"
bot_info() { printf '2\t%s\t%s\tchore(sync): sync upstream main\t%s\t%s\tGitHub\tnoreply@github.com\t%s\n' "$1" "$2" "${XS_BOT_LOGIN}" "${XS_BOT_EMAIL}" "${3:-true}"; }
main_sync_open_heads() { [[ -z "${OPENHEADS}" ]] || echo "${OPENHEADS}"; }
pr_state() { echo "${STATE}"; }
pr_find() { echo 9; }
api_ref_set() { echo "$1 $2" >> "${REFSET}"; }
api_branch_exists() { return 1; }
main_close_issue() { echo "$1" >> "${scratch}/closed-issues"; }
issue_upsert() { cp "$3" "${scratch}/issue-body"; echo "$1" > "${scratch}/issue-title"; ISSUE_NUMBER=5; }
ensure_label() { :; }
# the API commit: a local commit with the given tree and parents
api_commit() {
  local t="$2" m="$3" args=() x
  shift 3
  for x in "$@"; do args+=(-p "${x}"); done
  git commit-tree "${t}" -F "${m}" "${args[@]}" | tee -a "${COMMITS}"
}
gh() {
  case "$*" in
    *"@tsv"*) printf '%s\n' "${BOTINFO}" ;;
    *".verification.verified"*) echo true ;;
    *"git/ref/heads/"*) echo "${BRANCHTIP}" ;;
    *"pr view"*) echo "${MARKED}" ;;
    *"pr comment"*) echo "comment" >> "${COMMENTS}" ;;
    "pr create"*)
      local i
      for ((i = 1; i <= $#; i++)); do if [[ "${!i}" == --body-file ]]; then j=$((i + 1)); cp "${!j}" "${PRBODY}"; fi; done
      echo https://github.com/x/y/pull/11
      ;;
    *) echo "unexpected gh $*" >&2; return 1 ;;
  esac
}
export GITHUB_REPOSITORY=x/y
build() { in_repo "${repo}" main_build --main-sha "${mainsha}" --main-tree "${maintree}" --base "${oldup}" --branch sync/upstream-20261102 "$@"; }
STATE="closed 7"
build
expect "a closed PR is a skip" "0 yes 0" "${RC} $(grep -q 'skipped by closed PR #7' <<<"${OUT}" && echo yes || echo no) $(wc -l < "${REFSET}")"
STATE="merged 8"
build
expect "a PR merged today is a skip" "0 yes 0" "${RC} $(grep -q 'is merged' <<<"${OUT}" && echo yes || echo no) $(wc -l < "${REFSET}")"
STATE="none"
build
expect "a new PR is opened on a new branch" "0 1 yes yes" "${RC} $(wc -l < "${REFSET}") $(grep -q 'result=created' <<<"${OUT}" && echo yes || echo no) $(grep -q 'result=created' <<<"${OUT}" && grep -q 'verified=true' <<<"${OUT}" && echo yes || echo no)"
newtree="$(grep '^tree=' <<<"${OUT}" | cut -d= -f2)"
newcommit="$(grep '^commit=' <<<"${OUT}" | cut -d= -f2)"
expect "the commit merges main and upstream main" "${mainsha} ${upsha}" "$(G rev-parse "${newcommit}^1" "${newcommit}^2" | paste -sd' ')"
expect "the tree differs from upstream main only at patch paths" ".github/scripts/xs-sync.sh .github/workflows/xs-sync.yml" "$(G diff --name-only upgh "${newtree}" | paste -sd' ')"
expect "the patch files are main's" "$(G rev-parse main:.github/scripts/xs-sync.sh main:.github/workflows/xs-sync.yml | paste -sd' ')" "$(G rev-parse "${newtree}:.github/scripts/xs-sync.sh" "${newtree}:.github/workflows/xs-sync.yml" | paste -sd' ')"
expect "the tree keeps the upstream change" "$(G rev-parse upgh:f.txt)" "$(G rev-parse "${newtree}:f.txt")"
expect "the PR body lists upstream workflow changes, neutralised" "yes yes no" "$(grep -q 'Upstream changes under .github (1)' "${PRBODY}" && echo yes || echo no) $(grep -q 'added .github/workflows/a@​b‹c›.yml' "${PRBODY}" && echo yes || echo no) $(grep -q 'xs-ours' "${PRBODY}" && echo yes || echo no)"
expect "the commit subject is the bot subject" "chore(sync): sync upstream main" "$(G log -n1 --format=%s "${newcommit}")"
expect "--no-pr opens no PR" "yes" "$(rm -f "${PRBODY}"; build --no-pr; [[ ! -e "${PRBODY}" ]] && echo yes || echo no)"
# an open bot PR that is behind is rebuilt
: > "${REFSET}"
STATE="open 9"
BOTINFO="$(bot_info "${mainsha}" "${oldbot}")"
BRANCHTIP="${oldbot}"
build
expect "an open bot PR is refreshed" "0 sync/upstream-20261102 yes" "${RC} $(awk '{ print $1 }' "${REFSET}") $(grep -q 'result=refreshed' <<<"${OUT}" && echo yes || echo no)"
# main moved: same upstream, new main
BOTINFO="$(bot_info "${oldup}" "${upsha}")"
: > "${REFSET}"
build
expect "an open bot PR is rebuilt when main moved" "yes" "$(grep -q 'result=refreshed' <<<"${OUT}" && echo yes || echo no)"
BOTINFO="$(bot_info "${mainsha}" "${upsha}")"
: > "${REFSET}"
build
expect "an up to date PR is left alone" "0 0 yes" "${RC} $(wc -l < "${REFSET}") $(grep -q 'result=exists' <<<"${OUT}" && echo yes || echo no)"
# a human's tip: a comment, once, and nothing is written
BOTINFO="$(bot_info "${mainsha}" "${oldbot}" false)"
: > "${COMMENTS}"
: > "${REFSET}"
build
expect "a PR with a human tip needs a manual update" "0 yes 0 1" "${RC} $(grep -q 'result=needs-manual' <<<"${OUT}" && echo yes || echo no) $(wc -l < "${REFSET}") $(wc -l < "${COMMENTS}")"
MARKED=1
build
expect "the manual-update comment is not repeated" "1" "$(wc -l < "${COMMENTS}")"
MARKED=0
# a tip whose second parent is not upstream main is a human's
BOTINFO="$(bot_info "${mainsha}" "$(G rev-parse own)")"
(cd "${repo}" && branch_tip_is_bot sync/x) && r=bot || r=human
expect "a second parent outside upstream main is a human's" human "${r}"
BOTINFO="$(bot_info "${mainsha}" "${oldbot}")"
(cd "${repo}" && branch_tip_is_bot sync/x) && r=bot || r=human
expect "a verified bot commit is the bot's" bot "${r}"
BOTINFO="$(printf '1\t%s\t\tchore(sync): sync upstream main\t%s\t%s\tGitHub\tnoreply@github.com\ttrue' "${mainsha}" "${XS_BOT_LOGIN}" "${XS_BOT_EMAIL}")"
(cd "${repo}" && branch_tip_is_bot sync/x) && r=bot || r=human
expect "a single parent commit is a human's" human "${r}"
# the branch moved between the check and the refresh: not overwritten
BOTINFO="$(bot_info "${mainsha}" "${oldbot}")"
api_ref_set_if() { return 1; }
: > "${REFSET}"
: > "${COMMENTS}"
build --base "${oldup}"
expect "a branch that moved during the refresh is not overwritten" "0 yes 0 1" "${RC} $(grep -q 'result=needs-manual' <<<"${OUT}" && echo yes || echo no) $(wc -l < "${REFSET}") $(wc -l < "${COMMENTS}")"
unset -f api_ref_set_if
# shellcheck source=/dev/null
source "${here}/xs-sync.sh"
set +e
api_ref_set() { echo "$1 $2" >> "${REFSET}"; }
gh() { echo bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; }
: > "${REFSET}"
api_ref_set_if b1 cafe aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa && r=moved || r=kept
expect "api_ref_set_if refuses a moved tip" "kept 0" "${r} $(wc -c < "${REFSET}")"
api_ref_set_if b1 cafe bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb && r=moved || r=kept
expect "api_ref_set_if moves an unchanged tip" "moved b1 cafe" "${r} $(cat "${REFSET}")"
unset -f gh api_ref_set
# only bot heads are looked at
gh() { printf '%s' '[{"headRefName":"sync/upstream-20261101","isCrossRepository":false},{"headRefName":"sync/upstream-fix","isCrossRepository":false},{"headRefName":"sync/upstream-20261101-x","isCrossRepository":false},{"headRefName":"sync/upstream-20261102","isCrossRepository":true}]'; }
expect "main sync looks only at sync/upstream-YYYYMMDD heads" "sync/upstream-20261101" "$(main_sync_open_heads)"
unset -f gh

# ---------------------------------------------------------------------------
# a patch that does not apply opens the conflicts issue and pushes nothing
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
source "${here}/xs-sync.sh"
set +e
crepo="${scratch}/conflict"
C() { git -C "${crepo}" "$@"; }
git init -q -b up "${crepo}"
mkdir -p "${crepo}/.github/scripts"
printf '1\n2\n3\n4\n5\n6\n7\n8\n9\n' > "${crepo}/.github/scripts/xs-sync.sh"
C add -A && C commit -q -m u0
C checkout -q -b main
printf '1\n2\n3\nours\n5\n6\n7\n8\n9\n' > "${crepo}/.github/scripts/xs-sync.sh" && C commit -q -am patch
C checkout -q up
printf '1\n2\n3\ntheirs\n5\n6\n7\n8\n9\n' > "${crepo}/.github/scripts/xs-sync.sh" && C commit -q -am u1
C update-ref refs/remotes/origin/upstream/main up
cbase="$(C rev-parse up~1)"
ISSUE="${scratch}/issue"
: > "${ISSUE}"
gh() { echo "unexpected gh $*" >&2; return 1; }
issue_upsert() { echo "$1" >> "${ISSUE}"; cp "$3" "${scratch}/cissue-body"; ISSUE_NUMBER=5; }
ensure_label() { :; }
api_commit() { echo "unexpected api_commit" >&2; return 1; }
api_ref_set() { echo "unexpected api_ref_set" >&2; return 1; }
pr_state() { echo none; }
in_repo "${crepo}" main_build --main-sha "$(C rev-parse main)" --main-tree "$(C rev-parse 'main^{tree}')" --base "${cbase}" --branch sync/upstream-20261102
expect "a conflicting patch opens the conflicts issue and pushes nothing" "0 yes yes issue=5" "${RC} $(grep -qx 'result=conflict' <<<"${OUT}" && echo yes || echo no) $(grep -qx 'sync: upstream main conflicts' "${ISSUE}" && echo yes || echo no) $(grep '^issue=' <<<"${OUT}")"
expect "the conflicts issue names the file" "yes" "$(grep -q 'xs-sync.sh' "${scratch}/cissue-body" && echo yes || echo no)"
unset -f gh issue_upsert ensure_label api_commit api_ref_set pr_state

# ---------------------------------------------------------------------------
# cmd_main_sync decisions
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
source "${here}/xs-sync.sh"
set +e
CALLS="${scratch}/calls"
main_build() { echo "build $*" >> "${CALLS}"; }
main_diverged_issue() { echo "diverged-issue" >> "${CALLS}"; }
main_sync_close_prs() { echo "close-prs" >> "${CALLS}"; }
main_close_issue() { echo "close $1" >> "${CALLS}"; }
main_sync_branch() { echo sync/upstream-20261102; }
sync_with() {
  G update-ref refs/remotes/origin/main "$1"
  G update-ref refs/remotes/origin/upstream/main "$2"
  : > "${CALLS}"
  in_repo "${repo}" cmd_main_sync "${@:3}"
}
sync_with main up
expect "patched and upstream moved: build" "yes" "$(grep -q "^build --main-sha $(G rev-parse main) --main-tree $(G rev-parse 'main^{tree}') --base $(G rev-parse up~2) --upstream origin/upstream/main --branch sync/upstream-20261102\$" "${CALLS}" && echo yes || echo no)"
expect "patched and upstream moved: the diverged issue is closed, no build of an issue" "close sync: main has diverged from upstream" "$(grep '^close' "${CALLS}")"
sync_with main up~2
expect "patched and upstream not moved: nothing to build, issues and PRs closed" "close-prs|close sync: main has diverged from upstream|close sync: upstream main conflicts" "$(paste -sd'|' "${CALLS}")"
sync_with own up
expect "non-patch change: diverged issue" "diverged-issue" "$(cat "${CALLS}")"
expect "non-patch change: the path is printed" "yes" "$(grep -q -- '- own.txt' <<<"${OUT}" && echo yes || echo no)"
sync_with own up --dry-run
expect "dry run of a diverged main writes nothing" "" "$(cat "${CALLS}")"
sync_with main up --dry-run
expect "dry run of a patched main writes nothing and reports the patch applies" "yes " "$(grep -q 'the patch applies' <<<"${OUT}" && echo yes || echo no) $(cat "${CALLS}")"
sync_with squashed up
expect "squash merged earlier sync: build on the squashed base" "yes" "$(grep -q -- "--base $(G rev-parse up~1) " "${CALLS}" && echo yes || echo no)"
unset -f main_build main_diverged_issue main_sync_close_prs main_close_issue main_sync_branch

# shellcheck disable=SC2016 # backticks are part of the expected text
# the diverged issue lists the paths and commit subjects, fenced and neutralised
# shellcheck source=/dev/null
source "${here}/xs-sync.sh"
set +e
G checkout -q -b evil main
mkdir -p "${repo}/@org"
echo x > "${repo}/@org/x.txt" && G add -A
# shellcheck disable=SC2016 # backticks are part of the subject
git -C "${repo}" commit -q -m 'fix @org/team <script> `x`'
G update-ref refs/remotes/origin/main evil
G update-ref refs/remotes/origin/upstream/main up
issue_upsert() { cp "$3" "${scratch}/issue-body"; }
ensure_label() { :; }
in_repo "${repo}" main_diverged_issue origin/main origin/upstream/main
expect "diverged issue is fenced and neutralised" "yes no no" "$(grep -q '^```$' "${scratch}/issue-body" && echo yes || echo no) $(grep -q '@org/team' "${scratch}/issue-body" && echo yes || echo no) $(grep -q '<script>' "${scratch}/issue-body" && echo yes || echo no)"
# shellcheck disable=SC2016 # backticks are part of the expected text
expect "diverged issue lists the path" "yes" "$(grep -q -- '- `@org/x.txt`' "${scratch}/issue-body" && echo yes || echo no)"
unset -f issue_upsert ensure_label
G checkout -q main

# ---------------------------------------------------------------------------
# rehearsal: base = an older upstream main commit plus our patch, target = upstream main
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
source "${here}/xs-sync.sh"
set +e
rrepo="${scratch}/rehearsal"
R() { git -C "${rrepo}" "$@"; }
git init -q -b up "${rrepo}"
for i in 1 2 3 4 5; do echo "${i}" > "${rrepo}/f.txt" && R add f.txt && R commit -q -m "u${i}"; done
R checkout -q -b ci up
mkdir -p "${rrepo}/.github/workflows"
echo patch > "${rrepo}/.github/workflows/xs-sync.yml" && R add -A && R commit -q -m patch
R update-ref refs/remotes/origin/upstream/main up
R update-ref refs/remotes/origin/main ci
RCALLS="${scratch}/rcalls"
: > "${RCALLS}"
gh() {
  local LASTCOMMIT
  LASTCOMMIT="$(grep -E '^[0-9a-f]{40}$' "${RCALLS}" | tail -n1)"
  case "$*" in
    *"git/commits/"*"--jq .tree.sha"*) git cat-file -p "${LASTCOMMIT}" | sed -n 's/^tree //p' ;;
    *"git/commits/"*"parents"*) git cat-file -p "${LASTCOMMIT}" | sed -n 's/^parent //p' | paste -sd, ;;
    *"git/commits/"*) echo true ;;
    *"git/ref/heads/"*) return 1 ;;
    *) echo "unexpected gh $*" >&2; return 1 ;;
  esac
}
api_commit() {
  local t="$2" m="$3" args=() x
  shift 3
  for x in "$@"; do args+=(-p "${x}"); done
  git commit-tree "${t}" -F "${m}" "${args[@]}" | tee -a "${RCALLS}"
}
api_ref_set() { echo "set $1" >> "${RCALLS}"; }
api_ref_delete() { echo "delete $1" >> "${RCALLS}"; }
api_branch_exists() { return 1; }
issue_find() { :; }
cmd_main_sync() { echo "decision $*"; }
pr_state() { echo "unexpected pr_state" >&2; return 1; }
export GITHUB_RUN_ID=77
OUT="$(cd "${rrepo}" && XS_REHEARSAL_BACK=2 cmd_rehearse_main 2>&1)"
RC=$?
[[ "${RC}" == 0 ]] || echo "${OUT}"
expect "rehearsal passes" "0" "${RC}"
expect "rehearsal built the patched upstream tip" "yes" "$(grep -q 'rehearsal main OK' <<<"${OUT}" && echo yes || echo no)"
expect "rehearsal opens no PR and cleans its branch" "set rehearsal-sync/main-77|delete rehearsal-sync/main-77" "$(grep -E '^(set|delete)' "${RCALLS}" | paste -sd'|')"
expect "rehearsal base is an older upstream commit" "yes" "$(grep -q "base $(R rev-parse up~2)," <<<"${OUT}" && echo yes || echo no)"
unset -f gh api_commit api_ref_set api_ref_delete api_branch_exists issue_find cmd_main_sync pr_state

echo "pass=${pass} fail=${fail}"
[[ "${fail}" -eq 0 ]]
