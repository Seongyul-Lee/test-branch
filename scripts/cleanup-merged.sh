#!/usr/bin/env bash
# cleanup-merged.sh — 머지된 로컬 브랜치 + 원격에서 사라진 브랜치를 일괄 삭제
#
# Usage:
#   ./scripts/cleanup-merged.sh                       # 검출된 모든 머지된 브랜치 삭제
#   ./scripts/cleanup-merged.sh --exclude <pattern>   # 패턴 일치 브랜치는 제외 (반복 가능)
#   ./scripts/cleanup-merged.sh --exclude feat/keep --exclude 'wip-*'
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

# --exclude 패턴 누적 (bash glob 문법: *, ?, [abc] 지원)
EXCLUDE_PATTERNS=()

print_usage() {
  cat <<'USAGE'
Usage: ./scripts/cleanup-merged.sh [--exclude <pattern>]...

Options:
  --exclude <pattern>   삭제 대상에서 제외할 브랜치명 패턴.
                        bash glob(*, ?, [...])을 지원하며 여러 번 사용 가능.
                        예:
                          --exclude feat/keep-this        (정확 일치)
                          --exclude 'feat/wip-*'          (prefix 매칭)
                          --exclude 'data/*'              (data 브랜치 전부 제외)
  -h, --help            이 메시지를 표시하고 종료
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --exclude)
      if [[ -z "${2:-}" ]]; then
        echo "❌ --exclude는 패턴 인자가 필요합니다." >&2
        print_usage >&2
        exit 1
      fi
      EXCLUDE_PATTERNS+=("$2")
      shift 2
      ;;
    --exclude=*)
      EXCLUDE_PATTERNS+=("${1#*=}")
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      echo "❌ 알 수 없는 인자: $1" >&2
      print_usage >&2
      exit 1
      ;;
  esac
done

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

# --exclude 패턴 적용 (bash glob 매칭)
EXCLUDED_BRANCHES=""
if [[ ${#EXCLUDE_PATTERNS[@]} -gt 0 && -n "$ALL_TO_DELETE" ]]; then
  FILTERED=""
  while IFS= read -r b; do
    [[ -z "$b" ]] && continue
    matched=0
    for pat in "${EXCLUDE_PATTERNS[@]}"; do
      # bash 내장 glob 매칭 — $pat은 인용하지 않아야 패턴으로 해석됨
      if [[ "$b" == $pat ]]; then
        matched=1
        break
      fi
    done
    if [[ $matched -eq 1 ]]; then
      EXCLUDED_BRANCHES+="$b"$'\n'
    else
      FILTERED+="$b"$'\n'
    fi
  done <<< "$ALL_TO_DELETE"
  ALL_TO_DELETE=$(printf '%s' "$FILTERED" | sed '/^$/d')
fi

if [[ -z "$ALL_TO_DELETE" ]]; then
  if [[ -n "$EXCLUDED_BRANCHES" ]]; then
    echo "✅ --exclude로 모든 후보가 제외되어 삭제할 브랜치가 없습니다."
    echo "   제외됨:"
    printf '%s' "$EXCLUDED_BRANCHES" | sed '/^$/d' | sed 's/^/     ⏭  /'
  else
    echo "✅ 정리할 머지된 브랜치가 없습니다."
  fi
  exit 0
fi

# 각 브랜치의 검출 사유를 inline으로 표시 — 사용자가 y/N 결정 직전에
# "왜 이 브랜치가 검출됐는지" 즉시 파악할 수 있도록.
# 한 브랜치가 여러 신호에 매칭될 수 있으므로 우선순위를 정해 한 줄에
# 가장 구체적인 사유 하나만 표기 (실제 삭제 분기 로직과 동일 우선순위).
detect_reason() {
  local branch="$1"
  if echo "$MERGED" | grep -qx "$branch"; then
    echo "merged"
  elif echo "$PR_MERGED" | grep -qx "$branch"; then
    echo "PR merged on GitHub"
  else
    echo "gone from remote"
  fi
}

# 가장 긴 브랜치명 폭에 맞춰 컬럼 정렬
MAX_W=0
while IFS= read -r b; do
  [[ -z "$b" ]] && continue
  [[ ${#b} -gt $MAX_W ]] && MAX_W=${#b}
done <<< "$ALL_TO_DELETE"
COL_W=$((MAX_W + 4))

echo ""
echo "다음 브랜치들이 삭제됩니다:"
while IFS= read -r b; do
  [[ -z "$b" ]] && continue
  printf "  %-${COL_W}s(%s)\n" "$b" "$(detect_reason "$b")"
done <<< "$ALL_TO_DELETE"

if [[ -n "$EXCLUDED_BRANCHES" ]]; then
  echo ""
  echo "⏭  --exclude로 제외됨:"
  printf '%s' "$EXCLUDED_BRANCHES" | sed '/^$/d' | sed 's/^/     /'
fi

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
