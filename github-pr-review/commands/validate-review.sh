#!/usr/bin/env bash
# Helper command: Validate review JSON before posting
# Usage: ./validate-review.sh <pr_number> <json_file> [owner/repo]
#
# Example:
#   ./validate-review.sh 6 /tmp/review_comments.json
#
# Validates that each comment has a path, a body, and exactly one anchor
# (`line` - preferred - or the legacy `position`).

set -uo pipefail

PR_NUMBER="${1:-}"
JSON_FILE="${2:-}"
REPO_ARG="${3:-${GH_REPO:-}}"

if [ -z "$PR_NUMBER" ] || [ -z "$JSON_FILE" ]; then
  echo "Usage: $0 <pr_number> <json_file> [owner/repo]"
  exit 2
fi

if [ ! -f "$JSON_FILE" ]; then
  echo "Error: File not found: $JSON_FILE"
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required for this validator but was not found."
  echo "  Install with: brew install gh jq   (or: apt-get install jq)"
  echo ""
  echo "Without jq, validate by hand before posting:"
  echo "  - every comment has a non-empty 'path' and 'body'"
  echo "  - every comment has exactly one of 'line' (preferred) or 'position'"
  echo "  - after posting, verify anchoring (see SKILL.md: Verify Anchoring After Posting)"
  exit 2
fi

echo "Validating review for PR #$PR_NUMBER"
echo "===================================="
echo ""

FAILED=0

echo "1. Validating JSON structure..."
if jq empty "$JSON_FILE" 2>/dev/null; then
  echo "   OK  JSON is valid"
else
  echo "   ERR Invalid JSON"
  exit 1
fi

echo ""
echo "2. Checking required fields..."
if jq -e '.commit_id' "$JSON_FILE" >/dev/null 2>&1; then
  echo "   OK  commit_id present: $(jq -r '.commit_id' "$JSON_FILE")"
else
  echo "   ERR Missing commit_id"
  FAILED=1
fi

if jq -e '.comments | type == "array"' "$JSON_FILE" >/dev/null 2>&1; then
  echo "   OK  comments array present: $(jq '.comments | length' "$JSON_FILE") comment(s)"
else
  echo "   ERR Missing or invalid comments array"
  exit 1
fi

echo ""
echo "3. Validating each comment..."
# NOTE: iterate over a here-string, NOT a pipe. A `while read` on the right side of
# a pipe runs in a subshell, so failures set FAILED in a copy that is then discarded.
# NOTE: never name a shell variable PATH - assigning it destroys the command search
# path and every later command fails with "command not found".
while IFS= read -r comment; do
  [ -z "$comment" ] && continue
  C_PATH=$(printf '%s' "$comment" | jq -r '.path // empty')
  C_LINE=$(printf '%s' "$comment" | jq -r '.line // empty')
  C_POS=$(printf '%s' "$comment" | jq -r '.position // empty')
  C_BODY=$(printf '%s' "$comment" | jq -r '.body // empty')

  if [ -z "$C_PATH" ]; then
    echo "   ERR Comment missing 'path' field"; FAILED=1; continue
  fi

  if [ -n "$C_LINE" ] && [ -n "$C_POS" ]; then
    echo "   ERR $C_PATH has both 'line' and 'position' - use one (prefer 'line')"
    FAILED=1; continue
  fi

  ANCHOR_KIND="line"; ANCHOR="$C_LINE"
  if [ -z "$C_LINE" ]; then ANCHOR_KIND="position"; ANCHOR="$C_POS"; fi

  if [ -z "$ANCHOR" ]; then
    echo "   ERR Comment on '$C_PATH' has neither 'line' nor 'position'"
    FAILED=1; continue
  fi

  if ! printf '%s' "$ANCHOR" | grep -qE '^[0-9]+$'; then
    echo "   ERR $C_PATH has invalid $ANCHOR_KIND: '$ANCHOR' (must be a number)"
    FAILED=1; continue
  fi

  if [ -z "$C_BODY" ]; then
    echo "   ERR $C_PATH at $ANCHOR_KIND $ANCHOR missing 'body' field"
    FAILED=1; continue
  fi

  if [ "$ANCHOR_KIND" = "position" ]; then
    echo "   OK  $C_PATH:$ANCHOR_KIND=$ANCHOR (legacy anchor - prefer 'line')"
  else
    echo "   OK  $C_PATH:$ANCHOR_KIND=$ANCHOR"
  fi
done <<< "$(jq -c '.comments[]' "$JSON_FILE")"

echo ""
echo "4. Checking that each path exists in the PR..."
if [ -n "$REPO_ARG" ]; then
  REPO="$REPO_ARG"
else
  REPO="$(gh repo view --json owner,name --jq '.owner.login + "/" + .name' 2>/dev/null)"
fi

if [ -z "${REPO:-}" ]; then
  echo "   SKIP could not resolve a repository (pass owner/repo as the 3rd argument)"
else
  # `gh pr diff <n> --name-only` is unreliable for this; ask the API directly.
  PR_FILES="$(gh api --paginate "repos/$REPO/pulls/$PR_NUMBER/files" --jq '.[].filename' 2>/dev/null)"
  if [ -z "$PR_FILES" ]; then
    echo "   SKIP could not list files for PR #$PR_NUMBER in $REPO"
  else
    while IFS= read -r path; do
      [ -z "$path" ] && continue
      if printf '%s\n' "$PR_FILES" | grep -qxF "$path"; then
        echo "   OK  $path"
      else
        echo "   ERR $path is not in the PR diff (wrong path?)"
        FAILED=1
      fi
    done <<< "$(jq -r '.comments[].path' "$JSON_FILE" | sort -u)"
  fi
fi

echo ""
if [ "$FAILED" -ne 0 ]; then
  echo "VALIDATION FAILED - fix the errors above before posting."
  exit 1
fi

echo "Validation passed."
echo ""
echo "Reminder: this checks the payload, not where comments land. After posting,"
echo "verify anchoring (SKILL.md: Verify Anchoring After Posting) before telling"
echo "the user the review is done."
