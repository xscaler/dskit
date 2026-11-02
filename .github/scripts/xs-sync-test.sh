#!/usr/bin/env bash
# Table tests for the mirror and main sync helpers in xs-sync.sh. No network, no
# GitHub token. Run: .github/scripts/xs-sync-test.sh
# shellcheck disable=SC2317,SC2329 # mock functions are called indirectly
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

# which rules stop a direct push of main
rules() { printf '%s' "$1" | xs_push_blocked; }
expect "ruleset: pull request required" yes "$(rules '[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"pull_request"}]')"
expect "ruleset: status checks" yes "$(rules '[{"type":"required_status_checks"}]')"
expect "ruleset: merge queue" yes "$(rules '[{"type":"merge_queue"}]')"
expect "ruleset: only deletion and non-ff" no "$(rules '[{"type":"deletion"},{"type":"non_fast_forward"}]')"
expect "ruleset: none" no "$(rules '[]')"

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
# main state
# ---------------------------------------------------------------------------
repo="${scratch}/state"
G() { git -C "${repo}" "$@"; }
git init -q -b up "${repo}"
printf 'a\nb\nc\nd\ne\nf\n' > "${repo}/f.txt"
G add f.txt && G commit -q -m u0
G checkout -q -b main
st() { (cd "${repo}" && xs_main_state "$1" "$2"); }
expect "same" same "$(st main up)"
G checkout -q up
printf 'a\nb\nc\nd\ne\nf\ng\n' > "${repo}/f.txt" && G commit -q -am u1
printf 'a\nb\nc\nd\ne\nf\ng\nh\n' > "${repo}/f.txt" && G commit -q -am u2
expect "fast-forward" ff "$(st main up)"
# rebase merge of the sync PR: the same patches with new shas
G checkout -q -b rebased main
GIT_COMMITTER_DATE="2031-01-01T00:00:00" G cherry-pick up~1 up > /dev/null
expect "rebased copy has new shas" "no" "$([[ "$(G rev-parse rebased)" == "$(G rev-parse up)" ]] && echo yes || echo no)"
G checkout -q up
printf 'a\nb\nc\nd\ne\nf\ng\nh\ni\n' > "${repo}/f.txt" && G commit -q -am u3
expect "rewritten by a rebase merge" rewritten "$(st rebased up)"
# squash merge of the sync PR: one commit with the content of u2
G checkout -q -b squashed main
G checkout up~1 -- f.txt && G commit -q -m squash
expect "rewritten by a squash merge" rewritten "$(st squashed up)"
# main has its own commit
G checkout -q -b own main
echo own > "${repo}/own.txt" && G add own.txt && G commit -q -m "own file"
expect "diverged by its own commit" diverged "$(st own up)"
# own commit on top of rebased history
G checkout -q -b own2 rebased
echo own > "${repo}/own.txt" && G add own.txt && G commit -q -m "own file"
expect "diverged after a rebase merge" diverged "$(st own2 up)"
# own commit that edits an upstream file differently
G checkout -q -b own3 main
printf 'changed\n' > "${repo}/f.txt" && G commit -q -am "own edit"
expect "diverged by an edit" diverged "$(st own3 up)"
# own merge commit
G checkout -q -b own4 main
G merge -q --no-ff -m "merge" own > /dev/null 2>&1
expect "diverged by a merge" diverged "$(st own4 up)"

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
  esac
}
in_repo "${scratch}" cmd_disable_workflows
expect "disable-upstream-workflows disables only those" "0 repos/x/y/actions/workflows/2/disable repos/x/y/actions/workflows/5/disable" "${RC} $(paste -sd' ' "${DISABLED}")"
unset -f gh

# ---------------------------------------------------------------------------
# main sync PR handling (the API is mocked; refs live in the scratch repository)
# ---------------------------------------------------------------------------
G checkout -q up
mkdir -p "${repo}/.github/workflows"
echo a > "${repo}/.github/workflows/a@b<c>.yml"
echo a > "${repo}/.github/workflows/xs-ours.yml"
G add -A && G commit -q -m "upstream workflow"
G update-ref refs/remotes/origin/main main
G update-ref refs/remotes/origin/upstream/main up
tip="$(G rev-parse up)"
expect "github changes list the upstream workflow, neutralised, without xs files" "added .github/workflows/a@​b‹c›.yml" "$(cd "${repo}" && xs_github_changes main up | xs_neutralize)"
REFSET="${scratch}/refset"
COMMENTS="${scratch}/comments"
PRBODY="${scratch}/prbody"
OPENHEADS=""
STATE="none"
BRANCHTIP="$(G rev-parse up~1)"
MARKED=0
: > "${REFSET}"
: > "${COMMENTS}"
main_sync_open_heads() { [[ -z "${OPENHEADS}" ]] || echo "${OPENHEADS}"; }
pr_state() { echo "${STATE}"; }
pr_find() { echo 9; }
api_ref_set() { echo "$1 $2" >> "${REFSET}"; }
api_branch_exists() { return 1; }
gh() {
  case "$*" in
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
msync() { in_repo "${repo}" main_sync_pr "${tip}" ff "the ruleset requires a pull request"; }
STATE="closed 7"
msync
expect "a closed PR is a skip" "0 yes 0" "${RC} $(grep -q 'skipped by closed PR #7' <<<"${OUT}" && echo yes || echo no) $(wc -l < "${REFSET}")"
STATE="merged 8"
msync
expect "a PR merged today is a skip" "0 yes 0" "${RC} $(grep -q 'is merged' <<<"${OUT}" && echo yes || echo no) $(wc -l < "${REFSET}")"
STATE="none"
msync
expect "a new PR is opened on a new branch" "0 1 yes" "${RC} $(wc -l < "${REFSET}") $(grep -q 'result=pr' <<<"${OUT}" && echo yes || echo no)"
expect "the PR body lists upstream workflow changes, neutralised" "yes yes no" "$(grep -q 'Upstream changes under .github (1)' "${PRBODY}" && echo yes || echo no) $(grep -q 'added .github/workflows/a@​b‹c›.yml' "${PRBODY}" && echo yes || echo no) $(grep -q 'xs-ours' "${PRBODY}" && echo yes || echo no)"
# an open bot PR whose branch holds upstream commits only is moved to the new tip
: > "${REFSET}"
OPENHEADS="sync/upstream-20261101"
msync
expect "an open bot PR is refreshed" "0 sync/upstream-20261101 ${tip}" "${RC} $(cat "${REFSET}")"
BRANCHTIP="${tip}"
: > "${REFSET}"
msync
expect "an up to date PR is left alone" "0 0 yes" "${RC} $(wc -l < "${REFSET}") $(grep -q 'result=exists' <<<"${OUT}" && echo yes || echo no)"
# a branch with a commit that is not upstream's: a comment, once
BRANCHTIP="$(G rev-parse own)"
: > "${COMMENTS}"
msync
expect "a PR with human commits needs a manual update" "0 yes 0 1" "${RC} $(grep -q 'result=needs-manual' <<<"${OUT}" && echo yes || echo no) $(wc -l < "${REFSET}") $(wc -l < "${COMMENTS}")"
MARKED=1
msync
expect "the manual-update comment is not repeated" "1" "$(wc -l < "${COMMENTS}")"
# the branch moved between the check and the update: not overwritten, needs a manual update
BRANCHTIP="$(G rev-parse up~1)"
api_ref_set_if() { return 1; }
: > "${REFSET}"
: > "${COMMENTS}"
MARKED=0
msync
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
unset -f main_sync_open_heads
# shellcheck source=/dev/null
source "${here}/xs-sync.sh"
set +e
gh() { printf '%s' '[{"headRefName":"sync/upstream-20261101","isCrossRepository":false},{"headRefName":"sync/upstream-fix","isCrossRepository":false},{"headRefName":"sync/upstream-20261101-x","isCrossRepository":false},{"headRefName":"sync/upstream-20261102","isCrossRepository":true}]'; }
expect "main sync looks only at sync/upstream-YYYYMMDD heads" "sync/upstream-20261101" "$(main_sync_open_heads)"
unset -f gh pr_state pr_find api_ref_set api_branch_exists

# the diverged issue lists commit subjects in a fenced block, neutralised
G checkout -q -b evil main
# shellcheck disable=SC2016 # backticks are part of the subject
git -C "${repo}" -c user.name=t -c user.email=t@t commit -q --allow-empty -m 'fix @org/team <script> `x`'
G update-ref refs/remotes/origin/main evil
issue_upsert() { printf '%s' "$3" > "${scratch}/issue-path"; cp "$3" "${scratch}/issue-body"; }
ensure_label() { :; }
in_repo "${repo}" main_diverged_issue origin/main origin/upstream/main
expect "diverged issue is fenced and neutralised" "yes no no" "$(grep -q '^```$' "${scratch}/issue-body" && echo yes || echo no) $(grep -q '@org' "${scratch}/issue-body" && echo yes || echo no) $(grep -q '<script>' "${scratch}/issue-body" && echo yes || echo no)"
unset -f issue_upsert ensure_label
G checkout -q main

echo "pass=${pass} fail=${fail}"
[[ "${fail}" -eq 0 ]]
