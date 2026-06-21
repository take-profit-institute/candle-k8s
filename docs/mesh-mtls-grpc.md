# 메시 mTLS & gRPC 헬스체크

candle 서비스 간 동기 통신(gRPC)과 그 보안/헬스 구성에 대한 설명. 관련 매니페스트:

- `platform/manifests/base/peer-authentication.yaml` — PeerAuthentication (STRICT)
- `platform/manifests/base/destinationrule-mtls.yaml` — DestinationRule (ISTIO_MUTUAL + LB)
- `services/chart/templates/{service,deployment}.yaml` — gRPC 포트 + 헬스 프로브

---

## 1. mTLS — PeerAuthentication vs DestinationRule

두 리소스가 **짝**으로 동작한다. 하나는 "서버가 무엇을 받을지", 하나는 "클라이언트가 어떻게 보낼지".

| 리소스 | 주체 | 역할 |
|---|---|---|
| **PeerAuthentication** `mtls.mode: STRICT` | 수신(서버) 사이드카 | 평문 거부, **mTLS만 허용** |
| **DestinationRule** `tls.mode: ISTIO_MUTUAL` | 발신(클라이언트) 사이드카 | 사이드카 인증서로 **mTLS 발신** |

- Istio는 STRICT일 때 mesh 내부 목적지에 대해 클라이언트 mTLS를 자동 적용하지만, **DestinationRule을 명시**해두면 의도가 분명하고 동시에 **로드밸런싱·커넥션풀 정책**을 같은 곳에서 관리할 수 있다.
- 우리 설정: `candle` 네임스페이스 전체(`*.candle.svc.cluster.local`)에 ISTIO_MUTUAL.

```
client pod ──(Envoy, mTLS 발신: DestinationRule)──▶ (Envoy, mTLS 강제: PeerAuthentication) server pod
```

> 인증서·키 회전은 Istio가 자동(SDS). 앱 코드는 평문처럼 호출하고 사이드카가 암호화한다.

## 2. gRPC 부하분산 — 왜 DestinationRule이 중요한가

gRPC는 HTTP/2 **장수명 멀티플렉싱 커넥션**이라, L4(ClusterIP/kube-proxy) 분산은 **첫 연결 시 고른 파드 하나에 고정**된다 → 레플리카에 안 퍼짐.

해결: **L7(Envoy/Istio)가 요청(stream) 단위로 분산**. 그래서:
- Service 포트 이름을 **`grpc`** 로 지정(또는 `appProtocol: grpc`) → Envoy가 HTTP/2로 인식.
- DestinationRule `loadBalancer.simple: LEAST_REQUEST` → gRPC에 적합한 분산.
- `connectionPool.http.h2UpgradePolicy: UPGRADE` → HTTP/2 보장.

HPA로 파드가 늘어도 Envoy가 새 endpoint를 자동 반영한다.

## 3. gRPC 헬스체크

### 헬스 프로토콜
gRPC 표준 **Health Checking Protocol**(`grpc.health.v1.Health/Check`)을 서버가 구현해야 한다. Spring gRPC 스타터는 보통 이 서비스를 등록한다(미구현 시 아래 프로브가 실패하므로 반드시 활성화).

### 프로브 구성 (services 차트, `grpc.enabled: true`)
| 프로브 | 방식 | 이유 |
|---|---|---|
| `startupProbe` | **grpc** :9090 | gRPC 서버가 떠서 Health에 응답할 때까지 트래픽/타 프로브 보류 |
| `readinessProbe` | **grpc** :9090 | gRPC 서빙 가능할 때만 Endpoint에 편입 → LB 대상 |
| `livenessProbe` | **HTTP** `/actuator/health` :8080 | 프로세스 생존 확인 (아래 mTLS 이유로 HTTP 사용) |

비-gRPC(예: bff)는 readiness/liveness 모두 HTTP(`healthPath`, bff는 `/health`).

### ⚠️ Istio STRICT mTLS와 프로브의 상호작용 (중요)
- **HTTP 프로브**는 Istio가 자동으로 **rewrite**(pilot-agent :15021 경유)하여 사이드카 mTLS를 우회한다 → STRICT에서도 안전. 그래서 **liveness는 HTTP**로 둔다.
- **native gRPC/TCP 프로브는 rewrite되지 않는다.** kubelet의 평문 gRPC 프로브가 STRICT 사이드카에 막힐 수 있다. 다음 중 하나로 해결한다:
  1. **`grpc_health_probe` exec + localhost** (권장 fallback): 컨테이너에 바이너리를 넣고 `exec: ["/bin/grpc_health_probe","-addr=localhost:9090"]`. 루프백은 사이드카가 가로채지 않아 mTLS 무관.
  2. **actuator readiness 그룹에 gRPC 상태 포함**: readiness를 HTTP로 두되 Spring readiness group이 gRPC 서버 상태를 반영하게 구성. (HTTP라 rewrite 안전)
  3. 현재 매니페스트(native grpc 프로브)를 쓰되 **배포 후 프로브 성공 여부를 반드시 확인**. 실패 시 1) 또는 2)로 전환.

> 요약: liveness=HTTP(안전), readiness=gRPC(정확하지만 STRICT mTLS에서 검증 필요). 운영에서 막히면 `grpc_health_probe` exec(localhost) 로 바꾸는 것이 가장 견고하다.

## 4. 앱(서비스) 측 요구사항 체크리스트
- gRPC 서버 포트 = **9090** (`GRPC_SERVER_PORT` 주입). 차트 `grpc.port`와 일치.
- gRPC **Health Checking Protocol** 서비스 등록.
- actuator 노출(이미 `spring-boot-starter-actuator` 포함). liveness용 `/actuator/health`.
- gRPC 클라이언트(BFF 등)는 메시 DNS(`<svc>.candle.svc:9090`)로 호출 — 클라이언트 측 LB 직접 구현 불필요(Envoy가 처리).
