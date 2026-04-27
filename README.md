# project-accounts

Per-project CLI credential routing for Claude Code. Stop juggling AWS profiles, Vercel tokens, Railway logins, and friends — declare them once per project and let Claude (and a tiny PreToolUse hook) inject the right ones automatically.

## What it does

1. **Hook** — when you `cd` into a registered repo and run `aws`, `railway`, `vercel`, `gcloud`, `flyctl`, `doctl`, `heroku`, or `supabase`, the right env vars (profile names, tokens, scope IDs) are prepended to the command. The CLI just works without flags or `--profile` juggling.
2. **Skill** — when you ask Claude in natural language ("acme-erp prod backend logs from 12:30", "deploy with_dan to production"), Claude looks up the project in your mapping, pulls the credentials from a secret file, and runs the right command — even if you're not in the repo directory.

## Safety: dev auto, prod explicit

The hook **only** auto-injects credentials from `envs.dev.credentials`. Production and other envs are invoked **by name only** through the skill, so you can't accidentally `railway redeploy` against prod just by being in the repo. This is intentional and not configurable.

## Install

This plugin is distributed as a Claude Code marketplace plugin. From this directory:

```bash
claude plugin marketplace add /path/to/project-accounts-plugin
claude plugin install project-accounts@project-accounts
```

(or add the GitHub source once published).

After install, the first time the hook runs it will create an empty mapping file at `~/.claude/project-accounts.json`. The skill teaches Claude how to populate it.

## First use

Just ask Claude: "register a new project, name X, AWS profile Y" — the skill handles the rest, including walking you through token storage if you have secrets to keep out of the JSON.

If you prefer to set things up by hand, see `skills/project-accounts/SKILL.md` for the full schema and jq command catalog.

## Security notes

- **Never paste tokens into chat.** Tokens that pass through Claude's context end up in transcripts, logs, and potentially training data. The skill's token-storage commands use `pbpaste` (clipboard read) or `read -s` (terminal-only input) so secrets stay out of the model context.
- Tokens live in `~/.claude/secrets/*.token` (chmod 600), referenced from the mapping via `@file:<path>`. The plain-text JSON only contains the *path*, never the token itself.
- `~/.claude/project-accounts.json` and `~/.claude/secrets/` are per-machine personal state. Don't commit them.

## Schema (quick reference)

```json
{
  "managed_clis": ["aws", "railway", "vercel", "..."],
  "projects": {
    "<project-name>": {
      "aliases":  ["optional human-readable names"],
      "repos":    { "backend": "/abs/path", "frontend": "/abs/path" },
      "envs": {
        "dev":  { "credentials": {...}, "services": {...} },
        "prod": { "credentials": {...}, "services": {...} }
      },
      "notes": "free-form"
    }
  }
}
```

Full operation catalog (add project, add repo, add env, store token, etc.) lives in the skill — Claude reads it on demand.

## Contributing / issues

PRs welcome. Especially: adding new `managed_clis` defaults, platform-specific helpers in the skill cheat sheet, and refining the natural-language resolution rules.

## License

MIT
