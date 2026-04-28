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

# Validate an ssh alias before passing it to `ssh -G`. Strict — disallows
# spaces, =, *, ?, leading -, anything ssh might interpret as a flag or
# pattern. We also use `--` as a defensive separator at the call site.
valid_ssh_alias() {
  case "$1" in
    ''|-*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Pull a single key's value from `ssh -G` output. ssh -G emits lowercased
# keys, one per line, space-separated. First match wins.
ssh_g_value() {
  awk -v k="$1" '$1 == k { $1=""; sub(/^ /, ""); print; exit }'
}

stat_perms() {
  stat -f '%Sp' "$1" 2>/dev/null || stat -c '%A' "$1" 2>/dev/null
}

# Probe whether `nc` accepts `-G secs` (macOS / BSD-style connect timeout).
# ncat (Nmap) reuses `-G` for source-routing with a different argument shape,
# so we mustn't pass it blindly. Cached so we don't re-probe per service.
NC_HAS_G=""
nc_supports_G() {
  if [ -z "$NC_HAS_G" ]; then
    # Match nc help text where -G is documented as a connect timeout. Accept
    # both "Connection timeout" (macOS BSD nc, e.g. "-G conntimo  Connection
    # timeout in seconds") and any future variant that mentions "connect"
    # near -G. ncat (Nmap) uses -G for source routing — its help string
    # doesn't contain this phrase, so it correctly returns false.
    #
    # Capture nc -h output first instead of piping: macOS nc exits non-zero
    # after printing help, which under `set -o pipefail` would mask the
    # grep result and falsely report no -G support.
    local help
    help="$(nc -h 2>&1 || true)"
    if printf '%s\n' "$help" | grep -qiE -- '-G[[:space:]].*(onnection|onnect).*timeout'; then
      NC_HAS_G=1
    else
      NC_HAS_G=0
    fi
  fi
  [ "$NC_HAS_G" = 1 ]
}

# tcp_probe — connect-and-immediately-close, with a hard wall-clock timeout.
# Tries (in order): GNU coreutils timeout/gtimeout, nc (variant-aware), then a
# pure-bash background-and-kill fallback. Returns 0 on success, non-zero
# otherwise.
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
    # -z scan, -w session-timeout. On macOS BSD nc, -w only kicks in *after*
    # connect, so a filtered port can hang for the OS default; -G adds a
    # connect-timeout there. ncat doesn't accept -G in this form, so we only
    # add it when probed support is detected.
    if nc_supports_G; then
      nc -z -G "$tmo" -w "$tmo" "$host" "$port" </dev/null >/dev/null 2>&1
    else
      nc -z -w "$tmo" "$host" "$port" </dev/null >/dev/null 2>&1
    fi
    return $?
  fi
  # Pure-bash fallback: run probe in background, watchdog kills it after $tmo.
  # The sleep lives INSIDE the watchdog subshell so `wait` can find it (POSIX
  # `wait` only works on direct children of the calling shell). An EXIT trap
  # ensures the inner sleep is reaped if the watchdog itself is terminated
  # early — that's why we send SIGTERM (default kill), not SIGKILL, when the
  # probe finishes first; SIGKILL bypasses the trap and would orphan sleep.
  bash -c 'true >"/dev/tcp/$1/$2"' bash "$host" "$port" >/dev/null 2>&1 &
  local pid=$!
  (
    sleep "$tmo" &
    s_pid=$!
    trap 'kill "$s_pid" 2>/dev/null' EXIT
    wait "$s_pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
  ) >/dev/null 2>&1 &
  local watchdog=$!

  local rc=0
  wait "$pid" 2>/dev/null || rc=1

  # Probe is done. SIGTERM (not SIGKILL) so the watchdog's EXIT trap fires and
  # cleans up its inner sleep child.
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  return "$rc"
}

# valid_port — returns 0 iff $1 is an integer in 1..65535. JSON-sourced port
# values that fail this check are skipped so they don't reach nc / /dev/tcp
# with junk that would either error or produce confusing output.
#
# Use `(( 10#$1 ... ))` so leading zeros (e.g. "08", "09") are interpreted as
# base-10 — bash 4+'s `[ N -ge ... ]` would otherwise reject them as invalid
# octal. The case-pattern guard above already rejects non-digit input so
# `10#$1` is always safe to evaluate here.
valid_port() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  (( 10#$1 >= 1 && 10#$1 <= 65535 ))
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
        # Empty credential value: hook would skip with reason "empty-value".
        # Surface that here instead of marking it (plain), to keep doctor
        # consistent with the runtime hook's behaviour.
        if [ -z "$value" ]; then
          warn "    $key (empty — hook will skip)"
          continue
        fi
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
              # WARN, not FAIL — a leading / can also be a non-file value
              # (e.g. an API URL path "/v1/foo" stored as a plain credential),
              # so a missing path is informational, not a hard error.
              warn "    $key path:$expanded — not found (intended as a file path?)"
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

      # services — ssh reachability. Two registration shapes:
      #   1. explicit:  { platform:"ssh", host, user, key, port? }
      #   2. ssh_alias: { platform:"ssh", ssh_alias }  // resolves via ~/.ssh/config
      #
      # ssh_alias gets resolved through `ssh -G`, then probed exactly the same
      # way as explicit form. The alias is validated against a strict charset
      # before reaching ssh; we also pass it after `--` as belt-and-suspenders.
      if [ "$SKIP_NETWORK" != "1" ]; then
        # Use US (\x1f, "Unit Separator") as the field separator instead of
        # tab. With IFS=$'\t', bash treats tab as whitespace and collapses
        # consecutive empty fields, so an empty ssh_alias would shift host into
        # the alias slot. US is non-whitespace, never appears in mapping
        # values, and bash 3.2's `read` splits on it cleanly. (SOH \x01 looks
        # like a more natural choice but bash 3.2 swallows it during word
        # splitting — confirmed on macOS /bin/bash 3.2.57.)
        SVCS="$(jq -r --arg p "$project" --arg e "$env" '
          (.projects[$p].envs[$e].services // {}) | to_entries[]
          | select(.value.platform == "ssh")
          | [
              .key,
              .value.ssh_alias // "",
              .value.host      // "",
              .value.user      // "",
              (.value.port     // 22 | tostring)
            ]
          | join("\u001f")
        ' "$MAPPING")"
        while IFS=$'\037' read -r svc alias host user port; do
          [ -z "$svc" ] && continue
          if [ -n "$alias" ]; then
            if ! valid_ssh_alias "$alias"; then
              fail "    service.$svc ssh_alias=\"$alias\" — invalid (allowed: A-Z a-z 0-9 . _ -, no leading -)"
              continue
            fi
            cfg="$(ssh -G -- "$alias" 2>/dev/null || true)"
            if [ -z "$cfg" ]; then
              fail "    service.$svc ssh_alias=\"$alias\" — ssh -G returned no output"
              continue
            fi
            r_host="$(printf '%s\n' "$cfg" | ssh_g_value hostname)"
            r_user="$(printf '%s\n' "$cfg" | ssh_g_value user)"
            r_id="$(printf '%s\n' "$cfg" | ssh_g_value identityfile)"
            r_port="$(printf '%s\n' "$cfg" | ssh_g_value port)"
            # If ssh -G simply echoed the alias as the hostname, the alias
            # isn't matched by any Host block in the user's ssh config. Treat
            # this as a hard failure — the service is unusable.
            if [ "$r_host" = "$alias" ]; then
              fail "    service.$svc ssh_alias=\"$alias\" — not found in ~/.ssh/config (hostname unresolved)"
              continue
            fi
            host="$r_host"
            user="$r_user"
            port="$r_port"
            # Identity file from ssh config: warn (not fail) on permissions if
            # the path resolves and is a regular file. Default keys (~/.ssh/id_*)
            # may or may not exist — that's the user's choice, not our concern.
            if [ -n "$r_id" ]; then
              id_expanded="$(expand_tilde "$r_id")"
              if [ -f "$id_expanded" ]; then
                idperms=$(stat_perms "$id_expanded")
                if [ "$idperms" != "-rw-------" ] && [ "$idperms" != "-r--------" ]; then
                  warn "    service.$svc identity $id_expanded  [$idperms] — recommend chmod 600"
                fi
              fi
            fi
            label="service.$svc ssh $alias → $user@$host:$port"
          else
            [ -z "$host" ] && { warn "    service.$svc — no host or ssh_alias configured"; continue; }
            label="service.$svc ssh $user@$host:$port"
          fi
          if ! valid_port "$port"; then
            warn "    $label — invalid port: $port (must be integer 1-65535)"
            continue
          fi
          if tcp_probe "$host" "$port" "$SSH_TIMEOUT"; then
            ok "    $label — reachable"
          else
            warn "    $label — port closed or unreachable (timeout ${SSH_TIMEOUT}s)"
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
