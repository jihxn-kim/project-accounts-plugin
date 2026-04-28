# Usage Guide

Step-by-step walkthroughs for the most common scenarios. All examples use mock project names (`acme-erp`, `acme-storefront`) and mock IDs — replace with your real values.

> **Convention:** Anything you'd ask Claude in natural language is shown like `> "register a new project ..."`. Anything you'd type yourself is shown as a code block.

---

## Table of contents

- [5-minute quickstart](#5-minute-quickstart)
- [Registering an AWS project](#registering-an-aws-project)
- [Registering a Vercel project](#registering-a-vercel-project)
- [Registering a Railway project](#registering-a-railway-project)
- [Multi-environment (dev + prod)](#multi-environment-dev--prod)
- [Registering a PEM key for EC2 / SSH](#registering-a-pem-key-for-ec2--ssh)
- [Storing secrets safely](#storing-secrets-safely)
- [Natural-language invocation patterns](#natural-language-invocation-patterns)
- [Troubleshooting](#troubleshooting)

---

## 5-minute quickstart

### 1. Install the plugin

```bash
claude plugin marketplace add github:jihxn-kim/project-accounts-plugin
claude plugin install project-accounts@project-accounts
```

Restart Claude Code. The plugin's hook auto-creates `~/.claude/project-accounts.json` (empty stub) and `~/.claude/secrets/` (chmod 700) on first run.

### 2. Register your first project (with Claude)

Just ask:

> "register a new project, name `acme-erp`, AWS profile `acme-erp-dev`, region `us-east-1`. Local backend repo is at `~/code/acme-erp-backend`."

Claude reads the skill, runs the right `jq` commands, and confirms what got registered.

### 3. Verify

```bash
cd ~/code/acme-erp-backend && aws sts get-caller-identity
```

If you see the IAM identity for `acme-erp-dev`, the hook is firing correctly. The same command from any other directory falls back to your default profile.

---

## Registering an AWS project

Two paths depending on what you have.

### Path A: You already have an AWS profile in `~/.aws/credentials`

Just tell Claude the profile name:

> "register `acme-erp` with AWS profile `acme-erp-dev`, region `us-east-1`, repo at `~/code/acme-erp-backend`"

Claude writes:

```json
{
  "projects": {
    "acme-erp": {
      "repos": { "backend": "/Users/you/code/acme-erp-backend" },
      "envs": {
        "dev": {
          "credentials": {
            "AWS_PROFILE": "acme-erp-dev",
            "AWS_REGION": "us-east-1"
          },
          "services": {}
        }
      }
    }
  }
}
```

### Path B: You only have an access key + secret

Have Claude install the AWS CLI if missing, then *you* configure the profile interactively (so the secret never enters Claude's context):

```
! aws configure --profile acme-erp-dev
```

Then proceed as in Path A.

### Auto-discovering services

You don't have to fill `services` in by hand — once credentials work, ask Claude to discover what's running:

> "scan AWS account for `acme-erp`, find the ECS cluster, RDS instance, and any ALBs"

Claude queries `aws ecs list-clusters`, `aws rds describe-db-instances`, `aws elbv2 describe-load-balancers`, and proposes an updated mapping. You confirm, Claude writes.

A typical result for an ECS-Fargate-with-RDS-and-ALB stack:

```json
{
  "services": {
    "backend": {
      "platform": "aws",
      "service_type": "ecs-fargate",
      "cluster": "acme-erp-cluster",
      "service": "acme-erp-server",
      "log_group": "/ecs/acme-erp-server",
      "region": "us-east-1"
    },
    "db": {
      "platform": "aws",
      "service_type": "rds",
      "instance_id": "acme-erp-db",
      "engine": "postgres"
    },
    "alb": {
      "platform": "aws",
      "service_type": "alb",
      "name": "acme-erp-alb",
      "lb_dimension": "app/acme-erp-alb/<id>",
      "tg_dimension": "targetgroup/acme-erp-tg/<id>"
    }
  }
}
```

---

## Registering a Vercel project

Vercel has multiple authentication paths. Pick the one that fits.

### Single Vercel account → just `vercel login`

If you only ever use one Vercel account, run `vercel login` once. The CLI stores auth in `~/.vercel/auth.json` and works everywhere. The mapping then only needs the project IDs (no token):

```json
{
  "envs": {
    "dev": {
      "credentials": {
        "VERCEL_ORG_ID": "team_xxx",
        "VERCEL_PROJECT_ID": "prj_yyy"
      },
      "services": {
        "frontend": { "platform": "vercel", "framework": "nextjs" }
      }
    }
  }
}
```

### Multiple Vercel accounts → use a token per project

This is the case `project-accounts` is built for.

1. Open https://vercel.com/account/tokens **while logged into the account that owns the project** (switch via the avatar dropdown if needed).
2. Create a token. Scope it to the team/account that owns the project. Copy it.
3. Tell Claude (with the token already in your clipboard, never pasted into chat):

   > "save the Vercel token from clipboard for `acme-storefront`"

   Claude runs:

   ```bash
   pbpaste | tr -d '\r\n' > ~/.claude/secrets/acme-storefront-vercel.token && \
     chmod 600 ~/.claude/secrets/acme-storefront-vercel.token
   ```

   (Linux: `xclip -selection clipboard -o` or `wl-paste`. Windows: copy via clipboard utility of choice.)

4. Ask Claude to look up the project IDs and register the mapping:

   > "register `acme-storefront` Vercel project, frontend repo at `~/code/acme-storefront`"

   Claude calls `https://api.vercel.com/v9/projects?search=acme-storefront` with the token, finds the org/project IDs, and writes:

   ```json
   {
     "envs": {
       "dev": {
         "credentials": {
           "VERCEL_TOKEN": "@file:~/.claude/secrets/acme-storefront-vercel.token",
           "VERCEL_ORG_ID": "team_xxx",
           "VERCEL_PROJECT_ID": "prj_yyy"
         },
         "services": {
           "frontend": {
             "platform": "vercel",
             "project_id": "prj_yyy",
             "org_id": "team_xxx",
             "framework": "nextjs"
           }
         }
       }
     }
   }
   ```

### Verifying

```bash
cd ~/code/acme-storefront && vercel whoami
# → expects the username/team that owns this project, NOT your default vercel login
```

---

## Registering a Railway project

1. In the Railway dashboard, go to **Project Settings → Tokens** (project-scoped) or **Account → Tokens** (account-scoped). Create one, copy it.
2. Save the token (clipboard already has it):

   > "save the Railway token for `acme-erp` from clipboard"

3. Register:

   > "register `acme-erp` Railway services: backend service id `backend-prod`, db service id `postgres-prod`"

   Resulting mapping:

   ```json
   {
     "envs": {
       "dev": {
         "credentials": {
           "RAILWAY_TOKEN": "@file:~/.claude/secrets/acme-erp-railway.token"
         },
         "services": {
           "backend": { "platform": "railway", "service": "backend-prod" },
           "db": { "platform": "railway", "service": "postgres-prod" }
         }
       }
     }
   }
   ```

---

## Multi-environment (dev + prod)

Real projects often have separate `dev` and `prod` infrastructure with different credentials. The hook **only auto-injects `dev`** — `prod` and any other env are invoked by name only.

### Adding a prod environment

> "add `prod` environment to `acme-erp`. AWS profile `acme-erp-prod`, region `us-east-1`. Backend ECS cluster `acme-erp-prod-cluster`, service `acme-erp-prod-server`."

Mapping after:

```json
{
  "projects": {
    "acme-erp": {
      "repos": { "backend": "..." },
      "envs": {
        "dev":  { "credentials": {...}, "services": {...} },
        "prod": {
          "credentials": {
            "AWS_PROFILE": "acme-erp-prod",
            "AWS_REGION": "us-east-1"
          },
          "services": {
            "backend": {
              "platform": "aws",
              "service_type": "ecs-fargate",
              "cluster": "acme-erp-prod-cluster",
              "service": "acme-erp-prod-server",
              "log_group": "/ecs/acme-erp-prod-server"
            }
          }
        }
      }
    }
  }
}
```

### How prod is invoked

| You're in `~/code/acme-erp-backend` and run | Result |
|---------------------------------------------|--------|
| `aws sts get-caller-identity` | Hook auto-injects `dev` profile (safe) |
| You ask Claude: "show prod backend logs" | Claude resolves prod, runs `AWS_PROFILE=acme-erp-prod aws logs tail ...` (explicit) |
| You ask Claude: "redeploy prod" | Claude confirms first ("you want to redeploy `acme-erp-prod-server`?"), then runs |

The hook **never** auto-injects prod credentials. This is by design.

---

## Registering a PEM key for EC2 / SSH

Some products still need a SSH PEM key — e.g. you're SSH'ing into an EC2 bastion or a non-SSM-managed instance, or a vendor handed you a `.pem` for their host. The plugin supports this without a schema change.

### Two registration shapes

Pick based on whether the host is already wired up in your `~/.ssh/config`:

| Shape | When to use | What the mapping stores |
|-------|-------------|--------------------------|
| **`ssh_alias`** (preferred when ssh config has the host) | `ssh <alias>` already works on your machine | just `{platform:"ssh", ssh_alias:"<alias>"}` — host/user/identity come from `~/.ssh/config` |
| **explicit** (`host` + `user` + `key`) | no `~/.ssh/config` entry, or you want the plugin to own the connection details | `{platform:"ssh", host, user, key:"EC2_SSH_KEY"}` plus a credential pointing at the PEM path |

If you give Claude a paste of your `~/.ssh/config` Host block, it extracts hostname/user/identity from there and registers via `ssh_alias`. If you only give a PEM file plus a hostname, it falls through to the explicit shape.

### Shape A — ssh_alias (delegate to ~/.ssh/config)

If `ssh dalcom` already connects to your prod box, the registration is one line:

```bash
PA="$(ls -d ~/.claude/plugins/cache/project-accounts/project-accounts/*/scripts/pa-update.sh | sort -V | tail -1)"
"$PA" '.projects.dalcom.envs.prod.services.backend = {"platform":"ssh","ssh_alias":"dalcom"}'
```

No need to register an `EC2_SSH_KEY` credential — the IdentityFile lives in your ssh config. `pa-doctor` resolves the alias via `ssh -G`, fails if the alias isn't found in your ssh config, and probes the resolved hostname for reachability.

When Claude later runs "ssh into dalcom prod backend", it executes `ssh dalcom` — no `-i`, no `-l`, no host substitution.

### Shape B — explicit host/user/key

Use this path when there's no `~/.ssh/config` entry to delegate to.

PEM key vs. token — different consumption pattern:

| Secret type | How CLI consumes it | How to store in mapping |
|-------------|---------------------|--------------------------|
| API token (Vercel, Railway) | flag value: `--token=<content>` | `@file:` reference (hook reads file → injects content) |
| PEM key | path argument: `ssh -i <path>` | plain string path (hook injects path; CLI opens the file itself) |

#### What you need before starting

A PEM file alone is **not enough** — to actually SSH you need the trio: **key + host + user**. Have these ready before asking Claude to register:

| Field | Example |
|-------|---------|
| PEM file location | `~/Downloads/acme.pem`, `~/Downloads/acme-blue.pem` |
| Host (DNS or IP) | `bastion.acme.com`, `54.180.x.x` |
| User | `ubuntu`, `ec2-user`, `bitnami` (depends on AMI) |
| Service role | `backend`, `bastion`, `db`, ... |

#### Step 1 — move the PEM into the secrets directory

Claude runs (per env):

```bash
mkdir -p ~/.claude/secrets && chmod 700 ~/.claude/secrets
cp ~/Downloads/acme.pem      ~/.claude/secrets/acme-prod.pem && chmod 600 ~/.claude/secrets/acme-prod.pem
cp ~/Downloads/acme-blue.pem ~/.claude/secrets/acme-dev.pem  && chmod 600 ~/.claude/secrets/acme-dev.pem
```

(If you'd rather keep the PEM in `~/.ssh/`, you can — `~/.claude/secrets/` is just the recommended default. Register whatever absolute path you prefer in the next step.)

#### Step 2 — register the key path as a credential

Mutations of the mapping go through the plugin's `pa-update` helper, which writes a timestamped backup, validates the result, and atomically replaces the file (chmod 600). Resolve its path once:

```bash
PA="$(ls -d ~/.claude/plugins/cache/project-accounts/project-accounts/*/scripts/pa-update.sh | sort -V | tail -1)"
```

Then:

```bash
"$PA" '.projects.acme.envs.dev.credentials.EC2_SSH_KEY  = "~/.claude/secrets/acme-dev.pem"
     | .projects.acme.envs.prod.credentials.EC2_SSH_KEY = "~/.claude/secrets/acme-prod.pem"'
```

Plain string, **not `@file:`** — the value is a *path*, not key contents. The hook expands leading `~` automatically.

#### Step 3 — register the ssh service (host + user)

Without this, the registration is dead data — Claude knows the key but not where to use it.

```bash
"$PA" '.projects.acme.envs.dev.services.backend  = {"platform":"ssh","host":"13.124.x.x", "user":"ubuntu","key":"EC2_SSH_KEY"}
     | .projects.acme.envs.prod.services.backend = {"platform":"ssh","host":"54.180.x.x","user":"ubuntu","key":"EC2_SSH_KEY"}'
```

#### Step 4 — verify with a connection test

Always run a sanity check after registration:

```bash
ssh -i ~/.claude/secrets/acme-prod.pem \
    -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    ubuntu@54.180.x.x 'echo ok && uname -a'
```

If it times out: instance may be stopped, IP may have changed (Public IPv4 changes after restart unless an Elastic IP is attached), or your current public IP isn't allowed by the security group's port-22 inbound rule.

#### Step 5 — use it

For dev with a registered repo: hook auto-injects `EC2_SSH_KEY`, so:

```bash
ssh -i "$EC2_SSH_KEY" ubuntu@<host>
```

For prod or any name-based call:

> "ssh into acme prod backend"

Claude resolves key + host + user from the mapping and runs the full command.

### When you don't need PEM at all

If the EC2 has SSM agent + a SSM-enabled IAM role, skip PEM entirely and use:

```bash
aws ssm start-session --target i-0abc123...
```

— uses your AWS profile only, no SSH/PEM. Worth trying first; it's the modern path.

---

## Storing secrets safely

Tokens (Vercel, Railway, Heroku, GCP service-account JSON, etc.) must not appear in chat or shell history. Two safe paths:

### A. Clipboard (fastest, on macOS)

You copy the token. Tell Claude:

> "save token `<name>` from clipboard"

Claude runs:

```bash
pbpaste | tr -d '\r\n' > ~/.claude/secrets/<name>.token && \
  chmod 600 ~/.claude/secrets/<name>.token
```

The token never enters Claude's context.

### B. Interactive prompt (if no clipboard utility)

You run this yourself with the `!` prefix so input never reaches Claude:

```
! read -s -p "Paste token: " TOKEN && \
    printf '%s' "$TOKEN" > ~/.claude/secrets/<name>.token && \
    chmod 600 ~/.claude/secrets/<name>.token && \
    unset TOKEN && echo saved
```

### Reference in mapping

Always reference the file, never inline the token:

```json
"credentials": {
  "RAILWAY_TOKEN": "@file:~/.claude/secrets/acme-erp-railway.token"
}
```

The plugin resolves `@file:` at command execution time and injects the file's contents into the env var. The plain-text mapping JSON only ever stores the path.

### Rotating a secret

> "rotate the Railway token for `acme-erp` — new one is in clipboard"

Claude overwrites the same file. Mapping doesn't need to change.

---

## Natural-language invocation patterns

How Claude resolves your request, with concrete examples:

| What you say | What Claude resolves |
|--------------|---------------------|
| "show `acme-erp` prod backend logs from the last hour" | project=`acme-erp`, env=`prod`, service=`backend` → `AWS_PROFILE=acme-erp-prod aws logs tail /ecs/acme-erp-prod-server --since 1h` |
| "deploy `acme-storefront` to production" | project=`acme-storefront`, env=`dev` (only env), service=`frontend`, command needs `--prod` flag → `VERCEL_TOKEN=... vercel deploy --prod` |
| "what's the current ECS task count for `acme-erp` prod?" | project=`acme-erp`, env=`prod`, service=`backend` (ECS) → `aws ecs describe-services --cluster ... --query 'services[0].{desired,running,pending}'` |
| "is the `acme-erp` prod RDS healthy?" | project=`acme-erp`, env=`prod`, service=`db` → `aws rds describe-db-instances --db-instance-identifier ... --query '...DBInstanceStatus'` |
| "list all my registered projects" | `jq '.projects \| keys' ~/.claude/project-accounts.json` |
| "which project does this directory belong to?" | longest-prefix match on `repos.*` paths against `$PWD` |

If a request is ambiguous (e.g., "show backend logs" without a project name), Claude asks for clarification before running anything.

---

## Troubleshooting

### Two read-only commands you'll lean on

```bash
PA_ROOT="$(ls -d ~/.claude/plugins/cache/project-accounts/project-accounts/*/scripts | sort -V | tail -1)"
"$PA_ROOT/pa-status.sh"   # what would inject for $PWD right now
"$PA_ROOT/pa-doctor.sh"   # full health check across the whole mapping
```

`pa-status.sh` is the fastest way to see "why is the hook (not) doing X here?" — it shows the project match, the dev credentials with file/permission status, and the registered services.

`pa-doctor.sh` walks every project, every env, every credential, every ssh service (TCP probe), and every entry in `managed_clis`. Run it after switching machines, restoring from backup, or whenever something feels off. Set `PA_SKIP_NETWORK=1` to skip TCP probes.

### Hook doesn't fire on `cd <repo> && <cli>`

The hook reads `cwd` from the tool input, which is the **session CWD when the bash invocation started** — not where the command navigates to. Fix: actually `cd` in your terminal first, then run the CLI command. Or invoke by name through Claude.

### Hook fires but no env vars injected

`pa-status.sh` will tell you the cause directly. If you'd rather check by hand:

1. Is the directory under one of your registered repos?
2. Does the project have an `envs.dev` block? The hook only auto-injects `dev`.
3. Is the CLI name in `managed_clis`? If you added a new CLI, add it to that list.
4. Did you set the env var inline in your command (e.g., `AWS_PROFILE=other aws ...`)? The hook respects user overrides — and now reports them as `(skipped: <KEY>(override-in-command))` in its `systemMessage`.
5. Is the `@file:` token file readable? If not, the hook reports `(skipped: <KEY>(unreadable:<path>))`.

### `ssh_alias` service warnings in pa-doctor / pa-status

- **"hostname resolves to alias literal"** — `ssh -G` returned the alias as the hostname. Two possible causes: (a) the alias has no matching `Host` block in your ssh config (most common), or (b) you intentionally have `Host foo / HostName foo`. The plugin can't reliably distinguish, so it warns and still TCP-probes — the reachability result tells you whether it's a real target. To verify configuration: `ssh -G -- <alias> | head -3`.
- **"invalid (allowed: A-Z a-z 0-9 . _ -, no leading -)"** — the alias name contains a character the plugin won't pass to `ssh -G`. Rename the Host alias to fit, then update the mapping.

### `Match exec` blocks in `~/.ssh/config` execute during pa-doctor / pa-status

OpenSSH evaluates `Match exec "<cmd>"` blocks while parsing the config — even under `ssh -G`, which doesn't connect. If your `~/.ssh/config` has any `Match exec` directives (commonly used for VPN / network detection), `<cmd>` will run every time the plugin resolves an `ssh_alias`. This is OpenSSH behavior, not the plugin — but worth knowing if you're surprised to see your match probe firing on every `pa-doctor` run.

### Vercel/Railway returns "unauthorized"

Token may have expired or been revoked. Rotate it (see above) and update the secrets file.

### Plugin not loading after install

The plugin is downloaded on Claude Code startup. After running `claude plugin install`, fully restart Claude Code (not just `/clear`). Verify:

```bash
ls ~/.claude/plugins/cache/project-accounts/
```

### Multiple projects match the current directory

Longest-prefix wins. If you have `~/code/acme` and `~/code/acme/backend` registered as separate repos, `~/code/acme/backend/sub` resolves to the deeper one. Check with:

```bash
CWD="$PWD"
jq -r --arg cwd "$CWD" '
  [(.projects // {}) | to_entries[] | .key as $p | (.value.repos // {}) | to_entries[] | {project: $p, repo: .key, path: .value}]
  | map(select(.path as $pa | $cwd == $pa or ($cwd | startswith($pa + "/"))))
  | sort_by(.path | length) | reverse | .[0]
' ~/.claude/project-accounts.json
```
