#!/usr/bin/env bash
# pa-update.sh — safely mutate ~/.claude/project-accounts.json
#
# Wraps a jq filter with: timestamped backup, mktemp staging in the
# mapping's own directory, JSON validation, atomic replace, chmod 600.
#
# Usage:
#   pa-update.sh [jq args ...] '<jq filter>'
#
# All arguments are forwarded to jq verbatim, so --arg / --argjson work
# the same as a raw jq call. Example:
#   pa-update.sh --arg p "acme" --arg e "dev" \
#     '.projects[$p].envs[$e].credentials.AWS_PROFILE = "acme-dev"'
#
# Backups live in ~/.claude/project-accounts.backups/ (chmod 700);
# only the 20 most recent are kept.

set -euo pipefail

MAPPING="${HOME}/.claude/project-accounts.json"
BACKUP_DIR="${HOME}/.claude/project-accounts.backups"
KEEP=20

if [ ! -f "$MAPPING" ]; then
  printf 'pa-update: mapping not found at %s\n' "$MAPPING" >&2
  printf '  (it is created automatically the first time the hook runs)\n' >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'pa-update: jq is not installed (required to read/write the mapping)\n' >&2
  exit 1
fi

if [ "$#" -eq 0 ]; then
  printf 'pa-update: missing jq filter argument\n' >&2
  printf '  example: pa-update.sh --arg p acme '"'"'.projects[$p].envs.dev = {}'"'"'\n' >&2
  exit 2
fi

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

ts="$(date +%Y%m%d-%H%M%S)"
backup="$BACKUP_DIR/project-accounts.$ts.json"
cp "$MAPPING" "$backup"
chmod 600 "$backup"

# Prune older backups, keeping only the most recent $KEEP.
# Use a portable approach: list newest first, skip the first $KEEP, delete the rest.
# shellcheck disable=SC2012
ls -1t "$BACKUP_DIR"/project-accounts.*.json 2>/dev/null \
  | awk -v keep="$KEEP" 'NR>keep' \
  | while IFS= read -r f; do rm -f -- "$f"; done

# Stage the new mapping in the same directory so the final mv is atomic.
tmp="$(mktemp "${MAPPING}.new.XXXXXX")"
trap 'rm -f -- "$tmp"' EXIT

if ! jq "$@" "$MAPPING" >"$tmp"; then
  printf 'pa-update: jq filter failed; mapping left unchanged (backup at %s)\n' "$backup" >&2
  exit 1
fi

if ! jq empty "$tmp" >/dev/null 2>&1; then
  printf 'pa-update: jq output is not valid JSON; refusing to replace mapping (backup at %s)\n' "$backup" >&2
  exit 1
fi

mv -- "$tmp" "$MAPPING"
chmod 600 "$MAPPING"
trap - EXIT

printf 'pa-update: ok (backup: %s)\n' "$backup"
