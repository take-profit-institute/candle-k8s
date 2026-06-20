# candle-k8s (GitOps)

Candle 플랫폼의 Kubernetes 매니페스트. **ArgoCD app-of-apps** 패턴으로 동기화한다.
인프라(EKS/RDS/MSK/Redis/Edge)는 별도 `infrastructure/`(Terraform)가 담당하고,
이 repo는 **그 위에 올라가는 모든 워크로드**를 담당한다.

## Terraform ↔ candle-k8s 경계

| Terraform (infrastructure) | candle-k8s (this repo, ArgoCD) |
|---|---|
| EKS, 노드그룹, OIDC, IRSA roles | Istio, Strimzi+Debezium, 관측 스택 |
| ArgoCD / ESO / LB Controller 설치(부트스트랩) | TimescaleDB StatefulSet, 마이크로서비스 10종 |
| RDS/MSK/Redis, Secrets Manager secret | ExternalSecret(secret 동기화), Istio ingress NLB |
| CloudFront/WAF/APIGW/Route53 | KafkaConnect/Connector(outbox 라우팅) |

> Terraform이 ArgoCD를 설치한 뒤, `bootstrap/<env>.yaml`(app-of-apps)을 해당 클러스터 ArgoCD에 한 번 적용하면 나머지는 자동 동기화된다. (ArgoCD는 **클러스터별**로 존재 — dev/prod 각각)

## 구조

```
candle-k8s/
├── projects/candle.yaml          # ArgoCD AppProject
├── bootstrap/{dev,prod}.yaml      # app-of-apps 루트 (env별 1회 적용)
├── platform/
│   ├── applications/             # child ArgoCD Applications (root가 include glob로 선택)
│   │   ├── istio.yaml            # base · istiod · ingress-gateway(내부 NLB)
│   │   ├── strimzi.yaml          # Kafka Connect operator
│   │   ├── observability.yaml    # kube-prometheus-stack · loki · jaeger
│   │   ├── platform-config-{dev,prod}.yaml  # 직접 작성 매니페스트(overlays/<env>)
│   │   └── services-{dev,prod}.yaml          # ApplicationSet — 서비스 10종
│   └── manifests/
│       ├── base/                 # storageclass, secretstore, peerauth(mTLS),
│       │                         # istio gateway, kafka connect/connector, timescaledb
│       └── overlays/{dev,prod}/
└── services/
    └── chart/                    # 범용 마이크로서비스 Helm 차트
```

## 리버스 프록시 & TLS — 어디서?

| 계층 | 리버스 프록시 | TLS 설정 위치 |
|---|---|---|
| 인터넷 → 엣지 | **CloudFront** (CDN/엣지) | **Terraform** `modules/edge` — ACM(us-east-1) 인증서, `redirect-to-https` |
| CloudFront → APIGW | — | AWS 관리형(execute-api), 설정 불필요 |
| APIGW (라우팅/JWT) | **API Gateway** (관리형 프록시) | AWS 관리형 |
| APIGW → NLB → ingress | NLB(L4) | VPC 내부 **HTTP 80**(평문) — VPC/SG로 격리. 필요 시 NLB TLS 리스너 추가 |
| 메시 진입 | **Istio ingress gateway(Envoy)** | `platform/manifests/base/istio-gateway.yaml` (현재 HTTP; mesh 내부는 아래 mTLS) |
| 서비스 ↔ 서비스 | **Envoy 사이드카** | **candle-k8s** `peer-authentication.yaml` — **east-west mTLS(STRICT)** |

요약: **별도 nginx 리버스 프록시는 없다.** 엣지 TLS는 Terraform(ACM/CloudFront), 서비스 간 암호화(mTLS)는 candle-k8s(Istio PeerAuthentication)에서 한다. VPC 내부 APIGW→메시 구간은 기본 평문이며 VPC 격리에 의존(원하면 NLB TLS 리스너로 종단간 암호화 가능).

## 관측 스택 (이 repo가 관리)

`platform/applications/observability.yaml`에서 Application으로 설치:
- **kube-prometheus-stack** (Prometheus + Grafana + Alertmanager) — MSK/노드/Istio 메트릭
- **Loki** (+ promtail) — 로그
- **Jaeger** — 분산 트레이싱 (Istio가 trace 전파)

Terraform은 MSK `open_monitoring`(JMX/node exporter)만 켜두었고, 수집/시각화는 여기서.

## 적용 (클러스터별 1회)

```bash
aws eks update-kubeconfig --name candle-dev --region ap-northeast-2
kubectl apply -f projects/candle.yaml
kubectl apply -f bootstrap/dev.yaml      # 이후 ArgoCD가 전부 동기화
```

## Terraform 출력과 맞춰야 하는 값 (placeholder 치환)

| 위치 | placeholder | 출처 |
|---|---|---|
| 서비스 SA 애너테이션 | `<ACCOUNT_ID>` | IRSA role ARN (`terraform output irsa_app_role_arns`) |
| ClusterSecretStore | region/role | `external_secrets_role_arn` |
| Istio ingress NLB | `<VPC_LINK_SG>` | `terraform output edge_vpc_link_security_group_id` |
| KafkaConnect | MSK bootstrap | `terraform output msk_bootstrap_brokers_iam` |
| WS Ingress(ws-ingress.yaml) | (치환 불필요) | host는 overlay에서 env별 설정(dev/prod). ACM은 **host 매칭으로 LB Controller가 자동탐색** — ARN 하드코딩 안 함 |

> NLB 생성 후: 그 리스너 ARN을 Terraform `edge_mesh_nlb_listener_arn`에 주입해야 APIGW→메시 라우트가 연결된다(양방향 핸드셰이크).
