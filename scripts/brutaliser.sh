#!/usr/bin/env bash
set -euo pipefail
#
# brutaliser -- keep pull requests small.
#
# Fails CI when a pull request's diff exceeds a LOC budget, ignoring generated
# files and schemas. Oversized pull requests are immediately converted back to
# draft and gated behind a review count.
#
# Usage:
#   brutaliser.sh [check|approvals|configure]

# Environment:
#   TARGET              Base branch to diff against        (default: main)
#   BASE_SHA            Explicit base commit, overrides TARGET
#   HEAD_REF            Ref holding the PR head             (default: HEAD)
#   LOC_THRESHOLD       Maximum allowed LOC                 (default: 500)
#   LOC_COUNTS          net | total | added | deleted      (default: net)

#   REQUIRED_APPROVALS  Approvals needed once oversized     (default: 3)
#   MARK_DRAFT          true | false                        (default: true)
#   LABEL               Label applied when oversized        (default: brutal-large)
#   PR                  Pull request number, for gh mutations
#   EXCLUDE_FILE        Regex ignore file                   (default: .locguardignore)
#   EXCLUDES            Colon-separated extra regexes
#   DRY_RUN             true | false                        (default: false)

TARGET="${TARGET:-main}"
BASE_SHA="${BASE_SHA:-}"
HEAD_REF="${HEAD_REF:-HEAD}"
LOC_THRESHOLD="${LOC_THRESHOLD:-500}"
LOC_COUNTS="${LOC_COUNTS:-net}"
REQUIRED_APPROVALS="${REQUIRED_APPROVALS:-3}"
MARK_DRAFT="${MARK_DRAFT:-true}"
LABEL="${LABEL:-brutal-large}"
EXCLUDE_FILE="${EXCLUDE_FILE:-.locguardignore}"
DRY_RUN="${DRY_RUN:-false}"

info() { printf '%s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
	cat <<'EOF'
brutaliser -- fail a pull request when its diff is too large.

Usage:
  brutaliser.sh check        Measure the diff and enforce the budget.
  brutaliser.sh approvals    Fail unless an oversized PR has enough approvals.
  brutaliser.sh configure    Set the required approval count on the target branch.

See the header of this file for the environment variables that tune it.
EOF
}

# Paths that never count towards the budget: generated output, schemas, locks,
# vendored trees, snapshots, binaries.
EXCLUDE_RE=(
	'(^|/)(node_modules|vendor|third_party|dist|build|target|out|coverage|__generated__|generated|gen)/'
	'\.(min\.js|min\.css|map)$'
	'\.(json|json5|jsonc|yaml|yml|lock|sum|snap)$'
	'\.(proto|avro|xsd|graphql|gql|thrift|capnp|fbs)$'
	'\.(svg|svgz|png|jpe?g|gif|ico|webp|pdf|woff2?|ttf|eot|mp4|webm|wasm|pb|bin|parquet|csv|tsv)$'
	'\.(generated|gen)\.(rs|go|ts|tsx|js|jsx|py|java|kt|cs|swift|dart)$'
	'(^|/)(migrations|fixtures|testdata|snapshots|golden|__snapshots__)/'
)

load_excludes() {
	local line

	if [[ -n "${EXCLUDES:-}" ]]; then
		local -a extra
		IFS=':' read -r -a extra <<<"$EXCLUDES"
		EXCLUDE_RE+=("${extra[@]}")
	fi

	[[ -f "$EXCLUDE_FILE" ]] || return 0

	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ -z "$line" || "$line" == \#* ]] && continue
		EXCLUDE_RE+=("$line")
	done <"$EXCLUDE_FILE"
}

# Honours `.gitattributes` linguist-generated markers from the PR head tree.
linguist_generated() {
	local path="$1" out value
	out="$(git check-attr --source="$HEAD_REF" linguist-generated -- "$path" 2>/dev/null || true)"
	value="${out##*: }"
	[[ "$value" == "set" || "$value" == "true" ]]
}

is_excluded() {
	local path="$1" re
	for re in "${EXCLUDE_RE[@]}"; do
		if [[ "$path" =~ $re ]]; then
			return 0
		fi
	done
	linguist_generated "$path"
}

pr_has_label() {
	local pr="${PR:-}" label="$1"
	[[ -n "$pr" ]] || return 1
	gh pr view "$pr" --json labels --jq '.labels[].name' 2>/dev/null | grep -qxF "$label"
}

add_label() {
	local pr="${PR:-}"
	[[ -n "$pr" ]] || {
		warn "PR not set, skipping label"
		return 0
	}
	[[ "$DRY_RUN" == "true" ]] && {
		info "dry-run: would add label ${LABEL}"
		return 0
	}

	gh label create "$LABEL" --description "Pull request exceeds the LOC budget" --color B60205 --force >/dev/null 2>&1 || true
	gh pr edit "$pr" --add-label "$LABEL" >/dev/null 2>&1 || warn "could not add label ${LABEL}"
}

mark_draft() {
	local pr="${PR:-}" is_draft out

	[[ "$MARK_DRAFT" == "true" ]] || return 0
	[[ -n "$pr" ]] || {
		warn "PR not set, skipping draft"
		return 0
	}
	[[ "$DRY_RUN" == "true" ]] && {
		info "dry-run: would mark #${pr} as draft"
		return 0
	}

	is_draft="$(gh pr view "$pr" --json isDraft --jq '.isDraft' 2>/dev/null || printf 'false')"
	if [[ "$is_draft" == "true" ]]; then
		info "already a draft"
		return 0
	fi

	if ! out="$(gh pr ready "$pr" --undo 2>&1)"; then
		warn "could not convert #${pr} to draft: ${out}"
	fi
}

approval_count() {
	gh pr view "${PR:?PR is required}" --json reviews \
		--jq '[.reviews[] | select(.state == "APPROVED") | .author.login] | unique | length'
}

diff_range() {
	if [[ -n "$BASE_SHA" ]]; then
		printf '%s...%s' "$BASE_SHA" "$HEAD_REF"
	else
		printf 'origin/%s...%s' "$TARGET" "$HEAD_REF"
	fi
}

do_check() {
	local range added deleted path measured counted=0 excluded=0
	local total_added=0 total_deleted=0
	local -a rows=()

	range="$(diff_range)"
	info "brutaliser: diffing ${range}"
	load_excludes

	while IFS=$'\t' read -r added deleted path; do
		[[ -n "$path" ]] || continue
		if [[ "$added" == "-" || "$deleted" == "-" ]]; then
			continue
		fi
		if is_excluded "$path"; then
			excluded=$((excluded + 1))
			continue
		fi
		counted=$((counted + 1))
		total_added=$((total_added + added))
		total_deleted=$((total_deleted + deleted))
		rows+=("$((added + deleted))"$'\t'"$path")
	done < <(git diff --numstat --no-renames "$range")

	case "$LOC_COUNTS" in
	added) measured="$total_added" ;;
	deleted) measured="$total_deleted" ;;
	total) measured=$((total_added + total_deleted)) ;;
	net) measured=$((total_added - total_deleted)) ;;
	*) die "LOC_COUNTS must be net, total, added, or deleted" ;;
	esac

	info "brutaliser: ${measured} LOC net (+${total_added}/-${total_deleted}) over ${counted} counted files, ${excluded} excluded, budget ${LOC_THRESHOLD}"

	if ((measured <= LOC_THRESHOLD)); then
		info "brutaliser: within budget"
		return 0
	fi

	warn "brutaliser: over budget by $((measured - LOC_THRESHOLD)) LOC"
	printf '%s\n' "${rows[@]}" | sort -t$'\t' -k1,1nr | head -n 10 |
		while IFS=$'\t' read -r churn file; do
			printf '  %6s  %s\n' "$churn" "$file" >&2
		done

	add_label
	mark_draft
	info "brutaliser: pull request ${PR:-?} failed the LOC budget (${measured} > ${LOC_THRESHOLD})"
	exit 1
}

do_approvals() {
	local count
	[[ -n "${PR:-}" ]] || die "PR is required"

	if ! pr_has_label "$LABEL"; then
		info "brutaliser: no ${LABEL} label, approvals not enforced"
		return 0
	fi

	count="$(approval_count)"
	info "brutaliser: ${count}/${REQUIRED_APPROVALS} approvals from distinct reviewers"
	if ((count < REQUIRED_APPROVALS)); then
		warn "brutaliser: ${REQUIRED_APPROVALS} approvals required for oversized pull requests"
		exit 1
	fi
}

do_configure() {
	info "brutaliser: setting required approvals to ${REQUIRED_APPROVALS} on '${TARGET}'"
	gh api --method PUT \
		"repos/{owner}/{repo}/branches/${TARGET}/protection/required_pull_request_reviews" \
		-F required_approving_review_count="$REQUIRED_APPROVALS" >/dev/null
	info "brutaliser: done"
}

main() {
	case "${1:-check}" in
	check) do_check ;;
	approvals) do_approvals ;;
	configure) do_configure ;;
	-h | --help | help) usage ;;
	*) usage >&2; exit 64 ;;
	esac
}

main "$@"
