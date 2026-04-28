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

# tcp_probe — connect-and-immediately-close, with a hard wall-clock timeout.
# Tries (in order): GNU coreutils timeout/gtimeout, BSD/macOS nc, then a pure-
# bash background-and-kill fallback. Returns 0 on success, non-zero otherwise.
#
# host/port come from the user's JSON mapping, so they MUST never be
# interpolated into a shell command string. We pass them as positional args
# to the inner bash so $1/$2 are treated as literal strings — no chance of
# `host="x; rm -rf /"` triggering injection.
tcp_probe() {
  local host="$1" port="$2" tmo="$3"
  if command -v timeout >/dev/null 2>&1; then
    timeout "$tmo" bash -c 'true >"/dev/tcp/$1/$2"' bash "$host" "$port" 2>/dev/null
    return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$tmo" bash -c 'true >"/dev/tcp/$1/$2"' bash "$host" "$port" 2>/dev/null
    return $?
  fi
  if command -v nc >/dev/null 2>&1; then
    # -z scan, -G connect-timeout (macOS), -w session-timeout. Linux nc ignores
    # -G silently, which is fine — -w still bounds the call. host/port are
    # nc's own positional args, never interpolated.
    nc -z -G "$tmo" -w "$tmo" "$host" "$port" </dev/null >/dev/null 2>&1
    return $?
  fi
  # Pure-bash fallback: run probe in the background, kill it after $tmo.
  bash -c 'true >"/dev/tcp/$1/$2"' bash "$host" "$port" >/dev/null 2>&1 &
  local pid=$!
  ( sleep "$tmo" && kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  local sleeper=$!
  local rc=0
  wait "$pid" 2>/dev/null || rc=1
  kill "$sleeper" 2>/dev/null
  wait "$sleeper" 2>/dev/null
  return "$rc"
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
          # Treat as a path only when the value is absolute (/...) or
          # home-relative (~/...). Relative paths (./, ../) have no defined
          # base in this plugin's design — credentials live in a global
          # mapping shared across CWDs — so we don't recognise them.
          if [[ "$value" == /* ]] || [ "$expanded" != "$value" ]; then
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
          if tcp_probe "$host" "$port" "$SSH_TIMEOUT"; then
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
