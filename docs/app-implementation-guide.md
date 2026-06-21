# 앱 구현 가이드 (인프라/메시 정합성)

micro-services(Java Spring) · bff(Node)가 이 플랫폼(EKS + Istio + ESO + RDS/MSK/Redis)에서
정상 동작하려면 **코드/설정 측에서 맞춰야 하는 계약**을 정리한다. 인프라가 주입하는 값과
앱이 읽는 키가 어긋나면 배포는 되지만 런타임에 깨진다.

관련: [mesh-mtls-grpc.md](mesh-mtls-grpc.md), [../README.md](../README.md), infrastructure/docs/ci.md

---

## 1. 포트

| 구분 | 컨테이너 포트 | 주입 방식 | 앱 요구 |
|---|---|---|---|
| HTTP(REST/actuator) | **8080** | `SERVER_PORT=8080` env | `server.port`가 env로 override 가능해야 함(Spring 기본 OK). app.yml의 8081~ 하드코딩은 env가 덮음 |
| gRPC | **9090** | `GRPC_SERVER_PORT=9090` env | gRPC 서버가 `0.0.0.0:9090` 바인딩, `grpc.server.port`를 env로 override |
| bff(Node) | 8080 | `SERVER_PORT` | Fastify가 `process.env.SERVER_PORT` 사용 |

> 포트 충돌 금지: 한 컨테이너가 8080(HTTP)+9090(gRPC) 두 리스너를 띄운다.

## 2. DB 자격증명 — 주입 키 매핑 (자주 걸림)

ESO가 Secrets Manager(`candle/<env>/rds/<db>`)를 k8s Secret `<service>-db`로 동기화하고,
Deployment가 `envFrom`으로 주입한다. **주입되는 env 키는 소문자 그대로**:

```
username  password  host  port  dbname  engine
```

Spring `application.yml`에서 이 키들을 명시적으로 참조해야 한다(자동 매핑 안 됨):

```yaml
spring:
  datasource:
    url: jdbc:postgresql://${host}:${port}/${dbname}
    username: ${username}
    password: ${password}
```

- `SPRING_DATASOURCE_USERNAME` 같은 표준 키로 자동 매핑되지 **않는다**(키가 `username`이므로). 위처럼 `${username}` 직접 참조.
- **market-service**: `dbSecret = candle/<env>/timescale/market` → `host`가 클러스터 내부 DNS(`timescaledb.candle.svc...`), `engine=timescaledb`. 동일 방식으로 연결.
- **batch**: `dbSecret = candle/<env>/rds/batch` → Spring Batch **JobRepository** datasource로만 사용. 도메인 데이터는 DB가 아니라 소유 서비스 gRPC로 접근(아래 6장).

## 3. 헬스체크 / 수명주기

- actuator 노출 필수(이미 `spring-boot-starter-actuator`). liveness = HTTP `/actuator/health`.
- gRPC 서비스: **`grpc.health.v1.Health` 구현/등록 필수** (readiness/startup이 native gRPC 프로브). 미구현 시 파드가 Ready 안 됨 → [mesh-mtls-grpc.md](mesh-mtls-grpc.md) 3장의 mTLS 주의/대안 참고.
- bff: `healthPath: /health` (Node 라우트). 실제 경로 확인.
- **graceful shutdown**: `server.shutdown: graceful` + 종료 시 in-flight 처리. 롤링 업데이트/스케일다운 시 503 방지.
- **Istio 사이드카 기동 순서**: 앱이 시작 직후 외부(gRPC/Kafka/DB) 호출을 하면 Envoy가 아직 안 떴을 수 있다 → 파드 annotation `proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'` 권장.

## 4. AWS 접근 (IRSA) — 키 하드코딩 금지

- 파드는 ServiceAccount의 IRSA로 권한을 받는다. **AWS SDK 기본 자격증명 체인**을 쓰면 자동으로 web identity 토큰을 사용한다(키/시크릿 환경변수 설정 금지).
- `notification-service`: SES 발송 → SDK 기본 자격증명.
- SA ↔ 권한 매핑은 인프라가 관리. 앱은 SA 이름(=서비스명)만 매니페스트와 일치하면 됨.

## 5. Kafka (MSK) — IAM 인증

직접 produce/consume하는 서비스(주로 consumer: ranking/mission/notification, 그리고 batch)는 MSK **IAM 인증**으로 접속:

```properties
bootstrap.servers = <MSK IAM 부트스트랩 :9098>
security.protocol  = SASL_SSL
sasl.mechanism     = AWS_MSK_IAM
sasl.jaas.config   = software.amazon.msk.auth.iam.IAMLoginModule required;
sasl.client.callback.handler.class = software.amazon.msk.auth.iam.IAMClientCallbackHandler
```

- 클라이언트 라이브러리에 `aws-msk-iam-auth` 의존성 필요(이미지/jar에 포함).
- consume는 **멱등**해야 함(같은 이벤트 재수신 가정). idempotency key 활용.

## 6. Outbox (CDC) — Kafka 직접 발행 금지

서비스는 Kafka에 직접 쏘지 않고 **같은 트랜잭션에서 `outbox` 테이블에 기록**한다. Debezium이 WAL을 읽어 발행한다.

- 각 서비스 DB(`public.outbox`) 스키마는 Debezium **Outbox Event Router** 규약과 맞춰야 한다(커넥터 설정: `table.field.event.key=aggregate_id`, 토픽=`routedByValue`):

```sql
CREATE TABLE outbox (
  id            uuid        PRIMARY KEY,
  aggregatetype text        NOT NULL,   -- 토픽 라우팅 키
  aggregateid   text        NOT NULL,   -- 메시지 key (aggregate_id)
  type          text        NOT NULL,   -- 이벤트 타입
  payload       jsonb       NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now()
);
```

- 비즈니스 변경과 outbox INSERT는 **동일 트랜잭션**(이래야 정확히 한 번 발행 보장).
- outbox 테이블에 대해 Debezium role(`debezium`)이 SELECT 가능해야 하고, logical replication publication에 포함되어야 한다(커넥터 `publication.autocreate.mode=filtered`가 처리하나, 권한은 마이그레이션에서 `GRANT SELECT ON outbox TO debezium`).
- 이벤트 producer: auth/user/trading/portfolio/mission/learning (커넥터 존재). market은 Redis Pub/Sub(아래 7장).

## 7. Redis / 실시간 시세 (market → bff)

- 캐시: `redis_price_cache`(TTL), Ranking: `redis_ranking`(Sorted Set).
- **실시간 시세는 Redis Pub/Sub** 전용 인스턴스(`redis_market_pubsub`): market가 publish, **bff가 subscribe → WebSocket으로 클라이언트 push**.
- 엔드포인트는 env/config로 주입(클러스터 내부 DNS). 전송구간 TLS 켜짐.
- **failover 시 sub 연결이 끊긴다 → bff는 재연결 로직 필수.** 각 bff 레플리카가 독립 sub하므로 sticky session 불필요.
- WebSocket은 API Gateway가 아니라 **ws.<도메인> 전용 ALB** 경로로 들어온다(내부 라우팅 bff). 긴 연결 ping/heartbeat 권장.

## 8. gRPC 내부 통신

- 호출 대상은 메시 DNS: `trading-service.candle.svc.cluster.local:9090`. 앱은 **평문처럼** 호출(사이드카가 mTLS).
- **클라이언트 사이드 LB 직접 구현 금지** — Envoy가 요청 단위 분산(L7). 단일 채널을 재사용해도 분산됨.
- 모든 쓰기 RPC는 `CommandMetadata.idempotency_key` + gRPC metadata `x-idempotency-key` 동일 값 전달(proto 규약).

## 9. 관측 (로그/메트릭/트레이스)

- **로그**: stdout으로(파일 X). Loki가 수집. JSON 구조화 로그 권장.
- **메트릭**: 앱은 `/actuator/prometheus` 노출 필수(`micrometer-registry-prometheus` 의존성 + `management.endpoints.web.exposure.include`에 prometheus 포함). bff(Node)는 `/metrics`.
  - 수집은 자동: services 차트가 **ServiceMonitor** 생성 → Istio **prometheus merge**가 앱+Envoy 메트릭을 사이드카 `:15020/stats/prometheus`에 병합 → kube-prometheus-stack이 거기서 스크랩(STRICT mTLS 무관).
  - 앱이 메트릭 경로/포트만 맞추면 됨(차트가 `prometheus.io/{scrape,port,path}` 애너테이션 자동 부여). gRPC 전용 서버 메트릭도 micrometer로 `/actuator/prometheus`에 실어야 보인다.
- **트레이스**: Istio가 ingress/egress 스팬을 만들지만, **앱이 수신 trace 헤더(`traceparent`, `x-b3-*`)를 하위 호출에 전파**해야 Jaeger에서 끊기지 않는다.

## 10. 배치(Spring Batch) — native sidecar (적용됨)

batch가 소유 서비스 gRPC를 호출하므로 **메시(mTLS)에 합류**해야 한다. 일반 사이드카는 Job이 끝나도
사이드카가 살아 있어 Job이 완료되지 않는 문제가 있어, **Istio native sidecar**(init container, `restartPolicy: Always`)를 쓴다.

- istiod: `pilot.env.ENABLE_NATIVE_SIDECARS=true` (platform/applications/istio.yaml) — k8s ≥1.28(우리 1.30)·Istio ≥1.20(우리 1.23) 충족.
- batch CronJob: `sidecar.istio.io/inject: "true"` (services/batch-chart). Job의 main 컨테이너가 끝나면 kubelet이 native sidecar를 자동 종료 → **Job 정상 완료 + gRPC mTLS 유지**.
- 메시 기동 순서: `holdApplicationUntilProxyStarts: true`(meshConfig 전역) — 배치 시작 직후 gRPC 호출이 Envoy 준비 전에 나가는 것 방지.

> 결과: batch는 소유 서비스 gRPC(STRICT mTLS)·Kafka(MSK IAM)·자체 JobRepository DB 모두 정상 사용.
> 주의: native sidecar는 Istio가 정상 주입되는 k8s/Istio 버전에서만 동작(버전 다운그레이드 시 재검토).

## 11. 인증 헤더 (X-Account-Id) — 게이트웨이가 주입

- **JWT 검증·헤더 주입은 API Gateway(edge 모듈)에서** 한다:
  - 검증: `aws_apigatewayv2_authorizer`(JWT, issuer/audience) — `edge_jwt_issuer` 설정 시 활성.
  - 주입: integration `request_parameters`의 `overwrite:header.X-Account-Id ← $context.authorizer.claims.<claim>`. `overwrite`라 **클라이언트가 보낸 X-Account-Id는 덮어써져 위조 불가**. 클레임명은 `edge_jwt_header_claims`(기본 `sub`)로 실제 Auth 토큰에 맞게 설정.
- **서비스/BFF는 `X-Account-Id`를 신뢰**하고 사용(자체 JWT 재검증 불필요 — 단, public 인터넷에서 직접 X-Account-Id를 못 넣게 메시 ingress NLB는 internal이라 APIGW 경유만 가능).
- **`/auth/*`는 public**(authorizer 없음) → 이 라우트엔 X-Account-Id 없음(로그인 전).
- ⚠️ **WebSocket은 APIGW를 안 거친다**(ws.<domain> → 인터넷 ALB → bff). 따라서 **WS 연결의 JWT 검증은 bff가 직접** 해야 한다(쿼리파라미터/Sec-WebSocket-Protocol의 토큰 검증). WS에는 X-Account-Id가 주입되지 않음.

## 12. 멱등성 (IDEMPOTENCY.md 연계)

- 쓰기 명령은 idempotency key 기반으로 재시도 안전하게. 만료 키 정리는 batch(`idempotency.cleanup.v1`).
- consumer/배치/gRPC 재시도 모두 같은 키로 중복 효과가 없어야 한다.

---

## 빠른 체크리스트 (서비스 신규 추가 시)
- [ ] `SERVER_PORT`/`GRPC_SERVER_PORT` env 반영, 8080/9090 바인딩
- [ ] `${host}/${port}/${dbname}/${username}/${password}` 로 datasource 구성
- [ ] actuator health + (gRPC면) `grpc.health.v1.Health` 등록
- [ ] graceful shutdown + holdApplicationUntilProxyStarts
- [ ] outbox 테이블 스키마/트랜잭션 + debezium SELECT 권한
- [ ] Kafka는 MSK IAM, 직접 발행 금지(outbox)
- [ ] AWS는 IRSA(키 하드코딩 금지)
- [ ] 로그 stdout, /actuator/prometheus, trace 헤더 전파
- [ ] k8s Service/SA 이름 = `<module>`(예: `trading-service`)와 일치
