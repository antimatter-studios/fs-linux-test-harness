#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "usage: $0 <open-pull-request-number>" >&2
}

if [ "$#" -ne 1 ] || [[ ! "$1" =~ ^[1-9][0-9]*$ ]]; then
    usage
    exit 2
fi

pull_request="$1"
repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
head_branch="$(gh pr view "$pull_request" --repo "$repo" --json state,headRefName \
    --jq 'select(.state == "OPEN") | .headRefName')"

if [ -z "$head_branch" ]; then
    echo "PR #$pull_request is not open" >&2
    exit 1
fi

open_prs="$(gh pr list --repo "$repo" --state open --limit 1000 \
    --json number,headRefName,baseRefName \
    --jq '.[] | [.number, .headRefName, .baseRefName] | @tsv')"

affected_prs=("$pull_request")
affected_branches=("$head_branch")

for ((branch_index = 0; branch_index < ${#affected_branches[@]}; branch_index++)); do
    base_branch="${affected_branches[$branch_index]}"
    while IFS=$'\t' read -r candidate_number candidate_head candidate_base; do
        [ -n "$candidate_number" ] || continue
        [ "$candidate_base" = "$base_branch" ] || continue
        case " ${affected_prs[*]} " in
            *" $candidate_number "*) continue ;;
        esac
        affected_prs+=("$candidate_number")
        affected_branches+=("$candidate_head")
    done <<< "$open_prs"
done

run_ids=()
for branch in "${affected_branches[@]}"; do
    active_runs="$(gh run list --repo "$repo" --branch "$branch" --limit 1000 \
        --json databaseId,status \
        --jq '.[] | select(.status != "completed") | .databaseId')"
    while IFS= read -r run_id; do
        [ -n "$run_id" ] || continue
        case " ${run_ids[*]-} " in
            *" $run_id "*) continue ;;
        esac
        run_ids+=("$run_id")
    done <<< "$active_runs"
done

printf 'Affected pull requests:'
for affected_pr in "${affected_prs[@]}"; do
    printf ' #%s' "$affected_pr"
done
printf '\n'

if [ "${#run_ids[@]}" -eq 0 ]; then
    echo "No queued or running workflows to cancel."
    exit 0
fi

for run_id in "${run_ids[@]}"; do
    if gh run cancel "$run_id" --repo "$repo"; then
        printf 'Requested cancellation for workflow run %s\n' "$run_id"
    else
        printf 'Normal cancellation request failed for run %s; checking its status\n' "$run_id" >&2
    fi
done

unresolved_runs=("${run_ids[@]}")
for ((attempt = 0; attempt < 3 && ${#unresolved_runs[@]} > 0; attempt++)); do
    remaining_runs=()
    for run_id in ${unresolved_runs[@]+"${unresolved_runs[@]}"}; do
        status="$(gh run view "$run_id" --repo "$repo" --json status --jq .status)"
        if [ "$status" != completed ]; then
            remaining_runs+=("$run_id")
        fi
    done
    unresolved_runs=(${remaining_runs[@]+"${remaining_runs[@]}"})
    [ "${#unresolved_runs[@]}" -eq 0 ] || sleep 1
done

force_cancelled_runs=()
for run_id in ${unresolved_runs[@]+"${unresolved_runs[@]}"}; do
    status="$(gh run view "$run_id" --repo "$repo" --json status --jq .status)"
    if [ "$status" = completed ]; then
        continue
    fi
    printf 'Run %s remains %s after normal cancellation; force-cancelling it\n' \
        "$run_id" "$status"
    if gh run cancel "$run_id" --force --repo "$repo"; then
        force_cancelled_runs+=("$run_id")
    else
        status="$(gh run view "$run_id" --repo "$repo" --json status --jq .status)"
        if [ "$status" != completed ]; then
            printf 'Could not force-cancel workflow run %s (status: %s)\n' \
                "$run_id" "$status" >&2
            exit 1
        fi
    fi
done

for ((attempt = 0; attempt < 3 && ${#force_cancelled_runs[@]} > 0; attempt++)); do
    remaining_runs=()
    for run_id in "${force_cancelled_runs[@]}"; do
        status="$(gh run view "$run_id" --repo "$repo" --json status --jq .status)"
        if [ "$status" != completed ]; then
            remaining_runs+=("$run_id")
        else
            printf 'Cancelled workflow run %s\n' "$run_id"
        fi
    done
    force_cancelled_runs=(${remaining_runs[@]+"${remaining_runs[@]}"})
    [ "${#force_cancelled_runs[@]}" -eq 0 ] || sleep 1
done

if [ "${#force_cancelled_runs[@]}" -gt 0 ]; then
    printf 'Workflow runs did not finish cancelling: %s\n' \
        "${force_cancelled_runs[*]}" >&2
    exit 1
fi
