# config

`skku-notice-infra` repo의 `config/` 입니다. API(`tsungmn/skku-notice-api`, Docker Hub) 하나의 이미지로 세 가지를 돌립니다.

| 리소스 | 하는 일 | 순서(sync-wave) |
| --- | --- | --- |
| Secret, ConfigMap | `DATABASE_URL`(Vault), 비밀이 아닌 설정 | -1 |
| `skku-notice-migrate` Job | `python -m app.migrate`. 끝나야 다음으로 진행 | 0 |
| `skku-notice-api` Deployment + Service + Ingress | API. 프로브 `/api/healthz`, `/api/readyz` | 1 |
| `skku-notice-crawler` CronJob | `python -m app.crawl`, 30분마다 (07:00~23:30 KST) | 1 |

새 버전이 나가는 방법: API repo `main`에 push → Actions가 이미지를 빌드해 Docker Hub에 올리고 → 이 repo의 `config/overlays/api/kustomization.yaml` 의 `newTag` 를 커밋 → Argo CD가 감지해 마이그레이션 → 롤아웃.
웹도 같은 방식입니다: web repo `main`에 push → 이미지 빌드 → 이 repo의 `config/overlays/web/kustomization.yaml` 의 `newTag` 커밋.
Application의 Auto-Sync가 꺼져 있으면 태그 커밋 뒤 Argo CD에서 직접 SYNC 를 눌러야 반영됩니다.

## 배포 전 확인 (API에 계정 기능이 들어간 버전부터)

API는 prod에서 필수 설정이 하나라도 빠지면 **부팅을 거부**하고, 마이그레이션 Job도 같은 설정을 읽어서 같이 실패합니다(그러면 Sync가 wave 0에서 멈추고 기존 파드는 그대로 남습니다 — 서비스는 안 끊기지만 배포가 안 됩니다). 새 태그를 올리기 **전에**:

1. Vault `kv/skku-notice-tsungmn` 에 다음 키를 추가합니다. 없는 키가 하나라도 있으면 argocd-vault-plugin 렌더링이 실패합니다.

   | 키 | 값 |
   | --- | --- |
   | `SMTP_PASSWORD` | Resend API 키 (SMTP 비밀번호) |
   | `TURNSTILE_SECRET_KEY` | Cloudflare Turnstile **secret** (web 빌드의 site key와 같은 위젯 것) |
   | `SESSION_SECRET` | 32자 이상 무작위 값: `python -c "import secrets; print(secrets.token_urlsafe(48))"` |

   Google 로그인을 켤 때만 `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` 를 추가하고 `overlays/api/secret.yaml` 의 주석을 푸세요. 리디렉션 URI는 `https://skkunoti.tsungmn.com/api/v1/auth/google/callback`.
2. `overlays/api/config.yaml` 의 `SMTP_*` 와 `TRUSTED_PROXY_HOPS`. 발신 도메인(`SMTP_FROM`, 기본 `noreply@skkunoti.tsungmn.com`)이 Resend에서 인증돼 있어야 메일이 갑니다.
3. **`TRUSTED_PROXY_HOPS` 가 실제 경로와 맞는지.** Cloudflare → ingress-nginx → API 이면 2 입니다. ingress-nginx 의 ConfigMap 에 `use-forwarded-headers: "true"` 가 없으면 nginx 가 클라이언트의 `X-Forwarded-For` 를 버려서 API 가 모두를 같은 IP(ingress 파드)로 보고, 그러면 로그인 실패 한도(IP당 15분 50회)를 모든 사용자가 나눠 쓰게 됩니다. Cloudflare 를 거치지 않으면 1, 프록시가 하나도 없으면 0. 값을 바꾸면 `rollout restart` 가 필요합니다.
4. web repo(GitHub)의 repo variable `TURNSTILE_SITE_KEY` 가 채워져 있는지. web `deploy.yml` 이 `main` 빌드에서 값이 비어 있거나 Cloudflare 테스트 키(`1x…`, `2x…`, `3x…`)면 실패시킵니다 (PR 빌드는 검사하지 않음). 이 값과 Vault 의 `TURNSTILE_SECRET_KEY` 가 **같은 위젯** 것인지는 CI 가 알 수 없으니 아래 확인 3번으로 봅니다.
5. Google 로그인을 켤지 정합니다. 안 켜도 로그인 화면의 Google 버튼은 보이고(web 은 숨길 방법이 없음), 누르면 `/login?error=google_disabled` 로 돌아와 "지금은 Google 로그인을 사용할 수 없습니다"가 나옵니다. 켜려면 위 Google 항목을 먼저 하세요.

## 배포 순서와 확인

API 와 web 은 어느 쪽을 먼저 올려도 서로 깨지지 않습니다. 이번 마이그레이션(0002, 0003)은 컬럼·테이블 추가뿐이라 기존 API 파드가 돌아가는 중에 실행해도 안전하고, 새 web 이 옛 API 를 만나도 `/me` 가 404 라서 비로그인으로 보일 뿐입니다. 그래도 **API → web 순서**로 올리고 각 단계 확인을 끝낸 뒤 다음으로 가세요. 문제가 생겼을 때 원인이 한 곳으로 좁혀집니다.

**0. 올리기 전** (위 "배포 전 확인" 1~5)

**1. API** — API repo `main` push → CI 통과 → 이미지 → 이 repo 의 api `newTag` 커밋 → Argo CD Sync (Auto-Sync 가 꺼져 있으면 직접 SYNC)

1. `kubectl -n skku-notice-prod get job skku-notice-migrate` 가 Complete, `kubectl -n skku-notice-prod logs job/skku-notice-migrate` 에 `0003` 적용이 보이는지
2. `kubectl -n skku-notice-prod rollout status deploy/api-deployment`, `https://skkunoti.tsungmn.com/api/readyz` 가 200
3. 읽기 API 가 그대로인지: `/api/v1/articles?size=1` 200
4. 계정 API: `GET /api/v1/me` (쿠키 없이) 401, `POST /api/v1/auth/login` 에 `Origin: https://evil.example` 를 붙이면 403 `origin_not_allowed`
5. 다음 크롤러 실행 로그에 `cleanup: sessions=N email_tokens=M removed`

**2. web** — web repo `main` push → CI(Turnstile 키·번들 검사 포함) → 이미지 → web `newTag` 커밋 → Sync

1. `https://skkunoti.tsungmn.com/` 과 `/signup`, `/login` 이 열리는지 (브라우저 개발자 도구 Network 에서 요청이 `localhost` 가 아니라 `/api/v1/...` 로 나가는지)
2. `/signup` 에 Turnstile 위젯이 보이는지 ("회원가입을 일시적으로 사용할 수 없습니다"가 보이면 site key 가 번들에 없는 것)

**3. 처음부터 끝까지** (새 이메일 하나로, 시크릿 창에서)

1. 가입 → 인증 메일 도착(스팸함 포함) → 메일 링크 → 로그인 → `/account` 가 열림. 개발자 도구 Application > Cookies 에서 `sid` 가 `HttpOnly`, `Secure`, `Path=/api` 인지
2. 로그아웃 후 새로고침해도 비로그인 상태인지
3. 비밀번호 찾기 메일 → 링크 → 새 비밀번호 → 옛 세션이 끊김
4. Turnstile 이 실제로 통과되는지 (가입이 `captcha_failed` 로 막히면 site key 와 secret 이 서로 다른 위젯 것)
5. `TRUSTED_PROXY_HOPS`: 위 시험을 하는 동안 API 로그/제한 키에 찍히는 IP 가 내 공인 IP 인지 (Cloudflare 나 클러스터 IP 가 보이면 값이 틀림)
6. Google 을 켠 경우: 로그인 버튼 → Google → 사이트로 돌아와 로그인됨. 켜지 않은 경우: 버튼을 누르면 로그인 화면에 안내 문구
7. 시험 계정은 `/account` 에서 삭제

**문제가 생기면**

- **마이그레이션 Job 실패**: Sync 가 wave 0 에서 멈추고 기존 API 파드는 그대로 돕니다. 대개 Vault 키나 환경변수 누락이니 고친 뒤 Argo CD 에서 다시 Sync.
- **새 API 파드가 부팅을 거부(CrashLoop)**: Deployment 는 롤링 업데이트(replicas 1, 기본 전략)라 새 파드가 Ready 가 되기 전에는 기존 파드가 유지됩니다. `kubectl logs` 의 `prod requires: ...` 메시지대로 값을 채우세요.
- **되돌리기**: 이 repo 에서 해당 `newTag` 커밋을 `git revert` 해서 push 합니다 (Auto-Sync 앱에서는 Argo CD UI 의 Rollback 이 다시 덮어써지므로 git 으로 되돌립니다). web 만, 또는 API 만 따로 되돌려도 됩니다.
- **마이그레이션은 되돌리지 않습니다.** 0003 의 downgrade 는 `users`, `sessions`, `email_tokens` 테이블을 지워 가입자 데이터가 사라집니다. 옛 API 는 새 테이블·컬럼을 쓰지 않아서 스키마를 그대로 둬도 동작합니다. 옛 API + 새 web 조합은 `/me` 404 로 비로그인처럼 보이고 로그인·가입이 안 되니, 그 상태가 길어지면 web 도 같이 되돌리세요.
- ConfigMap(`config.yaml`)만 바꾼 경우는 `kubectl -n skku-notice-prod rollout restart deploy/api-deployment` 가 있어야 반영됩니다.
- 권장: Cloudflare 에서 `/api/v1/auth/*` 에 Rate limiting 규칙을 둡니다. API 의 제한기는 프로세스 메모리라 재시작 때 초기화됩니다.

## 처음 한 번만 (순서대로)

1. **DB**: `db/skku-notice/README.md` 대로 DB/역할을 만들고 Vault `kv/skku-notice` 에 `DATABASE_URL` 저장.
2. **값 확인**: 아래 "바꿀 때 같이 볼 곳".
3. **API repo와 web repo 양쪽의 Secrets**: `DOCKER_PASSWORD`(Docker Hub), `CONFIG_REPO_TOKEN` = fine-grained PAT (resource owner `tsungmnli`(GitHub 계정), `skku-notice-infra` repo만, Contents: Read and write).
4. **이 repo(`skku-notice-infra`)를 push.**
5. **API repo와 web repo `main`에 각각 push** 해서 첫 이미지를 만듭니다. (이 전에 Application을 만들면 api는 `newTag: placeholder`, web은 `newTag: ""`(태그 없음 = latest) 라서 ImagePullBackOff가 납니다. 이미지는 커밋 해시 태그로만 올라가며 `latest` 는 없습니다.)
6. **Argo CD에서 Application 만들기** (UI의 NEW APP). api와 web 각각:

   | 항목 | skku-notice-api | skku-notice-web |
   | --- | --- | --- |
   | Repository / Revision | `skku-notice-infra` / `main` | 같음 |
   | Path | `config/overlays/api` | `config/overlays/web` |
   | Destination namespace | `skku-notice-prod` | 해당 overlay의 `namespace:` 값 |
   | Sync Options | Auto-Create Namespace | 같음 |
   | Plugin | `argocd-vault-plugin-kustomize` | (없음) |

   Destination namespace를 비워 두면 Auto-Create Namespace 가 아무것도 만들지 않습니다. kustomize의 `namespace:` 와는 별개로 Application에도 적어야 합니다.
7. 확인: `kubectl -n skku-notice-prod get job,pods,cronjob` 그리고 `https://<호스트>/api/readyz` 가 200.
8. **과거 글 채우기 (한 번)**:
   ```bash
   kubectl -n skku-notice-prod create job backfill --from=cronjob/skku-notice-crawler \
     --dry-run=client -o json \
     | jq '.spec.template.spec.containers[0].env=[{"name":"CRAWL_MAX_PAGES","value":"50"}]' \
     | kubectl apply -f -
   kubectl -n skku-notice-prod logs -f job/backfill
   ```

## 바꿀 때 같이 볼 곳

`travel-planner-config` 와 같은 구조(`base/` 는 공통 설계도, `overlays/` 가 값)입니다.

1. `overlays/api/secret.yaml` — Vault 경로 문법. KV v2면 `kv/data/...`, v1이면 `kv/...`.
2. 호스트(`skkunoti.tsungmn.com`) — `overlays/api/domain.json`, `overlays/web/domain.json`, `overlays/api/config.yaml` 의 `PUBLIC_URL`·`CORS_ORIGINS`, 웹 repo `deploy.yml` 의 `API_BASE`. 모두 같은 값이어야 합니다.
3. 웹은 같은 호스트의 `/`, API는 `/api` 로 나뉩니다.
4. 새 이미지 버전은 `overlays/api/kustomization.yaml` 의 `newTag` 입니다(CI가 고칩니다).

## 알아둘 점

- 마이그레이션이 PreSync가 아니라 **Sync 훅(wave 0)** 인 이유: PreSync는 Secret보다도 먼저 돌아서 첫 배포 때 `DATABASE_URL` 없이 실패합니다.
- 모든 컨테이너는 non-root, 읽기 전용 파일시스템입니다. 시작 때 "Read-only file system" 오류가 나면 해당 컨테이너의 `readOnlyRootFilesystem` 을 `false` 로 바꾸세요.
- api·web Ingress 는 같은 호스트와 같은 Secret(`gitops-tls`)을 가리킵니다. 두 앱이 **같은 네임스페이스**에 있어야 인증서 하나를 같이 씁니다(네임스페이스가 다르면 인증서가 두 번 발급됩니다).
- 인증서 발급기는 `tsungmn-infra` 저장소의 `ClusterIssuer letsencrypt-tsungmn` 입니다(travel-planner와 공유). 이 서비스를 배포하기 전에 그 저장소가 먼저 배포되어 있어야 합니다.
- ConfigMap(`overlays/api/config.yaml`) 값을 바꿔도 파드는 저절로 재시작되지 않습니다. 바꾼 뒤 `kubectl -n skku-notice-prod rollout restart deploy/api-deployment` 를 하세요.
- 크롤러 CronJob의 `timeZone` 은 Kubernetes 1.27 이상이 필요합니다.
