#!/usr/bin/env bash
# check-branch.sh — pre-push 브랜치 검증 (2개 모드)
#
# Usage:
#   bash scripts/check-branch.sh no-main-push   # main/master 직접 push 차단
#   bash scripts/check-branch.sh name           # 브랜치명 정규식 검증
#
# lefthook의 pre-push 훅에서 호출된다. 인라인 multi-line 스크립트가
# Git Bash on Windows에서 lefthook에 의해 mangle되는 버그가 있어,
# 검증 로직을 이 파일로 추출해 우회한다.

set -euo pipefail

MODE="${1:-}"
BRANCH=$(git rev-parse --abbrev-ref HEAD)

case "$MODE" in
  no-main-push)
    if [[ "$BRANCH" == "main" || "$BRANCH" == "master" ]]; then
      echo "❌ $BRANCH 브랜치에 직접 push 금지."
      echo "   새 브랜치를 만드세요: ./scripts/new-branch.sh <type> <name>"
      exit 1
    fi
    ;;

  name)
    # main/master는 no-main-push에서 이미 차단되므로 여기서는 통과
    if [[ "$BRANCH" == "main" || "$BRANCH" == "master" ]]; then
      exit 0
    fi
    PATTERN="^(feat|fix|refactor|docs|research|data|chore|remove)/[a-z0-9][a-z0-9-]*$"
    if ! echo "$BRANCH" | grep -Eq "$PATTERN"; then
      echo "❌ 브랜치명 '$BRANCH'이 규칙을 위반합니다."
      echo "   올바른 형식: feat/my-feature, fix/bug-name, data/schema-v3 등"
      echo "   허용 type: feat | fix | refactor | docs | research | data | chore | remove"
      echo "   브랜치 이름 변경: git branch -m <type>/<올바른-이름>"
      exit 1
    fi
    ;;

  *)
    echo "❌ Usage: $0 {no-main-push|name}"
    exit 2
    ;;
esac
