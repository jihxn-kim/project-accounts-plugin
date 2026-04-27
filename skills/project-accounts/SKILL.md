---
name: project-accounts
description: Use when the user wants to manage or invoke commands against per-project CLI credentials and deployment targets — adding/removing projects, repos, envs (dev/prod), services; storing or rotating tokens; running logs/deploy/status for a specific project-env-service by natural-language name; listing current mappings; checking which project applies to the current directory.
---

# project-accounts

Per-project CLI credentials and deployment targets, keyed by project name (not path).

- **Mapping file:** `~/.claude/project-accounts.json` (auto-created on first hook run if missing)
- **Secret files:** `~/.claude/secrets/*.token` (chmod 600, referenced via `@file:` prefix)
- **Key files:** `~/.claude/secrets/*.pem` (chmod 600, registered as a path-valued env var — see PEM section)
- **Hook:** ships with this plugin under `hooks/inject.sh`, registered as PreToolUse/Bash

## Schema

```json
{
  "managed_clis": ["aws", "railway", "vercel", "gcloud", "doctl", "flyctl", "heroku", "supabase"],
  "projects": {
    "<project-name>": {
      "aliases":  ["optional human-readable names"],
      "repos":    { "<repo-name>": "<absolute-path>", ... },
      "envs": {
        "<env-name>": {
          "credentials": { "<ENV_VAR>": "<value or @file:...>", ... },
          "services": {
            "<service-name>": {
              "platform": "railway|vercel|aws|...",
              "service":  "<platform-specific id>",
              "notes":    "optional operational context"
            }
          }
        }
      },
      "notes": "free-form project notes (git remote, runtime, contacts, etc.)"
    }
  }
}
```

**Key conventions:**
- `<project-name>`: stable short identifier (`acme-erp`, `client-a-web`). Used as the primary lookup key.
- `aliases`: only for coded/non-obvious names. Directory and project names are usually self-explanatory — rely on semantic matching first.
- `repos`: maps a repo role (`backend`, `frontend`, `admin`) to its local clone path. Optional — a project with no `repos` is remote-only (invoked by name only).
- `envs.<name>`: conventionally `dev`, `staging`, `prod`. Each env has its own credentials and service IDs.
- `credentials`: env vars to inject. Plain values for non-secrets (profiles, team IDs, **paths to key files**); `@file:<path>` for token-style secrets whose *contents* should become the env value. Plain `~/...` paths are tilde-expanded by the hook.
- `services`: per-env deployment targets for logs/deploy/status commands.

### Two value modes for `credentials`

| Use case | Value form | Hook behavior |
|----------|------------|---------------|
| AWS profile name, team ID, region | plain string (`"acme-dev"`) | injected as-is |
| Token whose *content* is the secret | `@file:~/.claude/secrets/<x>.token` | reads file, injects content |
| Path to a key file (PEM, kubeconfig) | plain string (`"~/.claude/secrets/<x>.pem"`) | injected as path; CLI tool reads the file via `-i` / `--kubeconfig` / etc. |

**Rule of thumb:** if the CLI takes the secret as a flag value (`--token=...`), use `@file:`. If the CLI takes a *path* to the secret (`ssh -i <path>`), store the path as a plain string.

## Safety policy: dev auto, prod explicit

**The hook ONLY auto-injects `envs.dev.credentials`.** Prod and any non-dev env are invoked by name only — this prevents accidentally hitting prod from a `cd`-based flow.

| Invocation | Env used | Mechanism |
|------------|----------|-----------|
| `cd <repo> && railway logs` | **dev** | Hook auto-inject |
| "railway logs 봐줘" / "show railway logs" (while cd'd in repo) | **dev** | Hook auto-inject |
| "<project> production backend logs" | **prod** | Skill resolves → inline `VAR=val cmd` |
| "this project prod db restart" | **prod** | Skill resolves → inline `VAR=val cmd` |

**Never** run a prod command via cd auto-inject — always resolve by name + explicit env and construct the command with literal `$(cat <token-file>)` or `VAR=value` prefixes.

## Resolving a natural-language request

When the user says something like "acme-erp production backend last hour error logs":

1. **Project**: match against `projects.*` keys + `aliases`. Use semantic judgment. If ambiguous, confirm with the user.
2. **Env**: parse the phrasing — "production/prod/실서버" → `prod`; "dev/development/스테이징" → `dev`/`staging`. Default to `dev` if unstated AND the user is in a repo path (confirm otherwise).
3. **Service**: parse the service word — "backend" → `backend`, "DB/database" → `db`, etc. Verify it exists under `projects[P].envs[E].services`.
4. **Command**: look up `service.platform` and pick the right CLI command (see table below).
5. **Execute**: prepend credentials inline, e.g.:
   ```bash
   RAILWAY_TOKEN="$(cat ~/.claude/secrets/<file>.token)" \
     railway logs --service <service-id>
   ```

## Platform → command cheat sheet

| Platform | Logs | Deploy / Restart | Status |
|----------|------|------------------|--------|
| railway  | `railway logs --service <svc>` | `railway redeploy --service <svc>` | `railway status --service <svc>` |
| vercel   | `vercel logs <deployment-url>` or `vercel inspect` | `vercel deploy --prod` | `vercel ls` |
| aws (ecs) | `aws logs tail <log-group> --follow` (find log group via `describe-task-definition`) | `aws ecs update-service --force-new-deployment` | `aws ecs describe-services` |
| aws (lambda) | `aws logs tail /aws/lambda/<fn> --follow` | `aws lambda update-function-code` | `aws lambda get-function` |
| aws (rds) | (Performance Insights / CloudWatch RDS metrics) | (parameter group / instance modify) | `aws rds describe-db-instances` |
| fly.io   | `flyctl logs -a <app>` | `flyctl deploy -a <app>` | `flyctl status -a <app>` |
| heroku   | `heroku logs --tail -a <app>` | `heroku releases -a <app>` | `heroku ps -a <app>` |
| gcp      | `gcloud logging read 'resource.type=...'` | `gcloud run deploy` | `gcloud run services describe` |

When invoking, always pull the service/app id from `services.<svc>.service` (or platform-specific field) — never hardcode.

## Operations

Always edit via `jq --arg` / `--argjson` to avoid shell-quoting bugs. Never hand-edit the JSON.

### List projects

```bash
jq -r '.projects | keys[]' ~/.claude/project-accounts.json
```

### Show a project's full config

```bash
jq --arg p "<name>" '.projects[$p]' ~/.claude/project-accounts.json
```

### Show which project matches the current directory

```bash
CWD="$PWD"
jq -r --arg cwd "$CWD" '
  [
    (.projects // {}) | to_entries[]
    | .key as $pname
    | (.value.repos // {}) | to_entries[]
    | {project: $pname, repo: .key, path: .value}
  ]
  | map(select(.path as $p | $cwd == $p or ($cwd | startswith($p + "/"))))
  | sort_by(.path | length) | reverse | (.[0] // "no match")
' ~/.claude/project-accounts.json
```

### Add a new project (initial creation)

```bash
jq --arg name "<project-name>" '.projects[$name] = {
  aliases: [],
  repos: {},
  envs: {}
}' ~/.claude/project-accounts.json > /tmp/_pa.json && mv /tmp/_pa.json ~/.claude/project-accounts.json
```

### Add a repo to an existing project

```bash
jq --arg p "<project>" --arg r "<repo-role>" --arg path "<absolute-path>" \
   '.projects[$p].repos[$r] = $path' \
   ~/.claude/project-accounts.json > /tmp/_pa.json && mv /tmp/_pa.json ~/.claude/project-accounts.json
```

### Add or replace an env block

```bash
ENV_JSON='{
  "credentials": {
    "RAILWAY_TOKEN": "@file:~/.claude/secrets/<project>-railway.token"
  },
  "services": {
    "backend": { "platform": "railway", "service": "<service-id>" }
  }
}'
jq --arg p "<project>" --arg e "dev" --argjson env "$ENV_JSON" \
   '.projects[$p].envs[$e] = $env' \
   ~/.claude/project-accounts.json > /tmp/_pa.json && mv /tmp/_pa.json ~/.claude/project-accounts.json
```

### Add or update a single credential

```bash
jq --arg p "<project>" --arg e "<env>" \
   --arg k "<KEY>" --arg v "<value-or-@file:path>" \
   '.projects[$p].envs[$e].credentials[$k] = $v' \
   ~/.claude/project-accounts.json > /tmp/_pa.json && mv /tmp/_pa.json ~/.claude/project-accounts.json
```

### Add a service to an env

```bash
jq --arg p "<project>" --arg e "<env>" --arg svc "db" \
   --argjson spec '{"platform":"railway","service":"<service-id>","notes":"optional"}' \
   '.projects[$p].envs[$e].services[$svc] = $spec' \
   ~/.claude/project-accounts.json > /tmp/_pa.json && mv /tmp/_pa.json ~/.claude/project-accounts.json
```

### Store a token (secret)

**Never pass a token as a command-line arg or paste it into the chat** — both leak. Two safe options:

**A. Clipboard (fastest):** ask the user to copy the token, then run on macOS:

```bash
NAME="<project>-<service>"
pbpaste | tr -d '\r\n' > ~/.claude/secrets/$NAME.token && \
  chmod 600 ~/.claude/secrets/$NAME.token && \
  echo "saved: $(wc -c < ~/.claude/secrets/$NAME.token) bytes"
```

(Linux equivalent: `xclip -selection clipboard -o` or `wl-paste` instead of `pbpaste`.)

**B. Interactive prompt (if no clipboard):** the user must invoke this themselves with the `!` prefix so input never reaches the model context:

```
! read -s -p "Paste token: " TOKEN && printf '%s' "$TOKEN" > ~/.claude/secrets/<name>.token && chmod 600 ~/.claude/secrets/<name>.token && unset TOKEN && echo saved
```

Then reference it in the mapping: `"RAILWAY_TOKEN": "@file:~/.claude/secrets/<name>.token"`.

### Store a PEM key (SSH private key)

Unlike tokens, a PEM key alone is **incomplete**. To actually SSH you need `key + host + user` — registering only the key leaves dead data. **Always collect the connection info upfront** and register the key *and* at least one ssh service together.

#### Required info before doing anything

Ask the user for these in one go (offer to read from `~/.ssh/config` if they have entries there):

1. **PEM file location(s)** — and which env each one belongs to (dev / prod / etc.)
2. **Host** — DNS or IP for each env's instance
3. **User** — `ec2-user`, `ubuntu`, `bitnami`, … (AMI-dependent; if unknown, try `ec2-user` first then `ubuntu`)
4. **Service role** — what is this host? `backend`, `bastion`, `db`, etc.
5. **Port** — only ask if non-default (22)

If the user only provides the key without host/user, **stop and ask for the rest** before writing to the mapping. A registered PEM with no service entry is misleading.

#### Step 1 — move the PEM(s) into the secrets dir

```bash
NAME="<project>-<env>"        # e.g. acme-prod, acme-dev
SRC="<path the user gave>"    # e.g. ~/Downloads/acme.pem
mkdir -p ~/.claude/secrets && chmod 700 ~/.claude/secrets
cp "$SRC" ~/.claude/secrets/$NAME.pem && chmod 600 ~/.claude/secrets/$NAME.pem && \
  echo "saved: $(wc -c < ~/.claude/secrets/$NAME.pem) bytes"
```

#### Step 2 — register key path as a credential

Plain string (not `@file:`) so the hook injects the *path*. The hook expands leading `~`.

```bash
jq --arg p "<project>" --arg e "<env>" \
   --arg k "EC2_SSH_KEY" --arg v "~/.claude/secrets/$NAME.pem" \
   '.projects[$p].envs[$e].credentials[$k] = $v' \
   ~/.claude/project-accounts.json > /tmp/_pa.json && mv /tmp/_pa.json ~/.claude/project-accounts.json
```

#### Step 3 — register the ssh service (host + user + key reference)

```bash
jq --arg p "<project>" --arg e "<env>" --arg svc "<role>" \
   --argjson spec '{"platform":"ssh","host":"<dns-or-ip>","user":"<ubuntu|ec2-user|...>","key":"EC2_SSH_KEY"}' \
   '.projects[$p].envs[$e].services[$svc] = $spec' \
   ~/.claude/project-accounts.json > /tmp/_pa.json && mv /tmp/_pa.json ~/.claude/project-accounts.json
```

#### Step 4 — verify with a connection test

Always offer to run a connection check after registration so the user knows it actually works:

```bash
ssh -i ~/.claude/secrets/$NAME.pem \
    -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    <user>@<host> 'echo ok && uname -a'
```

If timeout: instance may be stopped, IP may have changed, or security group may not allow your current public IP. Don't silently move on — tell the user what to check (instance state, current Public IPv4, SG inbound 22).

#### Invocation later

For dev with a registered repo: hook auto-injects `EC2_SSH_KEY`, user runs `ssh -i "$EC2_SSH_KEY" ubuntu@<host>` directly.

For prod or any name-based call ("dalcom prod backend ssh"): resolve from mapping:

```bash
KEY="$(jq -r '.projects["<p>"].envs.<e>.credentials.EC2_SSH_KEY' ~/.claude/project-accounts.json | sed 's|^~|'"$HOME"'|')"
HOST="$(jq -r '.projects["<p>"].envs.<e>.services.<svc>.host' ~/.claude/project-accounts.json)"
USER="$(jq -r '.projects["<p>"].envs.<e>.services.<svc>.user' ~/.claude/project-accounts.json)"
ssh -i "$KEY" "$USER@$HOST"
```

If the user already keeps the PEM in `~/.ssh/` and doesn't want it moved, register that absolute path directly — the `~/.claude/secrets/` convention is just the recommended default.

### Remove a project / repo / env

```bash
# Remove entire project
jq --arg p "<project>" 'del(.projects[$p])' \
   ~/.claude/project-accounts.json > /tmp/_pa.json && mv /tmp/_pa.json ~/.claude/project-accounts.json

# Remove one repo
jq --arg p "<project>" --arg r "<repo>" 'del(.projects[$p].repos[$r])' \
   ~/.claude/project-accounts.json > /tmp/_pa.json && mv /tmp/_pa.json ~/.claude/project-accounts.json

# Remove an env
jq --arg p "<project>" --arg e "<env>" 'del(.projects[$p].envs[$e])' \
   ~/.claude/project-accounts.json > /tmp/_pa.json && mv /tmp/_pa.json ~/.claude/project-accounts.json
```

When removing, ask the user before deleting any secret file that referenced the removed mapping.

### Add a new CLI to `managed_clis`

```bash
jq '.managed_clis += ["kubectl"] | .managed_clis |= unique' \
   ~/.claude/project-accounts.json > /tmp/_pa.json && mv /tmp/_pa.json ~/.claude/project-accounts.json
```

## Running commands for non-dev envs

For prod (or any non-dev env), build the command with explicit inline env vars. Example — running prod backend logs on Railway:

```bash
TOKEN_FILE="$(jq -r '.projects["<project>"].envs.prod.credentials.RAILWAY_TOKEN' ~/.claude/project-accounts.json | sed 's|^@file:||; s|^~|'"$HOME"'|')"
SERVICE="$(jq -r '.projects["<project>"].envs.prod.services.backend.service' ~/.claude/project-accounts.json)"
RAILWAY_TOKEN="$(cat "$TOKEN_FILE")" railway logs --service "$SERVICE"
```

For dev when already cd'd into a mapped repo, just run the command plain — the hook handles it.

## Common mistakes

- **Putting tokens directly in `project-accounts.json`** — always use `@file:` references.
- **Using repo path as project key** — keys are names, not paths. Paths go inside `repos`.
- **Auto-injecting prod** — never. Hook is dev-only by design. Prod = explicit name-based invocation.
- **Assuming `managed_clis` covers every CLI** — add to the list when introducing a new tool.
- **Overlapping repo paths across projects** — possible but usually wrong. Longest-prefix wins; call out to the user if detected.
- **Committing `~/.claude/project-accounts.json` or `~/.claude/secrets/` to git** — per-machine personal state.
