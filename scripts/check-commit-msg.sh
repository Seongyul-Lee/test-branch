#!/usr/bin/env bash
# check-commit-msg.sh — Conventional Commits 형식 검증
#
# Usage: bash scripts/check-commit-msg.sh <commit-msg-file>
#
# lefthook의 commit-msg 훅에서 호출된다. lefthook의 `run: |` 인라인
# multi-line 블록이 Git Bash on Windows 환경에서 큰따옴표/백슬래시를
# mangle하는 버그가 있어, 검증 로직을 이 파일로 추출해 우회한다.

set -euo pipefail

MSG_FILE="${1:-}"

if [[ -z "$MSG_FILE" || ! -f "$MSG_FILE" ]]; then
  echo "❌ 커밋 메시지 파일을 찾을 수 없습니다: ${MSG_FILE}"
  exit 1
fi

FIRST_LINE=$(head -n1 "$MSG_FILE")

# 빈 줄/주석은 통과 (git이 생성한 템플릿에서 실 내용 없이 커밋하는 케이스)
if [[ -z "$FIRST_LINE" ]]; then
  exit 0
fi

# merge/revert 커밋은 통과 (git이 자동 생성하는 영어 메시지)
case "$FIRST_LINE" in
  "Merge "*|"Revert "*) exit 0 ;;
esac

# Conventional Commits 형식 검증
PATTERN="^(feat|fix|refactor|docs|research|data|chore)(\(.+\))?!?: .+"
if ! echo "$FIRST_LINE" | grep -Eq "$PATTERN"; then
  echo "❌ 커밋 메시지가 Conventional Commits 형식이 아닙니다."
  echo "   첫 줄: $FIRST_LINE"
  echo ""
  echo "   올바른 예:"
  echo "     feat: add order router"
  echo "     fix(api): handle null response"
  echo "     data: add orderbook v3 migration"
  echo "     refactor!: breaking change"
  exit 1
fi
