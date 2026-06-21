#!/usr/bin/env bash
# candle-k8s 매니페스트의 placeholder를 실제 값으로 치환한다.
#   <ACCOUNT_ID>, <ECR>            : 계정/리전 기반(결정적)
#   <MSK_IAM_BOOTSTRAP>            : terraform output msk_bootstrap_brokers_iam
#   <DEBEZIUM_ROLE_ARN>            : terraform output irsa_debezium_role_arn
#
# 사용:
#   scripts/render-placeholders.sh [dev|prod]
# 환경변수(선택):
#   ACCOUNT_ID(기본 348062907700) REGION(기본 ap-northeast-2)
#   TF_DIR(기본 ../infrastructure/envs/<env>)  — terraform output 읽을 위치
#   MSK_BOOTSTRAP / DEBEZIUM_ROLE_ARN          — 직접 지정 시 terraform 미사용
#
# 주의: 파일을 in-place로 바꾼다. 치환된 값은 git에 commit해야 ArgoCD가 본다.
#       MSK/Debezium 값은 dev apply 이후에야 나오므로, apply 후 실행 권장.
set -euo pipefail

ENV="${1:-dev}"
ACCOUNT_ID="${ACCOUNT_ID:-348062907700}"
REGION="${REGION:-ap-northeast-2}"
ECR="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="${TF_DIR:-$ROOT/../infrastructure/envs/$ENV}"
TARGET_DIR="$ROOT/platform" # README/docs는 건드리지 않음

# terraform output에서 동적 값 보강(직접 지정 안 했고 terraform 가능할 때)
MSK_BOOTSTRAP="${MSK_BOOTSTRAP:-}"
DEBEZIUM_ROLE_ARN="${DEBEZIUM_ROLE_ARN:-}"
if command -v terraform >/dev/null 2>&1 && [ -d "$TF_DIR" ]; then
  [ -z "$MSK_BOOTSTRAP" ] && MSK_BOOTSTRAP="$(terraform -chdir="$TF_DIR" output -raw msk_bootstrap_brokers_iam 2>/dev/null || true)"
  [ -z "$DEBEZIUM_ROLE_ARN" ] && DEBEZIUM_ROLE_ARN="$(terraform -chdir="$TF_DIR" output -raw irsa_debezium_role_arn 2>/dev/null || true)"
fi

# GNU/BSD sed 호환 in-place
sed_i() { if sed --version >/dev/null 2>&1; then sed -i "$@"; else sed -i '' "$@"; fi; }

echo "ENV=$ENV  ACCOUNT_ID=$ACCOUNT_ID  REGION=$REGION"
echo "ECR=$ECR"
echo "MSK_BOOTSTRAP=${MSK_BOOTSTRAP:-<미해결: terraform output 필요>}"
echo "DEBEZIUM_ROLE_ARN=${DEBEZIUM_ROLE_ARN:-<미해결: terraform output 필요>}"
echo "---"

# 치환 대상 파일(placeholder 포함된 것만)
changed=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  sed_i "s|<ACCOUNT_ID>|${ACCOUNT_ID}|g; s|<ECR>|${ECR}|g" "$f"
  [ -n "$MSK_BOOTSTRAP" ] && sed_i "s|<MSK_IAM_BOOTSTRAP>|${MSK_BOOTSTRAP}|g" "$f"
  [ -n "$DEBEZIUM_ROLE_ARN" ] && sed_i "s|<DEBEZIUM_ROLE_ARN>|${DEBEZIUM_ROLE_ARN}|g" "$f"
  echo "rendered: ${f#$ROOT/}"
  changed=1
done < <(grep -rlE '<ACCOUNT_ID>|<ECR>|<MSK_IAM_BOOTSTRAP>|<DEBEZIUM_ROLE_ARN>' "$TARGET_DIR" 2>/dev/null || true)

[ "$changed" -eq 0 ] && echo "치환할 placeholder 없음(이미 렌더됨)."

# 남은 미해결 placeholder 경고
remaining="$(grep -rEo '<MSK_IAM_BOOTSTRAP>|<DEBEZIUM_ROLE_ARN>' "$TARGET_DIR" 2>/dev/null | sort -u || true)"
if [ -n "$remaining" ]; then
  echo ""
  echo "⚠️ 미해결(아직 placeholder): $remaining"
  echo "   → dev apply 후 'terraform output'으로 값이 나오면 다시 실행하거나"
  echo "     MSK_BOOTSTRAP=... DEBEZIUM_ROLE_ARN=... scripts/render-placeholders.sh $ENV"
fi
