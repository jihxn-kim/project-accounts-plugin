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
mkdir -p "$SECRETS_DIR" 2>/dev/null && chmod 700 "$SECRETS_DIR" 2>/dev/null

INPUT="$(cat)"
CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty')"
CWD="${CWD:-$PWD}"

[ -n "$CMD" ] || exit 0

CLI_PATTERN="$(jq -r '(.managed_clis // []) | join("|")' "$MAPPING_FILE" 2>/dev/null)"
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
# to nag users who run `aws`/`vercel`/etc. outside any registered repo.
INVOKED_CLI=""
while IFS= read -r cli; do
  [ -z "$cli" ] && continue
  if printf '%s' "$CMD" | grep -Eq "(^|[[:space:];&|()\`]+)${cli}([[:space:]]|$)"; then
    INVOKED_CLI="$cli"
    break
  fi
done < <(jq -r '(.managed_clis // [])[]' "$MAPPING_FILE" 2>/dev/null)

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
while IFS=$'\t' read -r key value; do
  [ -z "$key" ] && continue
  # Respect explicit user overrides already in the command.
  if printf '%s' "$CMD" | grep -Eq "(^|[[:space:];&|()]+)${key}="; then
    continue
  fi
  if [[ "$value" == @file:* ]]; then
    filepath="${value#@file:}"
    filepath="${filepath/#\~/$HOME}"
    if [ -r "$filepath" ]; then
      value="$(tr -d '\r\n' < "$filepath")"
    else
      continue
    fi
  fi
  [ -z "$value" ] && continue
  printf -v escaped "%q" "$value"
  EXPORT_ARGS+=("${key}=${escaped}")
  APPLIED+=("$key")
done <<< "$ENV_PAIRS"

[ "${#EXPORT_ARGS[@]}" -gt 0 ] || exit 0

NEW_CMD="export ${EXPORT_ARGS[*]} && ${CMD}"

UPDATED_INPUT="$(printf '%s' "$INPUT" | jq --arg cmd "$NEW_CMD" '.tool_input | .command = $cmd')"

jq -n \
  --argjson input "$UPDATED_INPUT" \
  --arg project "$PROJECT" \
  --arg env "$AUTO_ENV" \
  --arg vars "$(IFS=,; printf '%s' "${APPLIED[*]}")" \
  '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      updatedInput: $input
    },
    systemMessage: ("[project-accounts] " + $project + " (" + $env + ") → " + $vars)
  }'
