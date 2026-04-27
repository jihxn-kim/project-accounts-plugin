# project-accounts

Claude Code 용 **프로젝트별 CLI 자격증명 라우터**. AWS 프로파일, Vercel 토큰, Railway 로그인 등을 프로젝트마다 갈아끼우는 짓을 그만 — 한 번 등록해두면 Claude (와 작은 PreToolUse 훅)가 알아서 올바른 자격증명을 주입해줍니다.

## 핵심 기능

### 1. Hook — `cd` 기반 자동 주입
등록된 레포 경로 안에서 `aws`, `railway`, `vercel`, `gcloud`, `flyctl`, `doctl`, `heroku`, `supabase` 명령을 치면 PreToolUse Bash 훅이 그 프로젝트의 **dev** 자격증명을 자동으로 앞에 붙여줍니다.

- `aws s3 ls` → `AWS_PROFILE=acme-dev aws s3 ls`
- `vercel deploy` → `VERCEL_TOKEN=... VERCEL_ORG_ID=... vercel deploy`
- `--profile` 같은 플래그를 손으로 안 붙여도 됨.

### 2. Skill — 자연어 호출
레포 디렉토리 밖에 있어도 프로젝트 이름으로 부를 수 있습니다.

- "acme-erp prod 백엔드 로그 12:30 부터 뽑아줘"
- "storefront 를 production 으로 배포"
- "client-a-web 상태 확인"

Claude 가 `~/.claude/project-accounts.json` 매핑에서 프로젝트를 찾아 → 시크릿 파일에서 토큰을 읽어 → 적절한 CLI 명령을 실행합니다.

### 3. 매핑·시크릿 관리도 자연어로
- "새 프로젝트 등록, 이름 X, AWS 프로파일 Y" 같은 요청을 스킬이 받아 JSON 을 안전하게 갱신.
- 토큰 저장은 `pbpaste` (클립보드) 또는 `read -s` (터미널 전용) 만 사용 — **채팅 컨텍스트에 시크릿이 절대 남지 않습니다.**
- 토큰은 `~/.claude/secrets/*.token` (chmod 600) 에 저장되고, JSON 에는 `@file:<경로>` 참조만 들어갑니다.

### 4. 멀티 환경 / 멀티 레포 / 멀티 서비스
한 프로젝트 키 안에 다음을 묶을 수 있습니다.

- `repos`: 백엔드/프론트/모바일 등 여러 레포 경로
- `envs`: dev / staging / prod 별 자격증명·서비스 정의
- `services`: ECS task, Vercel deployment, Railway service 같은 logs·deploy·status 타겟

## 안전 정책: dev 자동, prod 명시

훅은 **`envs.dev.credentials` 만** 자동 주입합니다. 프로덕션을 비롯한 다른 환경은 스킬을 통해 **이름으로 명시 호출** 해야만 동작 — 레포 안에 들어가 있다고 해서 실수로 `railway redeploy` 가 prod 에 날아가는 일은 없습니다. 이 동작은 의도된 것이고 설정으로 끌 수 없습니다.

## 설치

Claude Code 마켓플레이스 플러그인 형태로 배포됩니다.

```bash
claude plugin marketplace add /path/to/project-accounts-plugin
claude plugin install project-accounts@project-accounts
```

(또는 GitHub source 로 등록).

설치 후 훅이 처음 실행될 때 빈 매핑 파일 `~/.claude/project-accounts.json` 과 시크릿 디렉토리 `~/.claude/secrets/` (chmod 700) 가 자동 생성됩니다. 매핑을 채우는 방법은 스킬이 알려줍니다.

## 첫 사용

Claude 한테 그냥 말하면 됩니다 — "새 프로젝트 등록, 이름은 X, AWS 프로파일은 Y". 시크릿이 있으면 안전하게 저장하는 단계까지 스킬이 안내합니다.

단계별 워크스루는 [docs/USAGE.md](docs/USAGE.md), 전체 스키마와 jq 명령 카탈로그는 `skills/project-accounts/SKILL.md` 를 보세요.

## 보안 노트

- **토큰을 채팅에 붙여넣지 마세요.** Claude 컨텍스트를 거친 토큰은 transcript, 로그, 잠재적 학습 데이터로 흘러갈 수 있습니다. 스킬의 토큰 저장 명령은 `pbpaste` 또는 `read -s` 만 사용하므로 시크릿이 모델 컨텍스트에 들어가지 않습니다.
- 토큰은 `~/.claude/secrets/*.token` (chmod 600) 에 저장되고, 매핑에서는 `@file:<path>` 로만 참조합니다. 평문 JSON 안에는 **경로만** 들어가고 토큰 자체는 절대 들어가지 않습니다.
- `~/.claude/project-accounts.json` 과 `~/.claude/secrets/` 는 머신별 개인 상태입니다. 커밋하지 마세요.

## 스키마 (요약)

```json
{
  "managed_clis": ["aws", "railway", "vercel", "..."],
  "projects": {
    "<project-name>": {
      "aliases":  ["선택: 사람이 부르는 별명들"],
      "repos":    { "backend": "/abs/path", "frontend": "/abs/path" },
      "envs": {
        "dev":  { "credentials": {...}, "services": {...} },
        "prod": { "credentials": {...}, "services": {...} }
      },
      "notes": "자유 양식"
    }
  }
}
```

전체 동작 카탈로그 (프로젝트 추가, 레포 추가, env 추가, 토큰 저장 등) 는 스킬 안에 들어 있고 Claude 가 필요할 때 읽어옵니다.

## 기여 / 이슈

PR 환영합니다. 특히:
- `managed_clis` 기본값 추가
- 스킬 치트시트의 플랫폼별 헬퍼
- 자연어 해석 규칙 보완

## 라이선스

MIT
