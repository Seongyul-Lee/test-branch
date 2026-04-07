#!/usr/bin/env bash
# cleanup-merged.sh — 머지된 로컬 브랜치 + 원격에서 사라진 브랜치를 일괄 삭제
#
# Usage: ./scripts/cleanup-merged.sh
#
# 정리 대상은 세 가지 신호 중 하나라도 만족하는 로컬 브랜치:
#   1) git branch --merged main          — 일반 머지로 main에 흡수된 브랜치
#   2) git branch -vv 의 ': gone]' 표시   — 원격에서 사라진 추적 브랜치 (squash merge 대응)
#   3) GitHub PR이 MERGED 상태             — auto-delete 미동작 케이스 대응 (gh CLI 필요)
#
# 3번 검사는 gh CLI가 설치 + 인증되어 있을 때만 동작합니다.
# gh가 없거나 인증 안 되어 있으면 경고 후 1)+2)로만 동작합니다.

set -euo pipefail

PROTECTED_BRANCHES="main master develop"

# main 최신화
echo "🔍 main 브랜치 최신화 중..."
git checkout main
git pull --ff-only

echo "🔍 원격 추적 정보 정리 중 (git fetch -p)..."
git fetch -p

# 보호 브랜치 목록을 newline-separated로 (grep -F 입력용)
PROTECTED_LINES=$(echo "$PROTECTED_BRANCHES" | tr ' ' '\n')

# 1) 머지된 로컬 브랜치
MERGED=$(git branch --merged main \
  | sed 's/^[ *]*//' \
  | grep -v -x -F "$PROTECTED_LINES" \
  || true)

# 2) 원격에서 삭제된 브랜치를 추적하던 로컬 브랜치 (squash merge 대응)
GONE=$(git branch -vv \
  | awk '/: gone\]/{print $1}' \
  | grep -v -x -F "$PROTECTED_LINES" \
  || true)

# 3) GitHub PR이 MERGED 상태인 로컬 브랜치 (auto-delete 미동작 대응)
PR_MERGED=""
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  echo "🔍 GitHub PR 상태 확인 중 (gh)..."
  # 머지된 PR의 head ref 목록을 한 번의 API 호출로 가져옴
  MERGED_PR_HEADS=$(gh pr list --state merged --limit 200 \
    --json headRefName --jq '.[].headRefName' 2>/dev/null \
    | sort -u || true)

  if [[ -n "$MERGED_PR_HEADS" ]]; then
    LOCAL_BRANCHES=$(git for-each-ref --format='%(refname:short)' refs/heads/ \
      | grep -v -x -F "$PROTECTED_LINES" \
      | sort -u || true)

    if [[ -n "$LOCAL_BRANCHES" ]]; then
      # 로컬 브랜치 ∩ 머지된 PR head
      PR_MERGED=$(comm -12 \
        <(printf '%s\n' "$LOCAL_BRANCHES") \
        <(printf '%s\n' "$MERGED_PR_HEADS") || true)
    fi
  fi
else
  echo "⚠️  gh CLI 미설치 또는 미인증 — PR 상태 검사를 건너뜁니다."
  echo "   (gh CLI를 설치하면 auto-delete가 동작하지 않은 머지된 브랜치도 정리됩니다)"
fi

# 합치고 중복 제거
ALL_TO_DELETE=$(printf "%s\n%s\n%s\n" "$MERGED" "$GONE" "$PR_MERGED" | sort -u | sed '/^$/d')

if [[ -z "$ALL_TO_DELETE" ]]; then
  echo "✅ 정리할 머지된 브랜치가 없습니다."
  exit 0
fi

echo ""
echo "다음 브랜치들이 삭제됩니다:"
echo "$ALL_TO_DELETE" | sed 's/^/  /'
echo ""
read -r -p "진행하시겠습니까? [y/N]: " CONFIRM

if [[ ! "$CONFIRM" =~ ^[yY]$ ]]; then
  echo "취소되었습니다."
  exit 0
fi

echo ""
# 검사 종류별로 분기:
#   - MERGED:    -d 시도 후 실패 시 -D (안전 우선)
#   - PR_MERGED: 원격 브랜치도 함께 삭제(auto-delete 미동작 보정) + 로컬 -D
#   - GONE:      원격 추적이 이미 사라짐, -D 강제 삭제
while IFS= read -r BRANCH; do
  [[ -z "$BRANCH" ]] && continue

  if echo "$MERGED" | grep -qx "$BRANCH"; then
    if git branch -d "$BRANCH" 2>/dev/null; then
      echo "✅ $BRANCH 삭제 완료 (merged)"
    else
      git branch -D "$BRANCH"
      echo "✅ $BRANCH 삭제 완료 (forced)"
    fi
  elif echo "$PR_MERGED" | grep -qx "$BRANCH"; then
    # 원격 브랜치 정리 (실패해도 로컬 삭제는 계속 진행)
    if git push origin --delete "$BRANCH" >/dev/null 2>&1; then
      echo "   🌐 원격 브랜치도 삭제: origin/$BRANCH"
    fi
    git branch -D "$BRANCH"
    echo "✅ $BRANCH 삭제 완료 (PR merged on GitHub)"
  else
    git branch -D "$BRANCH"
    echo "✅ $BRANCH 삭제 완료 (gone from remote)"
  fi
done <<< "$ALL_TO_DELETE"

echo ""
echo "🎉 정리 완료."
