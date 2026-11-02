#!/usr/bin/env bash
# xScaler fork: upstream mirror and main sync for grafana/dskit.
#
# dskit is a library: it has no releases of ours and no upstream tags. This
# fork mirrors upstream main as origin/upstream/main and keeps its own main on
# upstream main while main carries nothing of its own. Everything else in the
# engine forks' sync (release detection, patch application, sync PRs) does not
# apply here and is left out.
#
# Subcommands:
#   mirror [--dry-run]       push upstream main (and any upstream tags) to origin
#   main-sync [--dry-run]    move main to upstream main: fast-forward when main
#                            has no commits of its own and the push is allowed,
#                            else a PR from sync/upstream-<date>; an issue when
#                            main has diverged
#   main-state <main> <up>   print same|ff|rewritten|diverged for two refs
#   rehearse-main            read-only decision plus a create/delete of a
#                            rehearsal-sync/ branch (proves the App token)
#   disable-upstream-workflows  disable every active workflow that is not .github/workflows/xs-*
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
# Rule types in a branch ruleset that stop a direct push of main by the App.
XS_PUSH_BLOCKING_RULES="${XS_PUSH_BLOCKING_RULES:-pull_request required_status_checks merge_queue update workflows required_deployments code_scanning code_quality}"
# ---------------------------------------------------------------------------

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

# xs_body_fill <body-file> <fill-file>: replace the text between the flag diff

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
  local -a b_fetch=() b_push=() b_names=()
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
  if ((${#MIRROR_FAILED[@]} > 0)); then
    printf '::error::mirror failed for: %s\n' "${MIRROR_FAILED[*]}" >&2
    summary "mirror failed for: ${MIRROR_FAILED[*]}"
    return 1
  fi
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

# issue_find <exact-title>: number of the open issue with that title.
issue_find() {
  [[ "$1" =~ ^[A-Za-z0-9\ ._:()/-]+$ ]] || die "bad issue title $1"
  gh issue list --state open --search "\"$1\" in:title" --limit 30 --json number,title \
    --jq "map(select(.title == \"$1\")) | .[0].number // empty"
}

# issue_upsert <title> <label> <body-file>: create the issue or replace its body.
# The search index lags behind new issues by a while, so an issue created seconds
# ago may be created again on a quick re-run.
issue_upsert() {
  local title="$1" label="$2" body="$3" num url
  num="$(issue_find "${title}")"
  if [[ -n "${num}" ]]; then
    gh issue edit "${num}" --body-file "${body}" > /dev/null
    echo "updated issue #${num}"
  else
    url="$(gh issue create --title "${title}" --label "${label}" --body-file "${body}")"
    echo "${url}"
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
    case "${p}" in ${rule}) return 0 ;; esac
  done
  return 1
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

# xs_workflows_to_disable: stdin is "id<TAB>path<TAB>state" lines; prints the active workflows that are not .github/workflows/xs-*.yml.
xs_workflows_to_disable() {
  local id path state
  while IFS=$'\t' read -r id path state; do
    [[ "${state}" == active ]] || continue
    [[ "${path}" == .github/workflows/* ]] || continue
    [[ "${path}" =~ ^\.github/workflows/xs-[A-Za-z0-9._-]+\.ya?ml$ ]] && continue
    printf '%s\t%s\n' "${id}" "${path}"
  done
}

# xs_github_changes <old> <new>: non-xs paths under .github that differ, as "<added|modified|deleted> <path>".
xs_github_changes() {
  local st p
  while IFS= read -r -d '' st && IFS= read -r -d '' p; do
    if xs_path_allowed "${p}"; then continue; fi
    case "${st}" in A) st=added ;; D) st=deleted ;; *) st=modified ;; esac
    printf '%s %s\n' "${st}" "${p}"
  done < <(git diff --no-renames --name-status -z "$1" "$2" -- .github)
}

# pr_state <head-branch>: the state of the PRs from this repository for that head.
pr_state() {
  gh pr list --state all --head "$1" --limit 20 --json number,state,isCrossRepository | xs_pr_state
}

# ---------------------------------------------------------------------------
# disable-upstream-workflows
# ---------------------------------------------------------------------------
cmd_disable_workflows() {
  local repo id path failed=0
  repo="$(repo_slug)"
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
# main follows upstream main while it carries nothing of its own.

# xs_main_state <main-ref> <upstream-ref>: prints one of
#   same       main is at upstream main
#   ff         main is an ancestor of upstream main (a fast-forward)
#   rewritten  main is not an ancestor but has no content of its own: its tree is
#              the tree of an upstream commit (a squash merge of an earlier sync PR),
#              or every commit in upstream..main has its patch upstream (a rebase
#              merge rewrote the shas)
#   diverged   main has commits of its own
xs_main_state() {
  local m="$1" u="$2" mt
  if [[ "$(git rev-parse "${m}^{commit}")" == "$(git rev-parse "${u}^{commit}")" ]]; then
    echo same
    return 0
  fi
  if git merge-base --is-ancestor "${m}" "${u}"; then
    echo ff
    return 0
  fi
  mt="$(git rev-parse "${m}^{tree}")"
  if git log --format=%T "${u}" | awk -v t="${mt}" '$0 == t { f = 1 } END { exit !f }'; then
    echo rewritten
    return 0
  fi
  if [[ "$(git rev-list --merges --count "${u}..${m}")" == 0 ]] && git cherry "${u}" "${m}" | awk '/^\+/ { n++ } END { exit n > 0 }'; then
    echo rewritten
    return 0
  fi
  echo diverged
}

# xs_push_blocked: stdin is `gh api repos/<repo>/rules/branches/<branch>`. Prints yes
# when a rule in the ruleset stops a direct push of the branch by the App.
xs_push_blocked() {
  jq -r --arg set "${XS_PUSH_BLOCKING_RULES}" \
    'if ([.[].type] | map(select(. as $t | ($set | split(" ") | index($t)) != null)) | length) > 0 then "yes" else "no" end'
}

# main_push_blocked: yes when the rulesets or a classic protection stop the push.
main_push_blocked() {
  local repo rules prot
  repo="$(repo_slug)"
  rules="$(gh api "repos/${repo}/rules/branches/${XS_MAIN_BRANCH}")"
  prot="$(gh api "repos/${repo}/branches/${XS_MAIN_BRANCH}" --jq .protected)"
  if [[ "$(xs_push_blocked <<<"${rules}")" == yes ]]; then
    echo yes
  elif [[ "${prot}" == true ]]; then
    echo yes
  else
    echo no
  fi
}

MAIN_DIVERGED_TITLE="sync: main has diverged from upstream"

# main_sync_open_heads: head branches of our own open sync/upstream-* PRs.
main_sync_open_heads() {
  gh pr list --state open --limit 100 --json headRefName,isCrossRepository | xs_own_heads | { grep -E '^sync/upstream-[0-9]{8}$' || true; }
}

# main_sync_close_prs <comment>: close open sync/upstream-* PRs and delete their branches.
main_sync_close_prs() {
  local h num
  while IFS= read -r h; do
    [[ -n "${h}" ]] || continue
    num="$(pr_find "${h}" open)"
    if [[ -n "${num}" ]]; then
      gh pr close "${num}" --comment "$1" > /dev/null
      echo "closed PR #${num} (${h})"
      api_ref_delete "${h}"
    fi
  done < <(main_sync_open_heads)
}

main_diverged_issue() {
  local m="$1" u="$2" body
  body="$(mktemp)"
  {
    echo "main has commits that upstream main does not have, so the sync cannot move it."
    echo
    echo "Commits only on main (up to 30):"
    echo
    echo '```'
    git log -n 30 --format='%h %s' "${u}..${m}" | xs_neutralize
    echo '```'
    echo
    echo "Reproduce:"
    echo
    echo '```sh'
    echo "git fetch origin ${XS_MAIN_BRANCH} upstream/${XS_MAIN_BRANCH}"
    echo "git log --oneline origin/upstream/${XS_MAIN_BRANCH}..origin/${XS_MAIN_BRANCH}"
    echo '```'
    echo
    echo "Decide per commit: send it upstream, or move it to a branch and reset main to upstream main."
  } > "${body}"
  ensure_label sync-diverged B60205 "main has commits upstream does not have"
  issue_upsert "${MAIN_DIVERGED_TITLE}" sync-diverged "${body}"
  summary "main has diverged from upstream. Issue \"${MAIN_DIVERGED_TITLE}\" opened or updated."
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

# main_sync_manual <pr> <head>: say once that the branch cannot be refreshed by the bot.
main_sync_manual() {
  local marked
  marked="$(gh pr view "$1" --json comments --jq '[.comments[].body | select(contains("xs-sync:needs-manual"))] | length')"
  if [[ "${marked}" == 0 ]]; then
    gh pr comment "$1" --body "main or upstream main moved, and $2 has commits that are not upstream main (or changed while it was refreshed), so it cannot be refreshed automatically. Merge upstream main into the branch, or close this PR and delete the branch so the sync opens a new one.
<!-- xs-sync:needs-manual -->" > /dev/null
  fi
  summary "### main sync: PR #$1 needs a manual update (the branch has other commits)"
  out result needs-manual
}

# main_sync_pr <tip> <state> <reason>: open (or move forward) a PR that brings main to
# the upstream tip. The PR branch only ever holds upstream commits.
main_sync_pr() {
  local tip="$1" state="$2" reason="$3" up="origin/upstream/${XS_MAIN_BRANCH}" repo head num cur body url st
  repo="$(repo_slug)"
  head="$(main_sync_open_heads | head -n1)"
  if [[ -n "${head}" ]]; then
    num="$(pr_find "${head}" open)"
    cur="$(gh api "repos/${repo}/git/ref/heads/${head}" --jq .object.sha)"
    if ! git merge-base --is-ancestor "${cur}" "${up}"; then
      # The branch is no longer the bot's: someone pushed to it. Say so once and stop.
      main_sync_manual "${num}" "${head}"
      return 0
    fi
    if [[ "${cur}" == "${tip}" ]]; then
      echo "PR #${num} (${head}) is already at ${tip}"
      out result exists
      return 0
    fi
    if ! api_ref_set_if "${head}" "${tip}" "${cur}"; then
      main_sync_manual "${num}" "${head}"
      return 0
    fi
    gh pr comment "${num}" --body "Moved ${head} to upstream main ${tip}." > /dev/null
    echo "moved ${head} to ${tip}"
    out result updated
    out pr "${num}"
    return 0
  fi
  head="sync/upstream-$(date -u +%Y%m%d)"
  # A sync PR closed without merging is an explicit skip, and so is one merged today
  # (main follows on the next run); anything else about the branch is unknown.
  st="$(pr_state "${head}")"
  case "${st}" in
    "closed "*)
      echo "skipped by closed PR #${st#closed }"
      summary "### main sync: skipped by closed PR #${st#closed } (${head}). Reopen it, or delete the branch to let the sync open a new one."
      out result skipped
      return 0
      ;;
    "merged "*)
      echo "skipped: PR #${st#merged } for ${head} is merged"
      summary "### main sync: PR #${st#merged } (${head}) is merged; the next run moves main further if upstream moved again."
      out result skipped
      return 0
      ;;
  esac
  if api_branch_exists "${head}"; then
    cur="$(gh api "repos/${repo}/git/ref/heads/${head}" --jq .object.sha)"
    git merge-base --is-ancestor "${cur}" "${up}" || die "${head} exists and holds commits that are not upstream main; not moving it"
  fi
  api_ref_set "${head}" "${tip}"
  body="$(mktemp)"
  {
    echo "main has no commits of its own (${state}). Move it to upstream main ${tip}."
    echo
    echo "A direct push of main is not possible: ${reason}."
    echo
    echo "Upstream changes: https://github.com/${XS_UPSTREAM_REPO}/compare/$(git rev-parse "origin/${XS_MAIN_BRANCH}")...${tip}"
    echo
    echo "Merge with \"Rebase and merge\". The branch holds upstream commits only, so the result is main at the"
    echo "upstream tip. A squash merge gives main the same files in one commit; the sync still recognises it."
    echo
    local gh_changes ngh
    gh_changes="$(xs_github_changes "origin/${XS_MAIN_BRANCH}" "${tip}")"
    ngh="$(grep -c . <<<"${gh_changes}" || true)"
    echo "### Upstream changes under .github (${ngh})"
    echo
    if ((ngh > 0)); then
      echo "Upstream workflows and scripts that changed. Upstream workflows stay disabled: xs-sync disables any"
      echo "that are not xs-*.yml on its next run."
      echo
      echo '```'
      awk 'NR <= 200' <<<"${gh_changes}" | xs_neutralize
      echo '```'
    else
      echo "None."
    fi
  } > "${body}"
  url="$(gh pr create --base "${XS_MAIN_BRANCH}" --head "${head}" --title "chore(sync): move main to upstream main" --body-file "${body}")"
  echo "opened ${url}"
  out result pr
  out pr "${url}"
  summary "Opened ${url}"
}

cmd_main_sync() {
  local dry=false
  [[ "${1:-}" == "--dry-run" ]] && dry=true
  local m="origin/${XS_MAIN_BRANCH}" u="origin/upstream/${XS_MAIN_BRANCH}" state tip blocked reason repo err
  tip="$(git rev-parse "${u}^{commit}")"
  state="$(xs_main_state "${m}" "${u}")"
  out state "${state}"
  summary "### main sync (dry run: ${dry})"
  summary "main ${state}, upstream main ${tip}"
  case "${state}" in
    same)
      echo "main is at upstream main ${tip}"
      if [[ "${dry}" == false ]]; then
        main_sync_close_prs "main is at upstream main"
        local old
        old="$(issue_find "${MAIN_DIVERGED_TITLE}" || true)"
        if [[ -n "${old}" ]]; then gh issue close "${old}" --comment "main follows upstream main again." > /dev/null; fi
      fi
      return 0
      ;;
    diverged)
      echo "main has commits of its own"
      if [[ "${dry}" == true ]]; then
        git log -n 10 --oneline "${u}..${m}"
        echo "dry run: would open or update the issue \"${MAIN_DIVERGED_TITLE}\""
      else
        main_diverged_issue "${m}" "${u}"
      fi
      return 0
      ;;
  esac

  blocked="$(main_push_blocked)"
  reason="the branch ruleset or protection requires a pull request"
  if [[ "${state}" == rewritten ]]; then
    blocked=yes
    reason="main is not an ancestor of upstream main (an earlier sync PR was rebased or squashed)"
  fi
  echo "state ${state}, direct push blocked: ${blocked}"
  if [[ "${dry}" == true ]]; then
    if [[ "${blocked}" == yes ]]; then echo "dry run: would open or update a sync/upstream-<date> PR"; else echo "dry run: would fast-forward ${XS_MAIN_BRANCH} to ${tip}"; fi
    return 0
  fi
  if [[ "${blocked}" == no ]]; then
    repo="$(repo_slug)"
    err="$(mktemp)"
    if gh api --method PATCH "repos/${repo}/git/refs/heads/${XS_MAIN_BRANCH}" -f "sha=${tip}" -F force=false > /dev/null 2> "${err}"; then
      echo "fast-forwarded ${XS_MAIN_BRANCH} to ${tip}"
      out result fast-forward
      summary "Fast-forwarded ${XS_MAIN_BRANCH} to \`${tip}\`."
      return 0
    fi
    if ! grep -q -i -E 'repository rule violations|protected branch|GH013|pull request|status check' "${err}"; then
      cat "${err}" >&2
      die "fast-forward of ${XS_MAIN_BRANCH} failed"
    fi
    cat "${err}" >&2
    reason="the push was rejected by a branch rule"
  fi
  main_sync_pr "${tip}" "${state}" "${reason}"
}

# rehearse-main: the decision against the live repository (no writes), and proof that
# the App token can create and delete a rehearsal-sync/ branch.
cmd_rehearse_main() {
  local tip branch="rehearsal-sync/main-${GITHUB_RUN_ID:-local$$}"
  tip="$(git rev-parse "origin/upstream/${XS_MAIN_BRANCH}^{commit}")"
  cmd_main_sync --dry-run
  echo "direct push of ${XS_MAIN_BRANCH} blocked: $(main_push_blocked)"
  # shellcheck disable=SC2064 # expand the branch now: it is local to this function
  trap "api_ref_delete '${branch}' || true" EXIT
  api_ref_set "${branch}" "${tip}"
  api_branch_exists "${branch}" || die "rehearsal branch ${branch} was not created"
  api_ref_delete "${branch}"
  if api_branch_exists "${branch}"; then die "rehearsal branch ${branch} still exists"; fi
  echo "rehearsal main OK: created and deleted ${branch}"
  summary "### rehearsal main: OK (decision above, branch created and deleted)"
}

# ---------------------------------------------------------------------------
# failure issue
# ---------------------------------------------------------------------------
cmd_issue_failed() {
  local url="${1:?run url required}" num title="sync: failed"
  [[ "${url}" =~ ^https://github\.com/[A-Za-z0-9._/-]+$ ]] || die "bad run url"
  ensure_label sync-failed D93F0B "xs-sync run failed"
  num="$(issue_find "${title}")"
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
