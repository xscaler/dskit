#!/usr/bin/env bash
# shellcheck disable=SC2310 # helpers run in if/|| on purpose; their callers check the result
# xScaler fork: upstream mirror and main sync for grafana/dskit.
#
# dskit is a library: it has no releases of ours and no upstream tags. This
# fork mirrors upstream main as origin/upstream/main. Our main is upstream main
# plus a patch (only XS_PATCH_PATHS: our own workflow and script files), so it
# never fast-forwards. Everything else in the engine forks' sync (release
# detection, flag diff) does not apply here and is left out.
#
# main state, against the base (the upstream main commit main was built on, found
# by merge-base or, after a squash or rebase merge of a sync PR, by content):
#   current   upstream main has not moved past the base: nothing to do
#   behind    upstream main moved: build a merge commit (main, upstream main) whose
#             tree is upstream main with the patch applied, through the git data
#             API (signed by GitHub), push it to sync/upstream-<date> and open a PR
#   diverged  main changes paths outside the patch set: an issue lists them
# A patch that does not apply opens a conflicts issue and pushes nothing.
#
# Subcommands:
#   mirror [--dry-run]       push upstream main (and any upstream tags) to origin
#   main-sync [--dry-run]    act on the main state above
#   main-state <main> <up>   print current|behind|diverged for two refs
#   rehearse-main            read-only decision, then a build on an artificial main
#                            (an older upstream commit plus our patch) that must give
#                            upstream main plus the patch; no PR
#   disable-upstream-workflows  disable every active workflow that is not ours
#   open-heads <out-file>    write head branches of our own open PRs
#   issue-failed <run-url>   open or update the "sync: failed" issue
#
# Credentials: GH_TOKEN (GitHub App token, jobs that write), GITHUB_REPOSITORY.
# Only the mirror pushes with git. main-sync writes through the API.

# The sed programs below wrap text in markdown backticks on purpose.
# shellcheck disable=SC2016
set -euo pipefail
shopt -s inherit_errexit

# ---------------------------------------------------------------------------
# Parameter block: the only part that changes between repos.
# ---------------------------------------------------------------------------
# Upstream repository (owner/name) and the URL git fetches from.
XS_UPSTREAM_REPO="${XS_UPSTREAM_REPO:-grafana/dskit}"
XS_UPSTREAM_URL="${XS_UPSTREAM_URL:-https://github.com/${XS_UPSTREAM_REPO}.git}"
# Upstream branches to mirror as origin/upstream/<name>. dskit has no release
# branches and no tags, only main.
XS_BRANCH_REGEX="${XS_BRANCH_REGEX:-^main\$}"
# Paths that may differ from upstream (our patch set). None yet, apart from our own
# workflow files.
XS_PATCH_PATHS=(
  ".github/workflows/xs-*"
  ".github/scripts/xs-*"
)
# The namespace upstream must never own: paths that only this fork may carry.
# Shell globs like XS_PATCH_PATHS, but workflows, scripts and actions only (not
# chart paths). A path here must be identical in main and in a sync result, and
# absent from every upstream tree.
XS_NS_PATHS=(
  ".github/workflows/xs-*"
  ".github/scripts/xs-*"
)
# ---------------------------------------------------------------------------

# Identity of the commits the sync bot makes through the git data API: the App is the
# author, GitHub signs and is the committer. A branch tip with any other author or
# committer, or no valid signature, is treated as a human's.
XS_BOT_LOGIN="${XS_BOT_LOGIN:-xscaler-gremlin[bot]}"
XS_BOT_EMAIL="${XS_BOT_EMAIL:-351432774+xscaler-gremlin[bot]@users.noreply.github.com}"

# Who opens the issues the bot looks up by title. gh --author slugs: the App for
# sync issues, the Actions bot for the failure issue (its job holds GITHUB_TOKEN).
# Outsiders can open issues on a public repo; a title match alone is not trusted.
XS_ISSUE_AUTHOR="${XS_ISSUE_AUTHOR:-app/xscaler-gremlin}"
XS_ISSUE_AUTHOR_ACTIONS="${XS_ISSUE_AUTHOR_ACTIONS:-app/github-actions}"

XS_MAIN_BRANCH="${XS_MAIN_BRANCH:-main}"
XS_UPSTREAM_REMOTE="xs-upstream"

log() { echo "$*" >&2; }
die() {
  echo "::error::$*" >&2
  exit 1
}

# out <key> <value>: print key=value and append it to GITHUB_OUTPUT.
out() {
  [[ "$2" != *$'\n'* ]] || die "output ${1} contains a newline"
  printf '%s=%s\n' "$1" "$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT}"; fi
}

summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then printf '%s\n' "$*" >> "${GITHUB_STEP_SUMMARY}"; fi
}

# xs_own_heads: stdin is `gh pr list --json headRefName,isCrossRepository`.
# Prints the head branches of PRs from this repository only. A fork can name its
# branch sync/<tag>; those PRs must never block or be touched by the sync.
xs_own_heads() {
  jq -r '.[] | select(.isCrossRepository == false) | .headRefName'
}


# retry <attempts> <command>...: run the command, sleeping between attempts.
retry() {
  local n="$1" i=1
  shift
  until "$@"; do
    ((i < n)) || return 1
    sleep $((i * ${XS_RETRY_SLEEP:-5}))
    i=$((i + 1))
  done
}

# ---------------------------------------------------------------------------
# Git and GitHub helpers
# ---------------------------------------------------------------------------

repo_slug() { printf '%s\n' "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"; }

# git_auth_args: git -c options that authenticate https pushes with XS_PUSH_TOKEN.
git_push() {
  local hdr
  hdr="$(printf 'x-access-token:%s' "${XS_PUSH_TOKEN:?XS_PUSH_TOKEN required}" | base64 -w0)"
  echo "::add-mask::${hdr}"
  git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic ${hdr}" push "$@"
}

ensure_upstream_remote() {
  if git remote get-url "${XS_UPSTREAM_REMOTE}" > /dev/null 2>&1; then
    git remote set-url "${XS_UPSTREAM_REMOTE}" "${XS_UPSTREAM_URL}"
  else
    git remote add "${XS_UPSTREAM_REMOTE}" "${XS_UPSTREAM_URL}"
  fi
}

ensure_label() {
  gh label create "$1" --color "$2" --description "$3" --force > /dev/null
}

# ---------------------------------------------------------------------------
# mirror
# ---------------------------------------------------------------------------
# Limits, by design: a tag that already exists on origin is never moved, so a
# tag upstream re-points stays at the old commit here; an upstream branch that
# is deleted stays stale under upstream/. Both are rare and need a human.

# mirror_batches <fetch-specs> <push-specs> <names>: arrays by name. Fetch and
# push in batches of 200 (GitHub rejects larger tag pushes). A failed batch is
# retried, then retried ref by ref; refs that still fail go to MIRROR_FAILED.
MIRROR_FAILED=()
mirror_batches() {
  local -n _f="$1" _p="$2" _n="$3"
  local i j
  for ((i = 0; i < ${#_f[@]}; i += 200)); do
    local -a bf=("${_f[@]:i:200}") bp=("${_p[@]:i:200}") bn=("${_n[@]:i:200}")
    if retry 3 git fetch --no-tags "${XS_UPSTREAM_REMOTE}" "${bf[@]}" && retry 3 git_push origin "${bp[@]}"; then
      continue
    fi
    log "batch failed, retrying ref by ref"
    for ((j = 0; j < ${#bf[@]}; j++)); do
      if retry 2 git fetch --no-tags "${XS_UPSTREAM_REMOTE}" "${bf[j]}" && retry 2 git_push origin "${bp[j]}"; then
        :
      else
        MIRROR_FAILED+=("${bn[j]}")
      fi
    done
  done
}

# mirror_ns_check <ref>...: upstream main and the given refs (the tags mirrored in
# this run) must not contain paths in the xs namespace. They are mirrored anyway
# (mirrors are data), but pushing a branch that holds such a workflow can run it
# with the push's context, so the run fails and a human looks. Main is checked on
# every run, so the failure repeats until upstream drops the path.
mirror_ns_check() {
  local ref bad=0 list
  retry 3 git fetch --no-tags "${XS_UPSTREAM_REMOTE}" "+refs/heads/main:refs/remotes/${XS_UPSTREAM_REMOTE}/main" || die "cannot fetch upstream main"
  for ref in "refs/remotes/${XS_UPSTREAM_REMOTE}/main" "$@"; do
    git rev-parse --verify --quiet "${ref}^{commit}" > /dev/null || continue
    list="$(xs_ns_violations "${ref}")" || die "cannot list the tree of ${ref}"
    [[ -n "${list}" ]] || continue
    bad=$((bad + 1))
    printf '::error::upstream %s holds paths in the xs namespace: %s\n' "${ref#refs/}" "$(head -n 10 <<<"${list}" | tr '\n' ';')" >&2
    summary "upstream ${ref#refs/} holds paths in the xs namespace (mirrored anyway, review them):"
    summary "$(head -n 20 <<<"${list}" | sed 's/^/- /')"
  done
  ((bad == 0))
}

cmd_mirror() {
  local dry=false
  [[ "${1:-}" == "--dry-run" ]] && dry=true
  ensure_upstream_remote

  local up_heads up_tags or_heads or_tags
  up_heads="$(mktemp)"
  up_tags="$(mktemp)"
  or_heads="$(mktemp)"
  or_tags="$(mktemp)"
  retry 3 git ls-remote --heads "${XS_UPSTREAM_REMOTE}" > "${up_heads}"
  retry 3 git ls-remote --tags --refs "${XS_UPSTREAM_REMOTE}" > "${up_tags}"
  retry 3 git ls-remote --heads origin 'refs/heads/upstream/*' > "${or_heads}"
  retry 3 git ls-remote --tags --refs origin > "${or_tags}"

  # Branches: upstream <b> -> origin upstream/<b>, only when the sha differs.
  local sha ref name cur
  local -a b_fetch=() b_push=() b_names=() ns_refs=()
  while read -r sha ref; do
    name="${ref#refs/heads/}"
    [[ "${name}" =~ ${XS_BRANCH_REGEX} ]] || continue
    cur="$(awk -v r="refs/heads/upstream/${name}" '$2 == r { print $1 }' "${or_heads}")"
    [[ "${cur}" != "${sha}" ]] || continue
    b_fetch+=("+refs/heads/${name}:refs/remotes/${XS_UPSTREAM_REMOTE}/${name}")
    b_push+=("+refs/remotes/${XS_UPSTREAM_REMOTE}/${name}:refs/heads/upstream/${name}")
    b_names+=("branch ${name}")
    echo "branch ${name}: ${cur:-none} -> ${sha}"
  done < "${up_heads}"

  # Tags: names upstream has and origin lacks. Our own -xs. tags are never touched.
  local -a t_fetch=() t_push=() t_names=()
  while read -r sha ref; do
    name="${ref#refs/tags/}"
    if [[ "${name}" == *-xs.* ]]; then continue; fi
    if awk -v r="${ref}" '$2 == r { found = 1 } END { exit !found }' "${or_tags}"; then continue; fi
    t_fetch+=("refs/tags/${name}:refs/tags/${name}")
    t_push+=("refs/tags/${name}:refs/tags/${name}") # no force: existing tags are never moved
    t_names+=("tag ${name}")
    ns_refs+=("refs/tags/${name}")
  done < "${up_tags}"
  echo "new tags: ${#t_names[@]}"
  if ((${#t_names[@]} > 0)); then printf '  %s\n' "${t_names[@]:0:40}"; fi
  if ((${#t_names[@]} > 40)); then echo "  ... and $((${#t_names[@]} - 40)) more"; fi

  summary "### mirror (dry run: ${dry})"
  summary "- branches to push: ${#b_names[@]}"
  summary "- tags to push: ${#t_names[@]}"

  if [[ "${dry}" == true ]]; then
    echo "dry run: nothing pushed"
    return 0
  fi

  # Safety: the destinations are only refs/heads/upstream/* and refs/tags/*.
  local s
  for s in "${b_push[@]}"; do
    [[ "${s#*:}" == refs/heads/upstream/* ]] || die "refusing destination ${s#*:}"
  done

  mirror_batches b_fetch b_push b_names
  mirror_batches t_fetch t_push t_names
  local rc=0
  if ((${#MIRROR_FAILED[@]} > 0)); then
    printf '::error::mirror failed for: %s\n' "${MIRROR_FAILED[*]}" >&2
    summary "mirror failed for: ${MIRROR_FAILED[*]}"
    rc=1
  fi
  mirror_ns_check "${ns_refs[@]}" || rc=1
  ((rc == 0)) || return 1
  echo "mirror done"
}

# open-heads <out-file>: head branches of open PRs that come from this repository.
cmd_open_heads() {
  gh pr list --state open --limit 1000 --json headRefName,isCrossRepository | xs_own_heads > "${1:?out file required}"
}


# ---------------------------------------------------------------------------
# API ref, PR and issue helpers
# ---------------------------------------------------------------------------

branch_name_ok() { [[ "$1" =~ ^(sync|rehearsal-sync)/[A-Za-z0-9._-]+$ ]]; }

# api_ref_set <branch> <sha>: create the branch, or move it when it exists. Callers
# run branch_guard first. Only sync/* and rehearsal-sync/* are ever written.
api_ref_set() {
  local branch="$1" sha="$2" repo err
  branch_name_ok "${branch}" || die "refusing to write branch ${branch}"
  repo="$(repo_slug)"
  err="$(mktemp)"
  if gh api --method POST "repos/${repo}/git/refs" -f "ref=refs/heads/${branch}" -f "sha=${sha}" > /dev/null 2> "${err}"; then
    return 0
  fi
  if grep -q 'Reference already exists' "${err}"; then
    gh api --method PATCH "repos/${repo}/git/refs/heads/${branch}" -f "sha=${sha}" -F force=true > /dev/null
    return 0
  fi
  cat "${err}" >&2
  return 1
}

api_ref_delete() {
  local branch="$1" repo err
  branch_name_ok "${branch}" || die "refusing to delete branch ${branch}"
  repo="$(repo_slug)"
  err="$(mktemp)"
  if gh api --method DELETE "repos/${repo}/git/refs/heads/${branch}" > /dev/null 2> "${err}"; then return 0; fi
  if grep -q -E 'HTTP 422|HTTP 404|Reference does not exist' "${err}"; then return 0; fi
  cat "${err}" >&2
  return 1
}

api_branch_exists() {
  local branch="$1" repo err
  repo="$(repo_slug)"
  err="$(mktemp)"
  if gh api "repos/${repo}/git/ref/heads/${branch}" > /dev/null 2> "${err}"; then return 0; fi
  grep -q 'HTTP 404' "${err}" || { cat "${err}" >&2; die "could not look up branch ${branch}"; }
  return 1
}

# pr_find <head-branch> <open|all>: number of a PR from this repository with that
# head branch. PRs from forks are ignored: a fork can use any branch name.
pr_find() {
  gh pr list --state "$2" --head "$1" --limit 20 --json number,isCrossRepository \
    --jq '[.[] | select(.isCrossRepository == false)][0].number // empty'
}

# issue_find <exact-title> <label> [author]: number of the open issue with that
# title, our label and an author the bot owns (default the App; the failure issue
# is opened with GITHUB_TOKEN, so it passes XS_ISSUE_AUTHOR_ACTIONS). Anyone can
# open an issue on a public repo, so the title alone proves nothing.
issue_find() {
  [[ "$1" =~ ^[A-Za-z0-9\ ._:()/-]+$ ]] || die "bad issue title $1"
  [[ -n "${2:-}" ]] || die "issue_find needs a label"
  gh issue list --state open --author "${3:-${XS_ISSUE_AUTHOR}}" --label "$2" --search "\"$1\" in:title" --limit 30 --json number,title \
    --jq "map(select(.title == \"$1\")) | .[0].number // empty"
}

# issue_upsert <title> <label> <body-file>: create the issue or replace its body.
# Sets ISSUE_NUMBER. The search index lags behind new issues by a while, so an
# issue created seconds ago may be created again on a quick re-run; callers that
# need the number use ISSUE_NUMBER, not a search.
ISSUE_NUMBER=""
issue_upsert() {
  local title="$1" label="$2" body="$3" num url
  num="$(issue_find "${title}" "${label}")"
  if [[ -n "${num}" ]]; then
    gh issue edit "${num}" --body-file "${body}" > /dev/null
    echo "updated issue #${num}"
    ISSUE_NUMBER="${num}"
  else
    url="$(gh issue create --title "${title}" --label "${label}" --body-file "${body}")"
    echo "${url}"
    ISSUE_NUMBER="${url##*/}"
  fi
}

# ---------------------------------------------------------------------------
# Shared helpers (the same text as in the engine forks)
# ---------------------------------------------------------------------------
# xs_path_allowed <path>: true when the path matches a patch path rule.
xs_path_allowed() {
  local p="$1" rule
  for rule in "${XS_PATCH_PATHS[@]}"; do
    # shellcheck disable=SC2254 # the rule is a glob on purpose
    case "${p}" in ${rule}) return 0 ;; *) ;; esac
  done
  return 1
}

# xs_ns_path <path>: true when the path is in the xs namespace.
xs_ns_path() {
  local p="$1" rule
  for rule in "${XS_NS_PATHS[@]}"; do
    # shellcheck disable=SC2254 # the rule is a glob on purpose
    case "${p}" in ${rule}) return 0 ;; *) ;; esac
  done
  return 1
}

# xs_ns_paths <commit-ish>: NUL separated xs namespace paths in its tree. Fails when
# git cannot read the tree, so a git error never reads as "no such paths".
xs_ns_paths() {
  local list p
  list="$(mktemp)"
  if ! git ls-tree -r --name-only -z "$1" -- .github > "${list}"; then
    rm -f "${list}"
    return 1
  fi
  while IFS= read -r -d '' p; do
    if xs_ns_path "${p}"; then printf '%s\0' "${p}"; fi
  done < "${list}"
  rm -f "${list}"
}

# xs_ns_violations <upstream-commit> [<base-tree> <result-tree>]: one line per
# problem, nothing when clean. Upstream must not carry any path in the xs
# namespace; with the trees, the namespace must also be byte-identical between
# main and the sync result. Paths are shown with control characters replaced.
xs_ns_violations() {
  local up="$1" base="${2:-}" result="${3:-}" p list
  list="$(mktemp)"
  xs_ns_paths "${up}" > "${list}" || { rm -f "${list}"; return 1; }
  while IFS= read -r -d '' p; do
    printf 'upstream %s contains %s\n' "${up}" "${p//[[:cntrl:]]/?}"
  done < "${list}"
  if [[ -n "${base}" && -n "${result}" ]]; then
    git diff --no-renames --name-only -z "${base}" "${result}" -- .github > "${list}" || { rm -f "${list}"; return 1; }
    while IFS= read -r -d '' p; do
      if xs_ns_path "${p}"; then printf 'result differs from main at %s\n' "${p//[[:cntrl:]]/?}"; fi
    done < "${list}"
  fi
  rm -f "${list}"
}

# xs_neutralize: stdin to stdout with @, < and > made inert and backtick runs replaced.
xs_neutralize() {
  sed -e 's/@/@\xe2\x80\x8b/g' -e 's/</\xe2\x80\xb9/g' -e 's/>/\xe2\x80\xba/g' -e "s/\`\\+/'/g"
}

# xs_pr_state: stdin is `gh pr list --json number,state,isCrossRepository`. open|merged|closed <n>, or none.
xs_pr_state() {
  jq -r '[.[] | select(.isCrossRepository == false)] as $p
    | ($p | map(select(.state == "OPEN")) | first) as $o
    | ($p | map(select(.state == "MERGED")) | first) as $m
    | ($p | map(select(.state == "CLOSED")) | first) as $c
    | if $o then "open \($o.number)" elif $m then "merged \($m.number)" elif $c then "closed \($c.number)" else "none" end'
}

# xs_closed_upstream_pr <upstream-sha>: stdin is `gh pr list --state closed --json
# number,state,headRefName,isCrossRepository,author,body`. Prints the number of the
# newest PR that was closed without merging, has a sync/upstream-* head in this
# repository, was opened by the bot (XS_ISSUE_AUTHOR) and records that upstream tip
# in its body as the line "<!-- xs-sync:upstream <sha> -->". Empty when there is none.
# A closed PR is an explicit skip for that upstream tip, whatever day the next
# sync/upstream-<date> branch is named.
xs_closed_upstream_pr() {
  jq -r --arg a "${XS_ISSUE_AUTHOR}" --arg m "<!-- xs-sync:upstream $1 -->" \
    '[.[] | select(.isCrossRepository == false and .state == "CLOSED"
        and (.headRefName | startswith("sync/upstream-")) and .author.login == $a
        and ((.body // "") | split("\n") | map(rtrimstr("\r")) | index($m)))]
      | map(.number) | max // empty'
}

# closed_upstream_pr <upstream-sha>: see xs_closed_upstream_pr.
closed_upstream_pr() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]] || die "bad upstream sha $1"
  gh pr list --state closed --limit 100 --json number,state,headRefName,isCrossRepository,author,body | xs_closed_upstream_pr "$1"
}


# xs_marker_set <upstream-sha>: stdin is a PR body. Prints it with the line
# "<!-- xs-sync:upstream <sha> -->" in place of an earlier marker line, or added at
# the end when there is none.
xs_marker_set() {
  awk -v m="<!-- xs-sync:upstream $1 -->" '
    /^<!-- xs-sync:upstream [0-9a-f]+ -->\r?$/ { if (!done) print m; done = 1; next }
    { print }
    END { if (!done) print m }
  '
}

# pr_marker_update <pr> <upstream-sha>: a refresh moved the PR to a new upstream tip;
# the marker follows, or a later close of the PR would skip the wrong tip.
pr_marker_update() {
  local f
  f="$(mktemp)"
  gh pr view "$1" --json body --jq .body | xs_marker_set "$2" > "${f}"
  gh pr edit "$1" --body-file "${f}" > /dev/null
}
# xs_workflows_to_disable: stdin is "id<TAB>path<TAB>state" lines (the Actions
# API). Prints "id<TAB>path" for every active workflow under .github/workflows/
# that is not ours. A workflow is ours when it is named xs-*.yml and none of the
# refs in XS_UPSTREAM_REFS (space separated: upstream main and the base tag)
# contains that path; an upstream file in our namespace stays disabled. Dynamic
# workflows (no such path) are left alone.
xs_workflows_to_disable() {
  local id path state ref theirs
  while IFS=$'\t' read -r id path state; do
    [[ "${state}" == active ]] || continue
    [[ "${path}" == .github/workflows/* ]] || continue
    if [[ "${path}" =~ ^\.github/workflows/xs-[A-Za-z0-9._-]+\.ya?ml$ ]]; then
      theirs=false
      for ref in ${XS_UPSTREAM_REFS:-}; do
        if git cat-file -e "${ref}:${path}" 2> /dev/null; then theirs=true; fi
      done
      [[ "${theirs}" == true ]] || continue
    fi
    printf '%s\t%s\n' "${id}" "${path}"
  done
}

# xs_github_changes <old> <new>: non-xs paths under .github that differ, as "<added|modified|deleted> <path>".
xs_github_changes() {
  local st p
  local gl
  gl="$(mktemp)"
  git diff --no-renames --name-status -z "$1" "$2" -- .github > "${gl}" || die "${FUNCNAME[0]}: git failed"
  while IFS= read -r -d '' st && IFS= read -r -d '' p; do
    if xs_path_allowed "${p}"; then continue; fi
    case "${st}" in A) st=added ;; D) st=deleted ;; *) st=modified ;; esac
    printf '%s %s\n' "${st}" "${p}"
  done < "${gl}"
}

# pr_state <head-branch>: the state of the PRs from this repository for that head.
pr_state() {
  gh pr list --state all --head "$1" --limit 20 --json number,state,isCrossRepository | xs_pr_state
}

# ---------------------------------------------------------------------------
# disable-upstream-workflows
# ---------------------------------------------------------------------------
cmd_disable_workflows() {
  local repo id path failed=0 base ref
  repo="$(repo_slug)"
  # Upstream refs that decide whether an xs-* workflow is ours: upstream main and the
  # upstream commit main is based on. A missing ref stops the job: guessing would
  # either disable our workflows or leave an upstream one active.
  git rev-parse --verify --quiet "origin/upstream/${XS_MAIN_BRANCH}^{commit}" > /dev/null || die "origin/upstream/${XS_MAIN_BRANCH} is missing; fetch the full history"
  base="$(git merge-base HEAD "origin/upstream/${XS_MAIN_BRANCH}")" || die "HEAD and origin/upstream/${XS_MAIN_BRANCH} share no history"
  XS_UPSTREAM_REFS="origin/upstream/${XS_MAIN_BRANCH} ${base}"
  for ref in ${XS_UPSTREAM_REFS}; do
    git rev-parse --verify --quiet "${ref}^{commit}" > /dev/null || die "${ref} is missing; fetch the full history"
  done
  export XS_UPSTREAM_REFS
  while IFS=$'\t' read -r id path; do
    if gh api --method PUT "repos/${repo}/actions/workflows/${id}/disable" > /dev/null; then
      echo "disabled ${path} (${id})"
    else
      echo "::warning::could not disable ${path} (${id})"
      failed=$((failed + 1))
    fi
  done < <(gh api --paginate "repos/${repo}/actions/workflows?per_page=100" --jq '.workflows[] | [.id, .path, .state] | @tsv' | xs_workflows_to_disable)
  ((failed == 0)) || die "${failed} upstream workflow(s) could not be disabled"
}

# ---------------------------------------------------------------------------
# main sync
# ---------------------------------------------------------------------------
# main is upstream main plus our patch (only XS_PATCH_PATHS differ), so it never
# fast-forwards. The base is the upstream main commit main was last built on. When
# upstream main moves past the base, the sync builds a merge commit of main and
# upstream main whose tree is upstream main with the patch applied, through the
# git data API (the commit is signed by GitHub), and opens a PR for it.

# xs_md_paths [plain]: NUL separated paths on stdin -> bullet list. Control
# characters and backticks are neutralised so a path cannot break the markdown;
# paths go into code spans so @ and # do not mention or link anything.
xs_md_paths() {
  local p bt='`' sq="'"
  while IFS= read -r -d '' p; do
    p="${p//[[:cntrl:]]/?}"
    p="${p//${bt}/${sq}}"
    if [[ "${1:-}" == plain ]]; then printf -- '- %s\n' "${p}"; else printf -- '- `%s`\n' "${p}"; fi
  done
}

# xs_content_matches <tag> <commit>: true when every path that differs between
# the tag and the commit is a patch path, i.e. the commit already holds the
# tag's content. The diff goes to a temp file first: a git failure stops the
# script instead of reading as "no difference".
xs_content_matches() {
  local p list rc=0
  list="$(mktemp)"
  git diff --no-renames --name-only -z "$1" "$2" > "${list}" || die "git diff $1 $2 failed"
  while IFS= read -r -d '' p; do
    if ! xs_path_allowed "${p}"; then
      rc=1
      break
    fi
  done < "${list}"
  rm -f "${list}"
  return "${rc}"
}

# patch_files <base> <tree>: NUL separated paths of our patch set.
patch_files() {
  git diff --no-renames --name-only -z "$1" "$2"
}

# xs_main_analyze <main-ref> <upstream-ref>: finds the upstream commit main is
# built on. Sets XS_BASE and XS_BAD (the paths outside the patch set that main
# changes against XS_BASE). Returns 0 when XS_BAD is empty (main is upstream plus
# the patch), 1 otherwise.
#
# The merge-base is tried first. A squash or rebase merge of an earlier sync PR
# leaves no upstream ancestry in main, so when the merge-base does not fit, the
# newest upstream commits (XS_BASE_SCAN, default 500) are searched for the one
# main equals outside the patch paths. When none fits, XS_BASE is the candidate
# with the fewest foreign paths, so the issue names what main added.
XS_BASE=""
XS_BAD=()
xs_main_analyze() {
  local m="$1" u="$2" mb c p best="" bestn=-1 n list commits found=false
  local -a bad=() bestbad=()
  XS_BASE=""
  XS_BAD=()
  mb="$(git merge-base "${m}" "${u}" 2> /dev/null || true)"
  if [[ -n "${mb}" ]] && xs_content_matches "${mb}" "${m}"; then
    XS_BASE="${mb}"
    return 0
  fi
  list="$(mktemp)"
  commits="$(mktemp)"
  # Every git call below goes to a temp file first, so a git failure stops the script
  # instead of reading as "no difference" or "no commits".
  git rev-list -n "${XS_BASE_SCAN:-500}" "${u}" > "${commits}" || die "git rev-list ${u} failed"
  while read -r c; do
    bad=()
    git diff --no-renames --name-only -z "${c}" "${m}" > "${list}" || die "git diff ${c} ${m} failed"
    while IFS= read -r -d '' p; do
      xs_path_allowed "${p}" || bad+=("${p}")
    done < "${list}"
    n="${#bad[@]}"
    if ((n == 0)); then
      found=true
      XS_BASE="${c}"
      break
    fi
    if ((bestn < 0 || n < bestn)); then
      best="${c}"
      bestn="${n}"
      bestbad=("${bad[@]}")
    fi
  done < "${commits}"
  if [[ "${found}" == true ]]; then
    rm -f "${list}" "${commits}"
    return 0
  fi
  if [[ -n "${mb}" ]]; then
    bad=()
    git diff --no-renames --name-only -z "${mb}" "${m}" > "${list}" || die "git diff ${mb} ${m} failed"
    while IFS= read -r -d '' p; do
      xs_path_allowed "${p}" || bad+=("${p}")
    done < "${list}"
    if ((bestn < 0 || ${#bad[@]} <= bestn)); then
      best="${mb}"
      bestbad=("${bad[@]}")
    fi
  fi
  rm -f "${list}" "${commits}"
  XS_BASE="${best}"
  XS_BAD=("${bestbad[@]}")
  return 1
}

# xs_main_state <main-ref> <upstream-ref>: prints one of
#   current   main is upstream main plus the patch, and upstream main has not
#             moved past the base: nothing to do
#   behind    main is upstream main plus the patch, and upstream main moved on
#   diverged  main changes paths outside the patch set
xs_main_state() {
  if xs_main_analyze "$1" "$2"; then
    if [[ "${XS_BASE}" == "$(git rev-parse "$2^{commit}")" ]]; then echo current; else echo behind; fi
  else
    echo diverged
  fi
}

MAIN_DIVERGED_TITLE="sync: main has diverged from upstream"
MAIN_CONFLICT_TITLE="sync: upstream main conflicts"

# main_sync_open_heads: head branches of our own open sync/upstream-* PRs.
main_sync_open_heads() {
  gh pr list --state open --limit 100 --json headRefName,isCrossRepository | xs_own_heads | { grep -E '^sync/upstream-[0-9]{8}$' || true; }
}

# main_sync_close_prs <comment>: close open sync/upstream-* PRs the bot made and
# delete their branches. A branch with other commits is left alone.
main_sync_close_prs() {
  local h num
  while IFS= read -r h; do
    [[ -n "${h}" ]] || continue
    num="$(pr_find "${h}" open)"
    [[ -n "${num}" ]] || continue
    if ! branch_tip_is_bot "${h}"; then
      echo "::warning::${h} is not the bot's own commit; PR #${num} is left open"
      continue
    fi
    gh pr close "${num}" --comment "$1" > /dev/null
    echo "closed PR #${num} (${h})"
    api_ref_delete "${h}"
  done < <(main_sync_open_heads)
}

# main_close_issue <title> <label> <comment>: close the open issue with that title,
# label and the bot as author.
main_close_issue() {
  local old
  old="$(issue_find "$1" "$2" || true)"
  if [[ -n "${old}" ]]; then gh issue close "${old}" --comment "$3" > /dev/null; fi
}

main_diverged_issue() {
  local m="$1" u="$2" body
  xs_main_analyze "${m}" "${u}" || true
  body="$(mktemp)"
  {
    echo "main changes files outside the patch set, so the sync cannot rebuild it on upstream main."
    echo
    echo "Patch set (may differ from upstream): .github/workflows/xs-*, .github/scripts/xs-*"
    echo
    echo "Paths outside the patch set that differ from upstream main ${XS_BASE:0:12} (up to 100):"
    echo
    printf '%s\0' "${XS_BAD[@]}" | awk 'BEGIN { RS = "\0"; ORS = "\0" } NR <= 100' | xs_md_paths
    echo
    echo "Commits on main since then (up to 30):"
    echo
    echo '```'
    git log -n 30 --format='%h %s' "${XS_BASE}..${m}" | xs_neutralize
    echo '```'
    echo
    echo "Reproduce:"
    echo
    echo '```sh'
    echo "git fetch origin ${XS_MAIN_BRANCH} upstream/${XS_MAIN_BRANCH}"
    echo "git diff --name-only ${XS_BASE:0:12} origin/${XS_MAIN_BRANCH}"
    echo '```'
    echo
    echo "Decide per path: send the change upstream, move it to a branch and revert it on main, or add it to the patch set."
  } > "${body}"
  ensure_label sync-diverged B60205 "main changes files outside the patch set"
  issue_upsert "${MAIN_DIVERGED_TITLE}" sync-diverged "${body}"
  summary "main has diverged from upstream. Issue \"${MAIN_DIVERGED_TITLE}\" opened or updated."
}

# ---------------------------------------------------------------------------
# API commit helpers (the same text as in the engine forks)
# ---------------------------------------------------------------------------

# api_call <method> <endpoint> <json-file>: call the API and print the body.
# Throttling (429, secondary rate limits) and 5xx are retried with a growing
# backoff; anything else fails at once.
api_call() {
  local method="$1" endpoint="$2" input="$3" attempt=1 err body
  err="$(mktemp)"
  while :; do
    if body="$(gh api --method "${method}" "${endpoint}" --input "${input}" 2> "${err}")"; then
      printf '%s\n' "${body}"
      return 0
    fi
    if grep -q -i -E 'HTTP 429|HTTP 5[0-9][0-9]|rate limit|secondary|abuse detection|retry after' "${err}" && ((attempt < 6)); then
      log "API ${method} ${endpoint} throttled or failed (attempt ${attempt}), backing off"
      sleep $((attempt * attempt * ${XS_RETRY_SLEEP:-5}))
      attempt=$((attempt + 1))
      continue
    fi
    cat "${err}" >&2
    return 1
  done
}

# api_plan <base-tree> <result-tree>: one JSON line per changed path on stdout:
# {path, mode, type, sha, blob}. sha is null for a deletion, blob is true when the
# content is new and needs a blob (false for a mode-only change). Renames are
# plain delete plus add. Submodules, unusual modes and file/directory swaps fail.
api_plan() {
  local base="$1" result="$2" meta path omode nmode osha nsha status blob
  local -a deleted=() added=()
  local gl
  gl="$(mktemp)"
  git diff-tree -r -z --no-renames --raw "${base}" "${result}" > "${gl}" || die "${FUNCNAME[0]}: git failed"
  while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    read -r omode nmode osha nsha status <<<"${meta#:}"
    case "${status}" in
      D)
        [[ "${omode}" != 160000 ]] || die "submodule removal at ${path} is not supported"
        deleted+=("${path}")
        jq -cn --arg p "${path}" --arg m "${omode}" '{path:$p,mode:$m,type:"blob",sha:null,blob:false}'
        ;;
      A | M | T)
        case "${nmode}" in
          100644 | 100755 | 120000) ;;
          160000) die "submodule change at ${path} is not supported" ;;
          *) die "unsupported file mode ${nmode} at ${path}" ;;
        esac
        added+=("${path}")
        blob=true
        if [[ "${osha}" == "${nsha}" ]]; then blob=false; fi
        jq -cn --arg p "${path}" --arg m "${nmode}" --arg s "${nsha}" --argjson b "${blob}" \
          '{path:$p,mode:$m,type:"blob",sha:$s,blob:$b}'
        ;;
      *) die "unexpected diff status ${status} at ${path}" ;;
    esac
  done < "${gl}"

  # A path that turns from file to directory or back cannot go through one
  # tree request with a base tree.
  local -A dset=() aset=()
  local x q
  for x in "${deleted[@]}"; do dset["${x}"]=1; done
  for x in "${added[@]}"; do aset["${x}"]=1; done
  for x in "${added[@]}"; do
    q="${x}"
    while [[ "${q}" == */* ]]; do
      q="${q%/*}"
      [[ -z "${dset[${q}]:-}" ]] || die "file to directory change at ${q} is not supported"
    done
  done
  for x in "${deleted[@]}"; do
    q="${x}"
    while [[ "${q}" == */* ]]; do
      q="${q%/*}"
      [[ -z "${aset[${q}]:-}" ]] || die "directory to file change at ${q} is not supported"
    done
  done
}

# api_commit <base-tree-of-parent> <result-tree> <message-file> <parent>...
# Creates blobs and a tree for the difference between <base-tree-of-parent> and
# <result-tree>, then a commit with the given parents. Prints the commit sha.
# The commit has no author or committer set, so GitHub signs it as the App.
api_commit() {
  local base_tree="$1" result_tree="$2" msg_file="$3"
  shift 3
  local repo tmp line sha path nsha tree_sha n=0
  repo="$(repo_slug)"
  tmp="$(mktemp -d)"
  api_plan "${base_tree}" "${result_tree}" > "${tmp}/plan"
  : > "${tmp}/entries"
  while IFS= read -r line; do
    n=$((n + 1))
    if [[ "$(jq -r .blob <<<"${line}")" == true ]]; then
      nsha="$(jq -r .sha <<<"${line}")"
      path="$(jq -r .path <<<"${line}")"
      git cat-file blob "${nsha}" | base64 -w0 > "${tmp}/b64"
      jq -n --rawfile c "${tmp}/b64" '{content:$c,encoding:"base64"}' > "${tmp}/blob.json"
      sha="$(api_call POST "repos/${repo}/git/blobs" "${tmp}/blob.json" | jq -r .sha)"
      [[ "${sha}" == "${nsha}" ]] || die "blob ${path}: API sha ${sha} != local ${nsha}"
    fi
    jq -c 'del(.blob)' <<<"${line}" >> "${tmp}/entries"
  done < "${tmp}/plan"

  if ((n == 0)); then
    tree_sha="${base_tree}"
  else
    jq -s --arg b "${base_tree}" '{base_tree:$b,tree:.}' "${tmp}/entries" > "${tmp}/tree.json"
    tree_sha="$(api_call POST "repos/${repo}/git/trees" "${tmp}/tree.json" | jq -r .sha)"
  fi
  [[ "${tree_sha}" == "${result_tree}" ]] || die "API tree ${tree_sha} != local tree ${result_tree}"

  local parents_json
  parents_json="$(printf '%s\n' "$@" | jq -R . | jq -sc .)"
  jq -n --rawfile m "${msg_file}" --arg t "${tree_sha}" --argjson p "${parents_json}" \
    '{message:$m,tree:$t,parents:$p}' > "${tmp}/commit.json"
  api_call POST "repos/${repo}/git/commits" "${tmp}/commit.json" | jq -r .sha
  rm -rf "${tmp}"
}

# apply_patch <patch-file> <commit-ish> <index-file>
# Applies the patch to the tree of commit-ish in a scratch index (3-way, no
# worktree). Returns 1 on conflict and prints the conflicting paths on fd 3.
apply_patch() {
  local patch="$1" target="$2" index="$3" err rc=0
  err="$(mktemp)"
  GIT_INDEX_FILE="${index}" git read-tree "${target}"
  GIT_INDEX_FILE="${index}" git apply --cached --3way "${patch}" 2> "${err}" || rc=$?
  if ((rc == 0)); then return 0; fi
  {
    GIT_INDEX_FILE="${index}" git ls-files -u -z | tr '\0' '\n' | cut -f2
    sed -n -E \
      -e 's/^error: patch failed: (.*):[0-9]+$/\1/p' \
      -e 's/^error: (.*): patch does not apply$/\1/p' \
      -e 's/^error: (.*): already exists in (working directory|index)$/\1/p' \
      -e 's/^error: (.*): does not exist in (working directory|index)$/\1/p' \
      -e 's/^Applied patch to .(.*). with conflicts\.$/\1/p' "${err}"
  } | LC_ALL=C sort -u >&3
  cat "${err}" >&2
  return 1
}

# branch_tip_is_bot <branch>: true when the branch tip is the bot's own sync
# commit: two parents, the second an upstream main commit, the usual subject,
# made by the App (author XS_BOT_LOGIN, committer GitHub) with a valid
# signature. Anything else means a human may have worked on the branch. Sets
# BOT_TIP, BOT_P1 and BOT_P2.
BOT_TIP=""
BOT_P1=""
BOT_P2=""
branch_tip_is_bot() {
  local branch="$1" tip info repo np subj an ae cn ce ver
  repo="$(repo_slug)"
  tip="$(gh api "repos/${repo}/git/ref/heads/${branch}" --jq .object.sha)"
  info="$(gh api "repos/${repo}/git/commits/${tip}" --jq '[(.parents|length), (.parents[0].sha // ""), (.parents[1].sha // ""), (.message|split("\n")[0]), (.author.name // ""), (.author.email // ""), (.committer.name // ""), (.committer.email // ""), (.verification.verified|tostring)]|@tsv')"
  BOT_TIP="${tip}"
  IFS=$'\t' read -r np BOT_P1 BOT_P2 subj an ae cn ce ver <<<"${info}"
  [[ "${np}" == 2 && "${subj}" == "chore(sync): sync upstream ${XS_MAIN_BRANCH}" && "${an}" == "${XS_BOT_LOGIN}" && "${ae}" == "${XS_BOT_EMAIL}" &&
    "${cn}" == GitHub && "${ce}" == noreply@github.com && "${ver}" == true ]] || return 1
  git merge-base --is-ancestor "${BOT_P2}" "origin/upstream/${XS_MAIN_BRANCH}" 2> /dev/null
}

# api_ref_set_if <branch> <sha> <expected-tip>: move the branch only when it still points at
# the tip that was checked (the ref API has no compare-and-swap, so the tip is read again
# right before the update; a push in that gap is not caught).
api_ref_set_if() {
  local branch="$1" sha="$2" expect="$3" cur
  cur="$(gh api "repos/$(repo_slug)/git/ref/heads/${branch}" --jq .object.sha)"
  [[ "${cur}" == "${expect}" ]] || return 1
  api_ref_set "${branch}" "${sha}"
}

# branch_guard <branch>: refuse to overwrite an existing sync branch that is not
# the bot's own sync commit.
branch_guard() {
  api_branch_exists "$1" || return 0
  branch_tip_is_bot "$1" ||
    die "$1 exists and is not a sync commit; not overwriting it. Delete the branch if it is stale and re-run"
}

# main_sync_branch: the head of the open sync PR, or today's new branch name.
main_sync_branch() {
  local head
  head="$(main_sync_open_heads | head -n1)"
  if [[ -z "${head}" ]]; then head="sync/upstream-$(date -u +%Y%m%d)"; fi
  printf '%s\n' "${head}"
}

# main_build --main-sha S --main-tree T --base B [--upstream U] [--branch BR] [--no-pr]
#   --main-sha   the commit that becomes the first parent (may not exist locally)
#   --main-tree  the tree of main
#   --base       the local upstream main commit main is built on
# Builds the merge commit (main, upstream main) whose tree is upstream main with
# the patch (base to main-tree) applied, writes it to BR through the API and,
# unless --no-pr, opens or refreshes the PR. A patch that does not apply opens or
# updates the conflicts issue and pushes nothing.
main_build() {
  local main_sha="" main_tree="" base="" upstream="origin/upstream/${XS_MAIN_BRANCH}" branch="" open_pr=true
  local issue_title="${MAIN_CONFLICT_TITLE}" issue_label="sync-conflict"
  while (($#)); do
    case "$1" in
      --main-sha) main_sha="$2"; shift 2 ;;
      --main-tree) main_tree="$2"; shift 2 ;;
      --base) base="$2"; shift 2 ;;
      --upstream) upstream="$2"; shift 2 ;;
      --branch) branch="$2"; shift 2 ;;
      --no-pr) open_pr=false; shift ;;
      --issue-title) issue_title="$2"; shift 2 ;;
      --issue-label) issue_label="$2"; shift 2 ;;
      *) die "build: unknown option $1" ;;
    esac
  done
  [[ "${main_sha}" =~ ^[0-9a-f]{40}$ && "${main_tree}" =~ ^[0-9a-f]{40}$ ]] || die "--main-sha and --main-tree must be full shas"
  git cat-file -e "${base}^{commit}" 2> /dev/null || die "--base ${base} is not a commit"
  [[ -n "${branch}" ]] || die "--branch required"
  branch_name_ok "${branch}" || die "bad branch ${branch}"

  # A sync PR closed without merging is an explicit skip, and so is one merged today
  # (main follows on the next run).
  local pr_st="none"
  if [[ "${open_pr}" == true ]]; then
    pr_st="$(pr_state "${branch}")"
    case "${pr_st}" in
      "closed "*)
        echo "skipped by closed PR #${pr_st#closed }"
        summary "### main sync: skipped by closed PR #${pr_st#closed } (${branch}). Reopen it, or delete the branch to let the sync open a new one."
        out result skipped
        return 0
        ;;
      "merged "*)
        echo "skipped: PR #${pr_st#merged } for ${branch} is merged"
        summary "### main sync: PR #${pr_st#merged } (${branch}) is merged; the next run moves main further if upstream moved again."
        out result skipped
        return 0
        ;;
      *) ;;
    esac
    # A sync PR closed without merging is skipped for the upstream tip it carries, not
    # just for the day: tomorrow's sync/upstream-<date> branch has a new name.
    if [[ "${pr_st}" != "open "* ]]; then
      local closed_pr
      closed_pr="$(closed_upstream_pr "$(git rev-parse "${upstream}^{commit}")")"
      if [[ -n "${closed_pr}" ]]; then
        echo "skipped by closed PR #${closed_pr}"
        summary "### main sync: skipped by closed PR #${closed_pr} (upstream main $(git rev-parse "${upstream}^{commit}")). Reopen it, or wait for upstream to move."
        out result skipped
        return 0
      fi
    fi
  fi

  local work patch files_file index up_commit up_tree nfiles
  work="$(mktemp -d)"
  patch="${work}/patch"
  files_file="${work}/files"
  index="${work}/index"
  up_commit="$(git rev-parse "${upstream}^{commit}")"
  up_tree="$(git rev-parse "${up_commit}^{tree}")"
  # Upstream never owns our namespace: a commit that carries an xs-* workflow or
  # script would land on main as one of ours.
  local ns
  ns="$(xs_ns_violations "${up_commit}")" || die "cannot list the xs namespace of ${up_commit}"
  [[ -z "${ns}" ]] || die "upstream main ${up_commit} holds paths in the xs namespace, which only this fork may own: $(head -n 20 <<<"${ns}" | tr '\n' ';')"

  # No renames: a rename is a delete plus an add, so the 3-way apply and the file
  # lists treat both paths.
  git diff --no-renames "${base}" "${main_tree}" --binary --full-index > "${patch}"
  patch_files "${base}" "${main_tree}" > "${files_file}"
  nfiles="$(tr -cd '\0' < "${files_file}" | wc -c)"
  echo "patch: ${nfiles} file(s), $(wc -c < "${patch}") bytes"

  local conflicts="${work}/conflicts" tree
  if ! apply_patch "${patch}" "${up_commit}" "${index}" 3> "${conflicts}"; then
    log "patch does not apply to upstream main ${up_commit}"
    local body="${work}/issue.md"
    {
      echo "The xScaler patch set does not apply to upstream main ${up_commit}."
      echo
      echo "Base: upstream main ${base}"
      echo
      echo "Conflicting files:"
      if [[ -s "${conflicts}" ]]; then
        tr '\n' '\0' < "${conflicts}" | xs_md_paths
      else
        echo "- (not reported by git apply, see the run log)"
      fi
      echo
      echo "Reproduce:"
      echo
      echo '```sh'
      echo "git fetch origin ${XS_MAIN_BRANCH} upstream/${XS_MAIN_BRANCH}"
      echo "git switch --detach origin/upstream/${XS_MAIN_BRANCH}"
      echo "git diff --no-renames ${base} origin/${XS_MAIN_BRANCH} --binary --full-index | git apply --3way"
      echo '```'
      echo
      echo "Resolve the conflicts on a branch, open a PR into ${XS_MAIN_BRANCH} that merges upstream main,"
      echo "and keep the paths outside the patch set byte-identical to upstream."
    } > "${body}"
    ensure_label "${issue_label}" B60205 "xs-sync could not apply the patch set to upstream main"
    issue_upsert "${issue_title}" "${issue_label}" "${body}"
    summary "### main sync: conflict"
    summary "Patch set does not apply to upstream main. Issue \"${issue_title}\" opened or updated."
    out result conflict
    out issue "${ISSUE_NUMBER}"
    return 0
  fi

  tree="$(GIT_INDEX_FILE="${index}" git write-tree)"
  echo "result tree ${tree}"
  ns="$(xs_ns_violations "${up_commit}" "${main_tree}" "${tree}")" || die "cannot compare the xs namespace of main and the result"
  [[ -z "${ns}" ]] || die "the sync result changes the xs namespace of ${XS_MAIN_BRANCH}: $(head -n 20 <<<"${ns}" | tr '\n' ';')"
  xs_content_matches "${up_tree}" "${tree}" || die "result tree ${tree} differs from upstream main outside the patch set"

  local msg="${work}/message"
  {
    echo "chore(sync): sync upstream ${XS_MAIN_BRANCH}"
    echo
    echo "main is upstream main ${base} plus the xScaler patch set. Move it to"
    echo "upstream main ${up_commit}: the tree is upstream main with the patch"
    echo "set applied, and the commit merges main and upstream main so the"
    echo "upstream ancestry stays in main's history."
    echo
    echo "Patch files (${nfiles}):"
    xs_md_paths plain < "${files_file}"
  } > "${msg}"

  if [[ "${open_pr}" == true ]]; then
    if [[ "${pr_st}" == "open "* ]]; then
      # An open bot PR: refresh it when main or upstream main moved, only while the
      # branch is still the bot's own commit.
      local num="${pr_st#open }" refreshed="" expect_tip=""
      out pr "${num}"
      if branch_tip_is_bot "${branch}"; then
        if [[ "${BOT_P1}" == "${main_sha}" && "${BOT_P2}" == "${up_commit}" ]]; then
          echo "PR #${num} (${branch}) is open and up to date"
          out result exists
          return 0
        fi
        expect_tip="${BOT_TIP}"
        refreshed="$(api_commit "${up_tree}" "${tree}" "${msg}" "${main_sha}" "${up_commit}")"
      fi
      if [[ -n "${refreshed}" ]] && api_ref_set_if "${branch}" "${refreshed}" "${expect_tip}"; then
        echo "refreshed PR #${num}: ${branch} -> ${refreshed}"
        pr_marker_update "${num}" "${up_commit}"
        gh pr comment "${num}" --body "Rebuilt ${branch} on upstream main ${up_commit}." > /dev/null
        summary "### main sync: refreshed PR #${num}"
        out result refreshed
        out commit "${refreshed}"
      else
        main_sync_manual "${num}" "${branch}"
      fi
      return 0
    fi
    branch_guard "${branch}"
  fi

  local commit verified
  commit="$(api_commit "${up_tree}" "${tree}" "${msg}" "${main_sha}" "${up_commit}")"
  api_ref_set "${branch}" "${commit}"
  verified="$(gh api "repos/$(repo_slug)/git/commits/${commit}" --jq '.verification.verified')"
  echo "branch ${branch} -> ${commit} (verified: ${verified})"
  out result created
  out branch "${branch}"
  out commit "${commit}"
  out tree "${tree}"
  out verified "${verified}"
  summary "### main sync"
  summary "Branch \`${branch}\` at \`${commit}\`, tree \`${tree}\`, signature verified: ${verified}."

  if [[ "${open_pr}" == true ]]; then
    main_close_issue "${MAIN_CONFLICT_TITLE}" sync-conflict "The patch set applies to upstream main now; sync PR follows."
    local pr_body="${work}/pr.md" nc gh_changes="${work}/gh-changes" ngh url
    nc="$(git rev-list --count --no-merges "${base}..${up_commit}")"
    {
      echo "main is upstream main ${base} plus the xScaler patch set. Upstream main moved by ${nc} commits to ${up_commit}."
      echo "<!-- xs-sync:upstream ${up_commit} -->"
      echo
      echo "Upstream changes: https://github.com/${XS_UPSTREAM_REPO}/compare/${base}...${up_commit}"
      echo
      echo "The commit merges main and upstream main. Its tree is upstream main with the patch set applied."
      echo
      echo "Merge with a merge commit. A squash gives main the same files in one commit; the sync still"
      echo "finds the upstream commit main is built on."
      echo
      echo "### Patch files (${nfiles})"
      echo
      xs_md_paths < "${files_file}"
      echo
      xs_github_changes "${base}" "${up_commit}" > "${gh_changes}"
      ngh="$(wc -l < "${gh_changes}")"
      echo "### Upstream changes under .github (${ngh})"
      echo
      if ((ngh > 0)); then
        echo "Upstream workflows and scripts that changed. Upstream workflows stay disabled: xs-sync disables any"
        echo "that are not ours on its next run."
        echo
        echo '```'
        awk 'NR <= 200' "${gh_changes}" | xs_neutralize
        echo '```'
      else
        echo "None."
      fi
    } > "${pr_body}"
    url="$(gh pr create --base "${XS_MAIN_BRANCH}" --head "${branch}" --title "chore(sync): move main to upstream main" --body-file "${pr_body}")"
    echo "opened ${url}"
    out pr "${url}"
    summary "Opened ${url}"
  fi
}

# main_sync_manual <pr> <head>: say once that the branch cannot be refreshed by the bot.
main_sync_manual() {
  local marked
  marked="$(gh pr view "$1" --json comments --jq '[.comments[].body | select(contains("xs-sync:needs-manual"))] | length')"
  if [[ "${marked}" == 0 ]]; then
    gh pr comment "$1" --body "main or upstream main moved, and $2 is not the sync bot's own verified commit any more (or changed while it was refreshed), so it cannot be refreshed automatically. Merge main and upstream main into the branch, or close this PR and delete the branch so the sync opens a new one.
<!-- xs-sync:needs-manual -->" > /dev/null
  fi
  summary "### main sync: PR #$1 needs a manual update (the branch is not the bot's own commit)"
  out result needs-manual
}

cmd_main_sync() {
  local dry=false
  [[ "${1:-}" == "--dry-run" ]] && dry=true
  local m="origin/${XS_MAIN_BRANCH}" u="origin/upstream/${XS_MAIN_BRANCH}" state tip
  tip="$(git rev-parse "${u}^{commit}")"
  state="$(xs_main_state "${m}" "${u}")"
  out state "${state}"
  summary "### main sync (dry run: ${dry})"
  summary "main ${state}, upstream main ${tip}"
  case "${state}" in
    current)
      echo "upstream main has not moved past the base of main (${tip})"
      if [[ "${dry}" == false ]]; then
        main_sync_close_prs "main already holds upstream main"
        main_close_issue "${MAIN_DIVERGED_TITLE}" sync-diverged "main is upstream main plus the patch set again."
        main_close_issue "${MAIN_CONFLICT_TITLE}" sync-conflict "main already holds upstream main."
      fi
      return 0
      ;;
    diverged)
      xs_main_analyze "${m}" "${u}" || true
      echo "main changes files outside the patch set:"
      printf '%s\0' "${XS_BAD[@]}" | xs_md_paths plain
      if [[ "${dry}" == true ]]; then
        echo "dry run: would open or update the issue \"${MAIN_DIVERGED_TITLE}\""
      else
        main_diverged_issue "${m}" "${u}"
      fi
      return 0
      ;;
    *) ;;
  esac

  xs_main_analyze "${m}" "${u}" || die "state ${state} but main does not analyse as patched"
  local base="${XS_BASE}" main_sha main_tree
  main_sha="$(git rev-parse "${m}^{commit}")"
  main_tree="$(git rev-parse "${m}^{tree}")"
  echo "main is upstream main ${base} plus the patch set; upstream main is ${tip}"
  if [[ "${dry}" == true ]]; then
    local work conflicts
    work="$(mktemp -d)"
    conflicts="${work}/conflicts"
    git diff --no-renames "${base}" "${main_tree}" --binary --full-index > "${work}/patch"
    if apply_patch "${work}/patch" "${tip}" "${work}/index" 3> "${conflicts}"; then
      echo "dry run: the patch applies; would open or update a sync/upstream-<date> PR"
    else
      echo "dry run: the patch does not apply; would open or update the issue \"${MAIN_CONFLICT_TITLE}\""
      cat "${conflicts}"
    fi
    return 0
  fi
  main_close_issue "${MAIN_DIVERGED_TITLE}" sync-diverged "main is upstream main plus the patch set again."
  main_build --main-sha "${main_sha}" --main-tree "${main_tree}" --base "${base}" --upstream "${u}" --branch "$(main_sync_branch)"
}

# overlay_patch <index-file> <ref> <files-file>: set every path of the file list in
# the index to its content in <ref>, or remove it when <ref> lacks it.
overlay_patch() {
  local idx="$1" ref="$2" p ent mode sha
  while IFS= read -r -d '' p; do
    ent="$(git ls-tree "${ref}" -- "${p}" | cut -f1)"
    if [[ -z "${ent}" ]]; then
      GIT_INDEX_FILE="${idx}" git update-index --force-remove -- "${p}"
    else
      read -r mode _ sha <<<"${ent}"
      GIT_INDEX_FILE="${idx}" git update-index --add --cacheinfo "${mode},${sha},${p}"
    fi
  done < "$3"
}

REHEARSAL_BRANCH=""
REHEARSAL_TITLE=""
REHEARSAL_ISSUE=""
rehearsal_cleanup() {
  local n="${REHEARSAL_ISSUE}"
  if [[ -n "${REHEARSAL_BRANCH}" ]]; then api_ref_delete "${REHEARSAL_BRANCH}" || true; fi
  if [[ -z "${n}" && -n "${REHEARSAL_TITLE}" ]]; then n="$(issue_find "${REHEARSAL_TITLE}" rehearsal || true)"; fi
  if [[ -n "${n}" ]]; then gh issue close "${n}" --comment "rehearsal finished" > /dev/null || true; fi
}

# rehearse-main: the decision against the live repository (no writes), then a build
# against an artificial main: an older upstream main commit (XS_REHEARSAL_BACK first-parent
# commits behind the tip) plus our patch set, taken from the checkout (HEAD).
# The build must give upstream main tip plus the patch set, differing from upstream
# main only at patch paths. The branch is a rehearsal-sync/ branch and no PR is opened.
cmd_rehearse_main() {
  local expect_ref="${XS_REHEARSAL_EXPECT:-HEAD}" u="origin/upstream/${XS_MAIN_BRANCH}" rid="${GITHUB_RUN_ID:-local$$}"
  local up_commit up_tree old old_tree work index eindex files synth_tree synth_local expect_tree remote_main
  cmd_main_sync --dry-run
  up_commit="$(git rev-parse "${u}^{commit}")"
  up_tree="$(git rev-parse "${up_commit}^{tree}")"
  xs_main_analyze "${expect_ref}" "${u}" || die "${expect_ref} changes paths outside the patch set"
  old="$(git rev-list --first-parent -n1 --skip="${XS_REHEARSAL_BACK:-25}" "${up_commit}")"
  [[ -n "${old}" && "${old}" != "${up_commit}" ]] || die "no upstream main commit ${XS_REHEARSAL_BACK:-25} commits behind the tip"
  old_tree="$(git rev-parse "${old}^{tree}")"
  echo "rehearsal: base ${old}, target ${up_commit}, patch set = ${expect_ref} against ${XS_BASE}"

  work="$(mktemp -d)"
  files="${work}/files"
  index="${work}/index"
  eindex="${work}/expect-index"
  patch_files "${XS_BASE}" "${expect_ref}" > "${files}"
  [[ -s "${files}" ]] || die "no patch set between ${XS_BASE} and ${expect_ref}"
  GIT_INDEX_FILE="${index}" git read-tree "${old}"
  overlay_patch "${index}" "${expect_ref}" "${files}"
  synth_tree="$(GIT_INDEX_FILE="${index}" git write-tree)"
  GIT_INDEX_FILE="${eindex}" git read-tree "${up_commit}"
  overlay_patch "${eindex}" "${expect_ref}" "${files}"
  expect_tree="$(GIT_INDEX_FILE="${eindex}" git write-tree)"
  xs_content_matches "${up_tree}" "${expect_tree}" || die "expected tree differs from upstream main outside the patch set"
  synth_local="$(git -c user.name=xs-sync -c user.email=xs-sync@localhost commit-tree "${synth_tree}" -p "${old}" -m "rehearsal main")"

  # The analysis must find the older upstream commit as the base of the artificial main.
  xs_main_analyze "${synth_local}" "${u}" || die "artificial main is not analysed as patched"
  [[ "${XS_BASE}" == "${old}" ]] || die "analysis found base ${XS_BASE}, expected ${old}"

  # The artificial main on the remote (dangling, only used as a parent).
  printf 'rehearsal main: upstream main %s plus patch set\n' "${old}" > "${work}/main-msg"
  remote_main="$(api_commit "${old_tree}" "${synth_tree}" "${work}/main-msg" "${old}")"
  echo "artificial main ${remote_main}"

  local branch="rehearsal-sync/main-${rid}"
  REHEARSAL_BRANCH="${branch}"
  REHEARSAL_TITLE="rehearsal sync: upstream main conflicts (${rid})"
  # shellcheck disable=SC2064 # the cleanup reads globals at exit
  trap rehearsal_cleanup EXIT

  local res
  res="$(main_build --main-sha "${remote_main}" --main-tree "${synth_tree}" --base "${old}" --upstream "${u}" \
    --branch "${branch}" --no-pr --issue-title "${REHEARSAL_TITLE}" --issue-label rehearsal)"
  echo "${res}"
  grep -qx 'result=created' <<<"${res}" || die "rehearsal: expected a created branch"
  local got commit remote_tree parents
  got="$(grep '^tree=' <<<"${res}" | cut -d= -f2)"
  commit="$(grep '^commit=' <<<"${res}" | cut -d= -f2)"
  [[ "${got}" == "${expect_tree}" ]] || die "rehearsal tree ${got} != expected ${expect_tree}"
  xs_content_matches "${up_tree}" "${got}" || die "rehearsal tree differs from upstream main outside the patch set"
  remote_tree="$(gh api "repos/$(repo_slug)/git/commits/${commit}" --jq .tree.sha)"
  [[ "${remote_tree}" == "${expect_tree}" ]] || die "remote tree ${remote_tree} != expected ${expect_tree}"
  parents="$(gh api "repos/$(repo_slug)/git/commits/${commit}" --jq '[.parents[].sha]|join(",")')"
  [[ "${parents}" == "${remote_main},${up_commit}" ]] || die "unexpected parents ${parents}"
  api_ref_delete "${branch}"
  if api_branch_exists "${branch}"; then die "rehearsal branch ${branch} still exists"; fi
  REHEARSAL_BRANCH=""
  echo "rehearsal main OK: tree ${got}, parents ${parents}"
  summary "### rehearsal main: OK (${old:0:12} to ${up_commit:0:12}, tree ${got}, verified $(grep '^verified=' <<<"${res}" | cut -d= -f2))"
}

# ---------------------------------------------------------------------------
# failure issue
# ---------------------------------------------------------------------------
cmd_issue_failed() {
  local url="${1:?run url required}" num title="sync: failed"
  [[ "${url}" =~ ^https://github\.com/[A-Za-z0-9._/-]+$ ]] || die "bad run url"
  ensure_label sync-failed D93F0B "xs-sync run failed"
  num="$(issue_find "${title}" sync-failed "${XS_ISSUE_AUTHOR_ACTIONS}")"
  if [[ -n "${num}" ]]; then
    gh issue comment "${num}" --body "Failed again: ${url}" > /dev/null
    echo "commented on #${num}"
  else
    gh issue create --title "${title}" --label sync-failed --body "xs-sync failed: ${url}"
  fi
}

# ---------------------------------------------------------------------------
main() {
  local cmd="${1:-}"
  shift || true
  case "${cmd}" in
    mirror) cmd_mirror "$@" ;;
    disable-upstream-workflows) cmd_disable_workflows ;;
    main-sync) cmd_main_sync "$@" ;;
    main-state) xs_main_state "$@" ;;
    rehearse-main) cmd_rehearse_main ;;
    open-heads) cmd_open_heads "$@" ;;
    issue-failed) cmd_issue_failed "$@" ;;
    *)
      sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' >&2
      exit 2
      ;;
  esac
}

if [[ "${XS_SYNC_SOURCE_ONLY:-}" != "1" ]]; then main "$@"; fi
