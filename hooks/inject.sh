#!/usr/bin/env bash
# project-accounts plugin: PreToolUse hook for Bash.
# When CWD matches a repo path under any projects[P].repos in
# ~/.claude/project-accounts.json, prepends `export KEY=value && ` to
# the bash command using credentials from projects[P].envs.dev.credentials.
# Dev-only by design — prod and other envs require explicit name-based
# invocation (the project-accounts skill handles those).
# Secret values of the form "@file:<path>" are read from disk at call time.

set -uo pipefail

MAPPING_FILE="${HOME}/.claude/project-accounts.json"
SECRETS_DIR="${HOME}/.claude/secrets"
AUTO_ENV="dev"

# First-run bootstrap: create empty stub so users have something to edit.
if [ ! -f "$MAPPING_FILE" ]; then
  mkdir -p "$(dirname "$MAPPING_FILE")"
  cat > "$MAPPING_FILE" <<'EOF'
{
  "_doc": "Per-project CLI credentials and deployment targets. See the project-accounts skill for the schema and management commands.",
  "_policy": "Hook auto-injects envs.dev.credentials when CWD matches a repo path. Prod and other envs require explicit name-based invocation (never auto-injected).",
  "managed_clis": ["aws", "railway", "vercel", "gcloud", "doctl", "flyctl", "heroku", "supabase"],
  "projects": {}
}
EOF
fi
# Tighten perms on the mapping file every run — covers freshly-bootstrapped
# files and existing ones from older versions that may have shipped 0644.
chmod 600 "$MAPPING_FILE" 2>/dev/null || true
mkdir -p "$SECRETS_DIR" 2>/dev/null && chmod 700 "$SECRETS_DIR" 2>/dev/null

INPUT="$(cat)"
CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty')"
CWD="${CWD:-$PWD}"

[ -n "$CMD" ] || exit 0

# managed_clis entries flow into a grep -E pattern, so each name must be
# regex-safe. Filter to plain executable names — letters, digits, underscore,
# dash. Anything else (whitespace, regex metachars, slashes) is silently
# dropped before the pattern is built.
CLI_PATTERN="$(jq -r '
  (.managed_clis // [])
  | map(select(type == "string" and test("^[A-Za-z][A-Za-z0-9_-]*$")))
  | join("|")
' "$MAPPING_FILE" 2>/dev/null)"
[ -n "$CLI_PATTERN" ] || exit 0

# Only intervene if the command contains a managed CLI as a shell token.
if ! printf '%s' "$CMD" | grep -Eq "(^|[[:space:];&|()\`]+)(${CLI_PATTERN})([[:space:]]|$)"; then
  exit 0
fi

# Find best-matching (project, repo) by longest prefix of CWD against repo paths.
PROJECT="$(jq -r --arg cwd "$CWD" '
  [
    (.projects // {}) | to_entries[]
    | .key as $pname
    | (.value.repos // {}) | to_entries[]
    | {project: $pname, path: .value}
  ]
  | map(select(.path as $p | $cwd == $p or ($cwd | startswith($p + "/"))))
  | sort_by(.path | length) | reverse
  | (.[0].project // "")
' "$MAPPING_FILE")"
[ -n "$PROJECT" ] || exit 0

# Identify which managed CLI is actually invoked, then verify it's installed.
# Only run this guard when the CWD already matched a project — we don't want
# to nag users who run `aws`/`vercel`/etc. outside any registered repo. Same
# regex-safe filter as CLI_PATTERN.
INVOKED_CLI=""
while IFS= read -r cli; do
  [ -z "$cli" ] && continue
  if printf '%s' "$CMD" | grep -Eq "(^|[[:space:];&|()\`]+)${cli}([[:space:]]|$)"; then
    INVOKED_CLI="$cli"
    break
  fi
done < <(jq -r '
  (.managed_clis // [])
  | map(select(type == "string" and test("^[A-Za-z][A-Za-z0-9_-]*$")))
  | .[]
' "$MAPPING_FILE" 2>/dev/null)

if [ -n "$INVOKED_CLI" ] && ! command -v "$INVOKED_CLI" >/dev/null 2>&1; then
  case "$INVOKED_CLI" in
    aws)      HINT="brew install awscli  (or: pip install awscli)" ;;
    vercel)   HINT="npm i -g vercel" ;;
    railway)  HINT="brew install railway  (or: npm i -g @railway/cli)" ;;
    gcloud)   HINT="brew install --cask google-cloud-sdk" ;;
    flyctl)   HINT="brew install flyctl" ;;
    doctl)    HINT="brew install doctl" ;;
    heroku)   HINT="brew tap heroku/brew && brew install heroku" ;;
    supabase) HINT="brew install supabase/tap/supabase" ;;
    *)        HINT="install $INVOKED_CLI for your platform" ;;
  esac
  jq -n \
    --arg cli "$INVOKED_CLI" \
    --arg project "$PROJECT" \
    --arg hint "$HINT" \
    '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: ("[project-accounts] " + $cli + " CLI is not installed on this machine (project=" + $project + "). Install hint: " + $hint)
      }
    }'
  exit 0
fi

ENV_PAIRS="$(jq -r --arg p "$PROJECT" --arg e "$AUTO_ENV" '
  (.projects[$p].envs[$e].credentials // {}) | to_entries[] | [.key, .value] | @tsv
' "$MAPPING_FILE")"
[ -n "$ENV_PAIRS" ] || exit 0

EXPORT_ARGS=()
APPLIED=()
SKIPPED=()  # entries of the form "KEY(reason)" so debugging surfaces silent skips
# Match POSIX env-var name format. Anything outside this is silently dropped:
# keys flow into both a grep -E pattern and an `export KEY=...` assembly, and
# accepting metacharacters here would let a malformed mapping run arbitrary
# shell. Defence-in-depth — the mapping is chmod 600, so this is only a
# last-line guard against typos / paste accidents in pa-update calls.
KEY_NAME_RE='^[A-Za-z_][A-Za-z0-9_]*$'
while IFS=$'\t' read -r key value; do
  [ -z "$key" ] && continue
  if ! [[ "$key" =~ $KEY_NAME_RE ]]; then
    SKIPPED+=("$(printf '%q' "$key")(invalid-key)")
    continue
  fi
  # Respect explicit user overrides already in the command. Key has been
  # validated above, so it's safe to embed in the grep pattern.
  if printf '%s' "$CMD" | grep -Eq "(^|[[:space:];&|()]+)${key}="; then
    SKIPPED+=("${key}(override-in-command)")
    continue
  fi
  if [[ "$value" == @file:* ]]; then
    filepath="${value#@file:}"
    filepath="${filepath/#\~/$HOME}"
    # Verify readable at hook time, but never embed the secret content in the
    # rewritten command. Embed `$(cat <path>)` instead so the actual secret is
    # only materialised inside the bash subshell at exec time — it never lands
    # in the hook output, transcripts, or PreToolUse logs.
    if [ ! -r "$filepath" ]; then
      SKIPPED+=("${key}(unreadable:${filepath})")
      continue
    fi
    printf -v quoted_path "%q" "$filepath"
    # tr strips any trailing CR/LF that the secret file might carry.
    EXPORT_ARGS+=("${key}=\"\$(tr -d '\\r\\n' < ${quoted_path})\"")
    APPLIED+=("$key")
    continue
  fi
  # Expand leading ~ for path-style values (PEM keys, kubeconfig, etc.).
  case "$value" in
    "~/"*) value="${HOME}${value#\~}" ;;
    "~")   value="$HOME" ;;
  esac
  if [ -z "$value" ]; then
    SKIPPED+=("${key}(empty-value)")
    continue
  fi
  printf -v escaped "%q" "$value"
  EXPORT_ARGS+=("${key}=${escaped}")
  APPLIED+=("$key")
done <<< "$ENV_PAIRS"

# Build a status string even when nothing was injected, so the user can see why
# the hook matched the project but didn't change the command. The :+ guard
# avoids the bash `set -u` empty-array expansion error.
APPLIED_STR="$( [ "${#APPLIED[@]}" -gt 0 ] && (IFS=,; printf '%s' "${APPLIED[*]}") )"
SKIPPED_STR="$( [ "${#SKIPPED[@]}" -gt 0 ] && (IFS=,; printf '%s' "${SKIPPED[*]}") )"
if [ "${#APPLIED[@]}" -eq 0 ]; then
  # Project matched but nothing injected — surface why so the user can debug
  # without having to run `pa status`.
  STATUS_MSG="[project-accounts] ${PROJECT} (${AUTO_ENV}) → no vars injected"
  if [ -n "$SKIPPED_STR" ]; then
    STATUS_MSG="${STATUS_MSG} (skipped: ${SKIPPED_STR})"
  fi
  jq -n --arg msg "$STATUS_MSG" '{systemMessage: $msg}'
  exit 0
fi

NEW_CMD="export ${EXPORT_ARGS[*]} && ${CMD}"

UPDATED_INPUT="$(printf '%s' "$INPUT" | jq --arg cmd "$NEW_CMD" '.tool_input | .command = $cmd')"

# Compose systemMessage: applied first, then skipped (if any) — variable names
# only, never values.
SYSTEM_MSG="[project-accounts] ${PROJECT} (${AUTO_ENV}) → ${APPLIED_STR}"
if [ -n "$SKIPPED_STR" ]; then
  SYSTEM_MSG="${SYSTEM_MSG} (skipped: ${SKIPPED_STR})"
fi

jq -n \
  --argjson input "$UPDATED_INPUT" \
  --arg msg "$SYSTEM_MSG" \
  '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      updatedInput: $input
    },
    systemMessage: $msg
  }'
