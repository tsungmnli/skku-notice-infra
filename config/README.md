# config

`skku-notice-infra` repo의 `config/` 입니다. API(`tsungmn/skku-notice-api`, Docker Hub) 하나의 이미지로 세 가지를 돌립니다.

| 리소스 | 하는 일 | 순서(sync-wave) |
| --- | --- | --- |
| Secret, ConfigMap | `DATABASE_URL`(Vault), 비밀이 아닌 설정 | -1 |
| `skku-notice-migrate` Job | `python -m app.migrate`. 끝나야 다음으로 진행 | 0 |
| `skku-notice-api` Deployment + Service + Ingress | API. 프로브 `/api/healthz`, `/api/readyz` | 1 |
| `skku-notice-crawler` CronJob | `python -m app.crawl`, 30분마다 (07:00~23:30 KST) | 1 |

새 버전이 나가는 방법: API repo `main`에 push → Actions가 이미지를 빌드해 Docker Hub에 올리고 → 이 repo의 `config/overlays/api/kustomization.yaml` 의 `newTag` 를 커밋 → Argo CD가 감지해 마이그레이션 → 롤아웃.

## 처음 한 번만 (순서대로)

1. **DB**: `db/skku-notice/README.md` 대로 DB/역할을 만들고 Vault `kv/skku-notice` 에 `DATABASE_URL` 저장.
2. **값 확인**: 아래 "바꿀 때 같이 볼 곳".
3. **API repo Secrets**: `DOCKER_PASSWORD`(Docker Hub), `CONFIG_REPO_TOKEN` = fine-grained PAT (resource owner `tsungmn`, `skku-notice-infra` repo만, Contents: Read and write).
4. **이 repo(`skku-notice-infra`)를 push.**
5. **API repo `main`에 push** 해서 첫 이미지를 만듭니다. (이 전에 Application을 만들면 `newTag: placeholder` 라서 ImagePullBackOff가 납니다.)
6. **Argo CD에서 Application 만들기** (UI의 NEW APP). api와 web 각각:

   | 항목 | skku-notice-api | skku-notice-web |
   | --- | --- | --- |
   | Repository / Revision | `skku-notice-infra` / `main` | 같음 |
   | Path | `config/overlays/api` | `config/overlays/web` |
   | Destination namespace | `skku-notice` | 해당 overlay의 `namespace:` 값 |
   | Sync Options | Auto-Create Namespace | 같음 |
   | Plugin | `argocd-vault-plugin-kustomize` | (없음) |

   Destination namespace를 비워 두면 Auto-Create Namespace 가 아무것도 만들지 않습니다. kustomize의 `namespace:` 와는 별개로 Application에도 적어야 합니다.
7. 확인: `kubectl -n skku-notice get job,pods,cronjob` 그리고 `https://<호스트>/api/readyz` 가 200.
8. **과거 글 채우기 (한 번)**:
   ```bash
   kubectl -n skku-notice create job backfill --from=cronjob/skku-notice-crawler \
     --dry-run=client -o json \
     | jq '.spec.template.spec.containers[0].env=[{"name":"CRAWL_MAX_PAGES","value":"50"}]' \
     | kubectl apply -f -
   kubectl -n skku-notice logs -f job/backfill
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
- 인증서 발급기는 `tsungmn-config` 저장소의 `ClusterIssuer letsencrypt-tsungmn` 입니다(travel-planner와 공유). 이 서비스를 배포하기 전에 그 저장소가 먼저 배포되어 있어야 합니다.
- ConfigMap(`overlays/api/config.yaml`) 값을 바꿔도 파드는 저절로 재시작되지 않습니다. 바꾼 뒤 `kubectl -n skku-notice rollout restart deploy/api-deployment` 를 하세요.
- 크롤러 CronJob의 `timeZone` 은 Kubernetes 1.27 이상이 필요합니다.
