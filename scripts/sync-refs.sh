#!/usr/bin/env bash
# Archive-sync branches and tags from each fork's upstream into the fork.
#
# Never loses anything already archived:
#   - new upstream commits        -> branch fast-forwarded
#   - new upstream branches/tags  -> copied
#   - upstream force-push/rewind, or a moved tag
#                                 -> old state kept as <name>@archived-<timestamp>,
#                                    then the ref follows upstream
#   - branches/tags deleted upstream, or the whole upstream gone -> kept as-is
#
# Env: ORG (required), REPOS (optional, space-separated owner/name list to limit the run),
#      DRY_RUN=true (only report), SKIP_BRANCHES (regex), WRITE_DELAY (seconds between writes)
set -uo pipefail

: "${ORG:?set ORG}"
DRY_RUN=${DRY_RUN:-false}
SKIP_BRANCHES=${SKIP_BRANCHES:-'^(dependabot/|renovate/|gh-readonly-queue/)'}
WRITE_DELAY=${WRITE_DELAY:-1}
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/null}
stamp=$(date -u '+%Y%m%d-%H%M')
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
failed=()

ci()       { [ -n "${GITHUB_ACTIONS:-}" ]; }
warn()     { if ci; then echo "::warning title=$1::$2"; else echo "WARNING [$1] $2"; fi; }
notice()   { if ci; then echo "::notice title=$1::$2"; else echo "NOTICE [$1] $2"; fi; }
group()    { if ci; then echo "::group::$1"; else echo "== $1"; fi; }
endgroup() { if ci; then echo "::endgroup::"; fi; }

# Write call: skipped in dry-run, paced to stay under GitHub's secondary rate limit.
write() {
  [ "$DRY_RUN" = true ] && return 0
  local out rc
  out=$(gh api "$@" 2>&1); rc=$?
  sleep "$WRITE_DELAY"
  if [ $rc -ne 0 ]; then
    grep -qiE 'secondary rate limit|rate limit exceeded' <<<"$out" && touch "$work/rate_limited"
    echo "$out" >&2
  fi
  return $rc
}

# "name<TAB>sha" for every ref under refs/<kind>/ (heads|tags).
# For annotated tags the sha is the tag object, so tag messages are preserved.
refs() {
  gh api --paginate "repos/$1/git/matching-refs/$2/" \
    --jq ".[] | \"\(.ref | ltrimstr(\"refs/$2/\"))\t\(.object.sha)\""
}

# classify <fork> <kind> <upstream-sha> <fork-sha>  ->  new | same | ff | rewritten
classify() {
  local repo=$1 kind=$2 up=$3 cur=$4 st
  [ -z "$cur" ] && { echo new; return; }
  [ "$cur" = "$up" ] && { echo same; return; }
  [ "$kind" = tags ] && { echo rewritten; return; }
  st=$(gh api "repos/$repo/compare/$cur...$up" --jq .status 2>/dev/null) || st=unknown
  case $st in
    ahead)     echo ff ;;
    identical) echo same ;;
    *)         echo rewritten ;;   # diverged / behind / unknown -> keep a backup first
  esac
}

# apply <fork> <kind> <name> <upstream-sha> <fork-sha> <action>
apply() {
  local repo=$1 kind=$2 name=$3 up=$4 cur=$5
  case $6 in
    same) ;;
    new)  write -X POST "repos/$repo/git/refs" -f ref="refs/$kind/$name" -f sha="$up" >/dev/null ;;
    ff)   write -X PATCH "repos/$repo/git/refs/heads/$name" -f sha="$up" -F force=false >/dev/null ;;
    rewritten)
      write -X POST "repos/$repo/git/refs" -f ref="refs/$kind/$name@archived-$stamp" -f sha="$cur" >/dev/null \
        || { echo "backup failed, ref left untouched" >&2; return 1; }
      write -X PATCH "repos/$repo/git/refs/$kind/$name" -f sha="$up" -F force=true >/dev/null ;;
  esac
}

{
  echo "## Branches & tags — $(date -u '+%Y-%m-%d %H:%M UTC')$([ "$DRY_RUN" = true ] && echo ' (dry run)')"
  echo
  echo "| Repository | New branches | Updated branches | New tags | Rewritten upstream | Failed |"
  echo "|---|---|---|---|---|---|"
} >> "$SUMMARY"

repos=${REPOS:-$(gh repo list "$ORG" --fork --limit 1000 --json nameWithOwner -q '.[].nameWithOwner')}
verb=$([ "$DRY_RUN" = true ] && echo "would " || echo "")

for repo in $repos; do
  group "$repo"
  parent=$(gh api "repos/$repo" --jq '.parent.full_name // empty' 2>/dev/null)
  if [ -z "$parent" ]; then
    notice "Detached" "$repo has no upstream any more (deleted or made private); archive kept as-is"
    echo "| $repo | — | — | — | — | upstream gone, archive kept |" >> "$SUMMARY"
    endgroup; continue
  fi
  echo "upstream: $parent"

  declare -A n=([new_heads]=0 [ff]=0 [new_tags]=0 [rewritten]=0 [err]=0)
  for kind in heads tags; do
    declare -A mine=()
    while IFS=$'\t' read -r name sha; do
      [ -n "$name" ] && mine["$name"]=$sha
    done < <(refs "$repo" "$kind")

    while IFS=$'\t' read -r name sha; do
      [ -z "$name" ] && continue
      cur=${mine[$name]:-}
      [ "$kind" = heads ] && [ -z "$cur" ] && [[ $name =~ $SKIP_BRANCHES ]] && continue
      action=$(classify "$repo" "$kind" "$sha" "$cur")
      [ "$action" = same ] && continue

      if apply "$repo" "$kind" "$name" "$sha" "$cur" "$action" 2>"$work/err"; then
        case $action in
          new)       n[new_$kind]=$((n[new_$kind] + 1)); echo "  + ${verb}create $kind/$name" ;;
          ff)        n[ff]=$((n[ff] + 1));               echo "  ↻ ${verb}fast-forward $kind/$name" ;;
          rewritten) n[rewritten]=$((n[rewritten] + 1))
                     warn "Upstream rewrote history" "$repo $kind/$name — ${verb}keep old state as $name@archived-$stamp" ;;
        esac
      else
        warn "Sync failed" "$repo $kind/$name: $(tr '\n' ' ' < "$work/err")"
        n[err]=$((n[err] + 1)); failed+=("$repo $kind/$name")
      fi
      [ -e "$work/rate_limited" ] && break 2
    done < <(refs "$parent" "$kind")
    unset mine
  done

  echo "| $repo | ${n[new_heads]} | ${n[ff]} | ${n[new_tags]} | ${n[rewritten]} | $([ "${n[err]}" -gt 0 ] && echo "❌ ${n[err]}" || echo 0) |" >> "$SUMMARY"
  unset n
  endgroup

  if [ -e "$work/rate_limited" ]; then
    notice "Rate limited" "GitHub's write rate limit was hit; stopping cleanly, the next run continues where this one left off"
    exit 0
  fi
done

echo
echo "Failures: ${#failed[@]}"
if [ ${#failed[@]} -gt 0 ]; then
  printf '  %s\n' "${failed[@]}"
  exit 1
fi
