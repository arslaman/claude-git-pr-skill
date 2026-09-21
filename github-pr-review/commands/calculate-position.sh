#!/usr/bin/env bash
# Show the diff for a file with BOTH the file line number and the diff position.
#
# Usage: ./calculate-position.sh <pr_number> <file_path> [owner/repo]
#
# The repo defaults to the current directory's; pass owner/repo (or set GH_REPO)
# when running from outside the target checkout.
#
# Prefer the "line" column: anchor review comments with `line` + `side` and let
# GitHub compute the position itself. The "pos" column is only for the legacy
# `position` field.
#
# Position rules (legacy): position 1 is the first line AFTER the first @@ header;
# the first header is not a position, but each SUBSEQUENT @@ header consumes one.

set -euo pipefail

PR_NUMBER="${1:-}"
FILE_PATH="${2:-}"
REPO_ARG="${3:-${GH_REPO:-}}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

if [ -z "$PR_NUMBER" ] || [ -z "$FILE_PATH" ]; then
  echo -e "${RED}Error: Missing arguments${NC}" >&2
  echo "Usage: $0 <pr_number> <file_path> [owner/repo]" >&2
  exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
  echo -e "${RED}Error: gh CLI not found. Install from https://cli.github.com/${NC}" >&2
  exit 2
fi

echo -e "${BLUE}Positions for: $FILE_PATH in PR #$PR_NUMBER${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

if [ -n "$REPO_ARG" ]; then
  REPO="$REPO_ARG"
else
  REPO="$(gh repo view --json owner,name --jq '.owner.login + "/" + .name')" || {
    echo -e "${RED}Error: could not resolve a repository. Pass owner/repo as the 3rd argument.${NC}" >&2
    exit 1
  }
fi

# NOTE: `gh pr diff <n> -- <path>` does NOT support a pathspec; it exits non-zero.
# Fetch the per-file patch from the API instead (gh's built-in --jq needs no system jq).
PATCH="$(gh api --paginate "repos/$REPO/pulls/$PR_NUMBER/files" \
  --jq ".[] | select(.filename == \"$FILE_PATH\") | .patch")" || {
  echo -e "${RED}Error: API request failed for PR #$PR_NUMBER in $REPO.${NC}" >&2
  exit 1
}

if [ -z "$PATCH" ]; then
  echo -e "${RED}File '$FILE_PATH' has no patch in PR #$PR_NUMBER.${NC}" >&2
  echo -e "${YELLOW}(Binary files and pure renames have no patch. Check the path below.)${NC}" >&2
  echo "" >&2
  echo -e "${BLUE}Files in this PR:${NC}" >&2
  gh api --paginate "repos/$REPO/pulls/$PR_NUMBER/files" --jq '.[].filename' >&2
  exit 1
fi

printf '%s\n' "$PATCH" | awk \
  -v red="$RED" -v green="$GREEN" -v blue="$BLUE" -v cyan="$CYAN" -v nc="$NC" '
BEGIN { position = 0; newline = 0; seen_hunk = 0 }

/^@@/ {
  # Each subsequent hunk header consumes one position; the first one does not.
  if (seen_hunk) position++
  seen_hunk = 1
  # Parse the new-file start line from "@@ -a,b +c,d @@"
  if (match($0, /\+[0-9]+/)) newline = substr($0, RSTART + 1, RLENGTH - 1) + 0
  print blue $0 nc
  next
}

seen_hunk {
  position++
  prefix = substr($0, 1, 1)
  rest = substr($0, 2)
  if (prefix == "-") {
    # Removed lines occupy a position but have no new-file line number.
    printf cyan "line    -  pos %3d: " nc red "-%s" nc "\n", position, rest
  } else if (prefix == "+") {
    printf cyan "line %4d  pos %3d: " nc green "+%s" nc "\n", newline, position, rest
    newline++
  } else {
    printf cyan "line %4d  pos %3d: " nc "  %s\n", newline, position, rest
    newline++
  }
  next
}

{ print $0 }
'

echo ""
echo -e "${YELLOW}Key:${NC}"
echo -e "  ${GREEN}line${NC} -> pass as \"line\" with \"side\": \"RIGHT\"  ${CYAN}(recommended)${NC}"
echo -e "  ${GREEN}pos${NC}  -> pass as \"position\" (legacy only)"
