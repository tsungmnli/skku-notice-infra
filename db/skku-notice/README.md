# db/skku-notice

`skku-notice-infra` repo의 `db/skku-notice/` 폴더입니다 (API repo에는 두지 않습니다).
홈서버 Postgres에 skku-notice용 데이터베이스와 역할을 만듭니다.

비밀번호는 `init.sql` 에 적지 않고 **`.env` 파일**에 둡니다. `.env` 는 `.gitignore` 에 들어 있어 실수로 push 되지 않습니다 (커밋되는 것은 `.env.example` 뿐입니다).

```bash
cd db/skku-notice
cp .env.example .env
# .env 를 열어 SKKU_APP_PASSWORD 를 무작위 값으로 채웁니다.  (생성: openssl rand -hex 24)

set -a; . ./.env; set +a           # .env 를 환경변수로 불러오기
psql -h <홈서버IP> -U postgres -f init.sql
```

`psql` 은 15 버전 이상이어야 합니다(`psql --version`). 비밀번호가 없거나 `CHANGE-ME` 그대로면 스크립트가 아무것도 만들지 않고 멈춥니다.

체크리스트

1. 위 명령으로 DB/역할 생성.
2. Vault `kv/skku-notice` 에 `DATABASE_URL=postgresql://skku_app:<.env의 비밀번호>@<홈서버IP>:5432/skkunoti` 저장.
3. 방화벽/`pg_hba.conf`: 5432는 클러스터 노드 IP에서만 허용 (인터넷 전체 개방 금지).
4. 백업: `pg_dump -Fc skku` 를 정기 실행하도록 설정 (스키마는 마이그레이션으로 복원 가능하지만 크롤링 데이터는 아닙니다).
5. 클러스터에서 접속 확인: `kubectl run dbtest --image=postgres:17 --restart=Never --command -- pg_isready -h <홈서버IP> -p 5432`

스키마(테이블)는 여기서 만들지 않습니다. API 배포 때 Sync 훅 Job(wave 0)이 `python -m app.migrate` 로 만듭니다.

> 이미 실제 비밀번호가 들어간 채로 커밋·push 한 적이 있다면 그 비밀번호는 노출된 것으로 보고 `ALTER ROLE skku_app PASSWORD '새값'` 으로 바꾸고 Vault 값도 갱신하세요.
