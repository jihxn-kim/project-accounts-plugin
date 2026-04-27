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

### Hook doesn't fire on `cd <repo> && <cli>`

The hook reads `cwd` from the tool input, which is the **session CWD when the bash invocation started** — not where the command navigates to. Fix: actually `cd` in your terminal first, then run the CLI command. Or invoke by name through Claude.

### Hook fires but no env vars injected

Check:

1. Is the directory under one of your registered repos? `jq -r --arg cwd "$PWD" '... ' ~/.claude/project-accounts.json` (full query in `skills/project-accounts/SKILL.md`).
2. Does the project have an `envs.dev` block? The hook only auto-injects `dev`.
3. Is the CLI name in `managed_clis`? If you added a new CLI, add it to that list.
4. Did you set the env var inline in your command (e.g., `AWS_PROFILE=other aws ...`)? The hook respects user overrides.

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
