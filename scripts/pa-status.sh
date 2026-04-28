#!/usr/bin/env bash
# pa-status.sh — show what the hook would do for the current directory.
#
# Resolves CWD against the project-accounts mapping using the same
# longest-prefix-wins logic as the hook, then prints which project/env
# matched, which credentials would be injected (with @file: paths and
# readability), and which services are registered.
#
# Read-only — never mutates the mapping.

set -euo pipefail

MAPPING="${HOME}/.claude/project-accounts.json"
SECRETS_DIR="${HOME}/.claude/secrets"
CWD="${1:-$PWD}"

if [ ! -f "$MAPPING" ]; then
  printf 'pa-status: mapping not found at %s\n' "$MAPPING" >&2
  printf '  (it is created automatically the first time the hook runs)\n' >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  printf 'pa-status: jq is required\n' >&2
  exit 1
fi

# --- helpers ---------------------------------------------------------------

# Expand a leading ~ in a path (no jq-style $HOME assumption).
expand_tilde() {
  local p="$1"
  case "$p" in
    "~/"*) printf '%s' "${HOME}${p#\~}" ;;
    "~")   printf '%s' "$HOME" ;;
    *)     printf '%s' "$p" ;;
  esac
}

# Validate an ssh alias name. Strict — disallows spaces, =, *, ?, leading -,
# anything that ssh might interpret as a flag or pattern. The alias is passed
# to `ssh -G`; rejecting metacharacters here keeps that call's surface small
# even though we also use `--` as a defensive separator.
valid_ssh_alias() {
  case "$1" in
    ''|-*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Extract a single key's value from `ssh -G` output. ssh -G emits lowercased
# keys, one per line, space-separated. First match wins — same as ssh's own
# first-match rule for Host blocks.
ssh_g_value() {
  awk -v k="$1" '$1 == k { $1=""; sub(/^ /, ""); print; exit }'
}

# --- resolve current project ----------------------------------------------

MATCH_JSON="$(jq -r --arg cwd "$CWD" '
  [
    (.projects // {}) | to_entries[]
    | .key as $pname
    | (.value.repos // {}) | to_entries[]
    | {project: $pname, repo: .key, path: .value}
  ]
  | map(select(.path as $p | $cwd == $p or ($cwd | startswith($p + "/"))))
  | sort_by(.path | length) | reverse
  | .[0] // null
' "$MAPPING")"

printf 'CWD: %s\n' "$CWD"
printf 'Mapping: %s\n\n' "$MAPPING"

if [ "$MATCH_JSON" = "null" ]; then
  printf 'No project matches this directory.\n\n'
  printf 'Registered projects:\n'
  jq -r '
    (.projects // {}) | to_entries[]
    | .key as $name
    | "  " + $name +
      (
        if (.value.repos // {} | length) > 0
        then "  repos: " + ((.value.repos // {}) | to_entries | map(.key + "=" + .value) | join(", "))
        else "  (no repos registered — name-only)"
        end
      )
  ' "$MAPPING"
  exit 0
fi

PROJECT="$(jq -r '.project' <<<"$MATCH_JSON")"
REPO="$(jq -r '.repo' <<<"$MATCH_JSON")"
REPO_PATH="$(jq -r '.path' <<<"$MATCH_JSON")"

printf 'Project: %s  (matched via repos.%s = %s)\n' "$PROJECT" "$REPO" "$REPO_PATH"
printf 'Auto-inject env: dev\n\n'

# --- dev credentials ------------------------------------------------------

CRED_PAIRS="$(jq -r --arg p "$PROJECT" '
  (.projects[$p].envs.dev.credentials // {}) | to_entries[] | [.key, .value] | @tsv
' "$MAPPING")"

if [ -z "$CRED_PAIRS" ]; then
  printf 'Credentials in dev: (none — hook will not inject anything)\n'
else
  printf 'Credentials in dev:\n'
  while IFS=$'\t' read -r key value; do
    [ -z "$key" ] && continue
    # Empty value: hook would skip with reason "empty-value". Surface that
    # here so status reflects the runtime hook behaviour.
    if [ -z "$value" ]; then
      printf '  %s  (empty — hook will skip)\n' "$key"
      continue
    fi
    if [[ "$value" == @file:* ]]; then
      filepath="$(expand_tilde "${value#@file:}")"
      if [ -r "$filepath" ]; then
        size=$(wc -c < "$filepath" 2>/dev/null | tr -d ' ')
        perms=$(stat -f '%Sp' "$filepath" 2>/dev/null || stat -c '%A' "$filepath" 2>/dev/null)
        printf '  %s  @file:%s  [%s, %s bytes]\n' "$key" "$filepath" "$perms" "$size"
      else
        printf '  %s  @file:%s  [MISSING or unreadable]\n' "$key" "$filepath"
      fi
    else
      expanded="$(expand_tilde "$value")"
      # Match the doctor's rule: only absolute (/...) or tilde (~/...) values
      # are recognised as paths. Relative paths have no defined base.
      if [[ "$value" == /* ]] || [ "$expanded" != "$value" ]; then
        if [ -e "$expanded" ]; then
          perms=$(stat -f '%Sp' "$expanded" 2>/dev/null || stat -c '%A' "$expanded" 2>/dev/null)
          printf '  %s  %s  [path, %s]\n' "$key" "$expanded" "$perms"
        else
          printf '  %s  %s  [path, MISSING]\n' "$key" "$expanded"
        fi
      else
        printf '  %s  %s\n' "$key" "$value"
      fi
    fi
  done <<<"$CRED_PAIRS"
fi

# --- dev services ---------------------------------------------------------

printf '\n'
SVC_KEYS="$(jq -r --arg p "$PROJECT" '
  (.projects[$p].envs.dev.services // {}) | keys[]
' "$MAPPING")"

if [ -z "$SVC_KEYS" ]; then
  printf 'Services in dev: (none)\n'
else
  printf 'Services in dev:\n'
  while IFS= read -r svc; do
    [ -z "$svc" ] && continue
    spec="$(jq -c --arg p "$PROJECT" --arg s "$svc" \
      '.projects[$p].envs.dev.services[$s]' "$MAPPING")"
    platform="$(jq -r '.platform // "?"' <<<"$spec")"
    if [ "$platform" = "ssh" ]; then
      alias_name="$(jq -r '.ssh_alias // ""' <<<"$spec")"
      if [ -n "$alias_name" ]; then
        if ! valid_ssh_alias "$alias_name"; then
          printf '  %s [ssh] %s (alias) — invalid alias name (allowed: A-Z a-z 0-9 . _ -, no leading -)\n' \
            "$svc" "$alias_name"
          continue
        fi
        cfg="$(ssh -G -- "$alias_name" 2>/dev/null || true)"
        if [ -z "$cfg" ]; then
          printf '  %s [ssh] %s (alias) — could not resolve via ssh -G\n' "$svc" "$alias_name"
          continue
        fi
        rhost="$(printf '%s\n' "$cfg" | ssh_g_value hostname)"
        ruser="$(printf '%s\n' "$cfg" | ssh_g_value user)"
        rid="$(printf '%s\n' "$cfg" | ssh_g_value identityfile)"
        rport="$(printf '%s\n' "$cfg" | ssh_g_value port)"
        # If hostname == alias literal, ssh -G found no Host block matching the
        # alias and just echoed it back. Surface that here so the user knows
        # ~/.ssh/config is missing the entry.
        if [ "$rhost" = "$alias_name" ]; then
          printf '  %s [ssh] %s (alias) — not found in ~/.ssh/config (hostname did not resolve)\n' \
            "$svc" "$alias_name"
        else
          printf '  %s [ssh] %s → %s@%s:%s  (identity=%s)\n' \
            "$svc" "$alias_name" "$ruser" "$rhost" "$rport" "${rid:-—}"
        fi
      else
        user="$(jq -r '.user // "?"' <<<"$spec")"
        host="$(jq -r '.host // "?"' <<<"$spec")"
        key="$(jq -r '.key // "?"' <<<"$spec")"
        printf '  %s [ssh] %s@%s  (key=%s)\n' "$svc" "$user" "$host" "$key"
      fi
    else
      target="$(jq -r '.service // .instance // "—"' <<<"$spec")"
      printf '  %s [%s] %s\n' "$svc" "$platform" "$target"
    fi
  done <<<"$SVC_KEYS"
fi

# --- non-dev envs (info only) --------------------------------------------

printf '\n'
NONDEV="$(jq -r --arg p "$PROJECT" '
  (.projects[$p].envs // {}) | keys | map(select(. != "dev")) | join(", ")
' "$MAPPING")"
if [ -n "$NONDEV" ]; then
  printf 'Other envs (name-only, not auto-injected): %s\n' "$NONDEV"
fi
