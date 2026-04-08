#!/usr/bin/env bash
# finish-branch.sh — 현재 브랜치를 push하고 GitHub PR을 자동 생성
#
# Usage: ./scripts/finish-branch.sh [--no-pr]
#   --no-pr   push만 수행하고 PR 생성은 건너뜀

set -euo pipefail

NO_PR=0
for arg in "$@"; do
  case "$arg" in
    --no-pr) NO_PR=1 ;;
    *)
      echo "❌ 알 수 없는 인자: $arg"
      echo "   Usage: $0 [--no-pr]"
      exit 1
      ;;
  esac
done

# gh CLI 설치 확인 (--no-pr 시 생략)
if [[ $NO_PR -eq 0 ]] && ! command -v gh >/dev/null 2>&1; then
  echo "❌ GitHub CLI(gh)가 설치되어 있지 않습니다."
  echo "   설치: https://cli.github.com/"
  echo ""
  echo "또는 수동 PR 생성:"
  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  echo "  git push -u origin $CURRENT_BRANCH"
  echo "  # 그 후 GitHub 웹 UI에서 PR 생성"
  exit 1
fi

# 현재 브랜치
BRANCH=$(git rev-parse --abbrev-ref HEAD)

if [[ "$BRANCH" == "main" ]]; then
  echo "❌ main 브랜치에서는 실행할 수 없습니다."
  echo "   먼저 작업 브랜치로 전환하세요: ./scripts/new-branch.sh <type> <name>"
  exit 1
fi

# 브랜치명 규칙 검증 (한 번 더 안전망)
PATTERN="^(feat|fix|refactor|docs|research|data|chore|remove)/[a-z0-9][a-z0-9-]*$"
if [[ ! "$BRANCH" =~ $PATTERN ]]; then
  echo "❌ 브랜치명 '$BRANCH'이 규칙을 위반합니다."
  echo "   올바른 형식: feat/my-feature, fix/bug-name, data/schema-v3, remove/unused-asset 등"
  echo "   브랜치 이름 변경: git branch -m <type>/<올바른-이름>"
  exit 1
fi

# 커밋되지 않은 변경 확인
if [[ -n "$(git status --porcelain)" ]]; then
  echo "⚠️  커밋되지 않은 변경 사항이 있습니다:"
  git status --short
  echo ""
  echo "   계속하려면 먼저 커밋하세요:"
  echo "   git add . && git commit -m \"<type>: ...\""
  exit 1
fi

# 커밋 1개 이상 있는지 확인
if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
  echo "❌ 아직 커밋이 없습니다. 먼저 커밋을 만드세요."
  exit 1
fi

# main과의 차이가 있는지
COMMITS_AHEAD=$(git rev-list --count main..HEAD 2>/dev/null || echo "0")
if [[ "$COMMITS_AHEAD" == "0" ]]; then
  echo "❌ main 대비 커밋이 없습니다. 먼저 작업을 커밋하세요."
  exit 1
fi

# push
echo "📤 원격에 push 중: $BRANCH"
git push -u origin "$BRANCH"

if [[ $NO_PR -eq 1 ]]; then
  echo ""
  echo "✅ push 완료 (--no-pr: PR 생성을 건너뛰었습니다)."
  echo "   나중에 PR을 만들려면: gh pr create --fill-first"
  exit 0
fi

# PR 생성
# --fill-first: 커밋이 여러 개일 때 첫 커밋 메시지를 PR 제목/본문으로 사용.
# (--fill은 multi-commit PR에서 브랜치명을 Conventional Commits가 아닌 형식으로
#  변환해 PR 제목 검증이 실패하는 버그가 있어 --fill-first로 통일한다.)
echo "📝 PR 생성 중..."
gh pr create --fill-first

echo ""
echo "✅ PR 생성 완료. 리뷰 후 GitHub UI에서 'Squash and merge' 버튼을 클릭하세요."
echo "   머지 후 로컬 정리: ./scripts/cleanup-merged.sh"
