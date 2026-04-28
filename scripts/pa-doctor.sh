#!/usr/bin/env bash
# pa-doctor.sh — full health check for the project-accounts mapping.
#
# Verifies file permissions, secret-file existence + chmod, ssh service
# reachability (port 22 by default), and PATH presence of managed CLIs.
# Read-only — never mutates the mapping.
#
# Exit code: 0 if no problems, 1 if any FAIL was reported. WARNs do not
# affect exit code.

set -uo pipefail

MAPPING="${HOME}/.claude/project-accounts.json"
SECRETS_DIR="${HOME}/.claude/secrets"
BACKUP_DIR="${HOME}/.claude/project-accounts.backups"
SSH_TIMEOUT="${PA_SSH_TIMEOUT:-3}"
SKIP_NETWORK="${PA_SKIP_NETWORK:-0}"

if [ ! -f "$MAPPING" ]; then
  printf 'pa-doctor: mapping not found at %s\n' "$MAPPING" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  printf 'pa-doctor: jq is required\n' >&2
  exit 1
fi

# --- output helpers --------------------------------------------------------
if [ -t 1 ]; then
  C_OK=$'\033[32m'
  C_WARN=$'\033[33m'
  C_FAIL=$'\033[31m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_RST=$'\033[0m'
else
  C_OK=; C_WARN=; C_FAIL=; C_DIM=; C_BOLD=; C_RST=
fi

FAILS=0
ok()   { printf '  %s✓%s %s\n' "$C_OK"   "$C_RST" "$*"; }
warn() { printf '  %s⚠%s %s\n' "$C_WARN" "$C_RST" "$*"; }
fail() { printf '  %s✗%s %s\n' "$C_FAIL" "$C_RST" "$*"; FAILS=$((FAILS+1)); }
section() { printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RST"; }

expand_tilde() {
  local p="$1"
  case "$p" in
    "~/"*) printf '%s' "${HOME}${p#\~}" ;;
    "~")   printf '%s' "$HOME" ;;
    *)     printf '%s' "$p" ;;
  esac
}

stat_perms() {
  stat -f '%Sp' "$1" 2>/dev/null || stat -c '%A' "$1" 2>/dev/null
}

# --- 1. mapping + secrets dir --------------------------------------------
section "Mapping & secrets storage"

PERMS=$(stat_perms "$MAPPING")
case "$PERMS" in
  -rw-------) ok "mapping perms: $PERMS  ($MAPPING)" ;;
  *)          warn "mapping perms: $PERMS — recommended -rw------- (run any 'pa-update' to fix automatically)" ;;
esac

if [ -d "$SECRETS_DIR" ]; then
  PERMS=$(stat_perms "$SECRETS_DIR")
  case "$PERMS" in
    drwx------) ok "secrets dir perms: $PERMS  ($SECRETS_DIR)" ;;
    *)          warn "secrets dir perms: $PERMS — recommended drwx------ (chmod 700 $SECRETS_DIR)" ;;
  esac
else
  warn "secrets dir not present (will be created on first hook run)"
fi

if [ -d "$BACKUP_DIR" ]; then
  count=$(ls -1 "$BACKUP_DIR" 2>/dev/null | wc -l | tr -d ' ')
  ok "backups: $count file(s) in $BACKUP_DIR"
else
  printf '  %s·%s no backups yet (will appear after first pa-update)\n' "$C_DIM" "$C_RST"
fi

# --- 2. JSON validity ----------------------------------------------------
if ! jq empty "$MAPPING" >/dev/null 2>&1; then
  section "JSON validity"
  fail "mapping is not valid JSON — fix before continuing"
  exit 1
fi

# --- 3. per-project checks -----------------------------------------------
PROJECTS="$(jq -r '(.projects // {}) | keys[]' "$MAPPING")"
if [ -z "$PROJECTS" ]; then
  section "Projects"
  printf '  %s·%s none registered yet\n' "$C_DIM" "$C_RST"
else
  while IFS= read -r project; do
    [ -z "$project" ] && continue
    section "Project: $project"

    # repos
    REPOS="$(jq -r --arg p "$project" '
      (.projects[$p].repos // {}) | to_entries[] | [.key, .value] | @tsv
    ' "$MAPPING")"
    if [ -n "$REPOS" ]; then
      while IFS=$'\t' read -r role path; do
        [ -z "$role" ] && continue
        if [ -d "$path" ]; then
          ok "repo.$role: $path"
        else
          warn "repo.$role: $path — directory not present (clone or update path)"
        fi
      done <<<"$REPOS"
    fi

    # envs
    ENVS="$(jq -r --arg p "$project" '
      (.projects[$p].envs // {}) | keys[]
    ' "$MAPPING")"
    while IFS= read -r env; do
      [ -z "$env" ] && continue
      printf '  %s· env: %s%s\n' "$C_DIM" "$env" "$C_RST"

      # credentials
      CREDS="$(jq -r --arg p "$project" --arg e "$env" '
        (.projects[$p].envs[$e].credentials // {}) | to_entries[] | [.key, .value] | @tsv
      ' "$MAPPING")"
      while IFS=$'\t' read -r key value; do
        [ -z "$key" ] && continue
        if [[ "$value" == @file:* ]]; then
          fp="$(expand_tilde "${value#@file:}")"
          if [ ! -e "$fp" ]; then
            fail "    $key @file:$fp — MISSING"
          elif [ ! -r "$fp" ]; then
            fail "    $key @file:$fp — not readable"
          else
            perms=$(stat_perms "$fp")
            if [ "$perms" = "-rw-------" ]; then
              ok "    $key @file:$fp  [$perms]"
            else
              warn "    $key @file:$fp  [$perms] — recommend chmod 600"
            fi
          fi
        else
          expanded="$(expand_tilde "$value")"
          if [ "$expanded" != "$value" ]; then
            # path-style value (PEM, kubeconfig, etc.)
            if [ ! -e "$expanded" ]; then
              fail "    $key path:$expanded — MISSING"
            else
              perms=$(stat_perms "$expanded")
              if [ "$perms" = "-rw-------" ]; then
                ok "    $key path:$expanded  [$perms]"
              else
                warn "    $key path:$expanded  [$perms] — recommend chmod 600"
              fi
            fi
          else
            ok "    $key (plain)"
          fi
        fi
      done <<<"$CREDS"

      # services — ssh reachability
      if [ "$SKIP_NETWORK" != "1" ]; then
        SVCS="$(jq -r --arg p "$project" --arg e "$env" '
          (.projects[$p].envs[$e].services // {}) | to_entries[]
          | select(.value.platform == "ssh")
          | [.key, .value.host // "", .value.user // "", (.value.port // 22 | tostring)]
          | @tsv
        ' "$MAPPING")"
        while IFS=$'\t' read -r svc host user port; do
          [ -z "$svc" ] && continue
          [ -z "$host" ] && { warn "    service.$svc — no host configured"; continue; }
          # Use a TCP probe via /dev/tcp; portable across mac and linux bash.
          if (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; then
            exec 3>&- 3<&-
            ok "    service.$svc ssh $user@$host:$port — reachable"
          else
            warn "    service.$svc ssh $user@$host:$port — port closed or unreachable (timeout ${SSH_TIMEOUT}s)"
          fi
        done <<<"$SVCS"
      fi
    done <<<"$ENVS"
  done <<<"$PROJECTS"
fi

# --- 4. managed CLIs on PATH ---------------------------------------------
section "Managed CLIs on PATH"
CLIS="$(jq -r '(.managed_clis // [])[]' "$MAPPING")"
if [ -z "$CLIS" ]; then
  printf '  %s·%s no managed_clis defined\n' "$C_DIM" "$C_RST"
else
  while IFS= read -r cli; do
    [ -z "$cli" ] && continue
    if path=$(command -v "$cli" 2>/dev/null); then
      ok "$cli  ($path)"
    else
      warn "$cli  not on PATH — install if you plan to use it"
    fi
  done <<<"$CLIS"
fi

# --- summary -------------------------------------------------------------
printf '\n'
if [ "$FAILS" -eq 0 ]; then
  printf '%sAll checks passed.%s Warnings (if any) are advisory.\n' "$C_OK" "$C_RST"
  exit 0
else
  printf '%s%d failure(s)%s — see ✗ lines above.\n' "$C_FAIL" "$FAILS" "$C_RST"
  exit 1
fi
