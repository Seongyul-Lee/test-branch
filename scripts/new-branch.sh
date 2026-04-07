#!/usr/bin/env bash
# new-branch.sh — main을 최신화하고 <type>/<name> 형식의 새 작업 브랜치 생성
#
# Usage:
#   ./scripts/new-branch.sh                    # 인터랙티브 모드 (TTY 필요)
#   ./scripts/new-branch.sh <type>             # type만 지정, name은 프롬프트로 입력
#   ./scripts/new-branch.sh <type> <name>      # 인자 모드 (CI/스크립트 호환)
#
#   type: feat | fix | refactor | docs | research | data | chore
#   name: kebab-case (대소문자/공백/언더스코어는 자동 변환)

set -euo pipefail

ALLOWED_TYPES=(feat fix refactor docs research data chore)

print_usage() {
  echo "Usage: $0 [<type>] [<name>]"
  echo "  인자가 빠지면 인터랙티브 모드로 진입합니다 (TTY 필요)."
  echo "  type: feat | fix | refactor | docs | research | data | chore"
  echo "  name: kebab-case (자동 변환)"
}

TYPE="${1:-}"
NAME="${2:-}"

# 인터랙티브 type 선택 — 방향키 ↑↓ 이동, Enter 확정
select_type_interactive() {
  if [[ ! -t 0 || ! -t 2 ]]; then
    echo "❌ 인터랙티브 모드는 TTY가 필요합니다." >&2
    echo "   인자를 직접 지정하세요: $0 <type> <name>" >&2
    exit 1
  fi

  local n=${#ALLOWED_TYPES[@]}
  local selected=0
  local key
  local first=1
  local i

  # 커서 숨김 + 종료/인터럽트 시 복구
  printf '\033[?25l' >&2
  trap 'printf "\033[?25h" >&2' EXIT
  trap 'printf "\033[?25h" >&2; exit 130' INT TERM

  while true; do
    if [[ $first -eq 0 ]]; then
      # 이전 메뉴 지우기 (헤더 1줄 + 항목 n줄)
      for ((i = 0; i < n + 1; i++)); do
        printf '\033[1A\033[2K' >&2
      done
    fi
    first=0

    printf '브랜치 type을 선택하세요 (↑↓ 이동, Enter 확정):\n' >&2
    for i in "${!ALLOWED_TYPES[@]}"; do
      if [[ $i -eq $selected ]]; then
        printf '  \033[1;36m▶ %s\033[0m\n' "${ALLOWED_TYPES[$i]}" >&2
      else
        printf '    %s\n' "${ALLOWED_TYPES[$i]}" >&2
      fi
    done

    # 한 글자 읽기. Enter는 빈 문자열로 도착.
    IFS= read -rsn1 key || true
    if [[ -z $key ]]; then
      break
    fi
    if [[ $key == $'\x1b' ]]; then
      # ESC 시퀀스: 두 글자 더 읽기 (timeout으로 단독 ESC 흡수)
      local rest=""
      read -rsn2 -t 0.05 rest || true
      case "$rest" in
        '[A' | 'OA') ((selected = (selected - 1 + n) % n)) ;;
        '[B' | 'OB') ((selected = (selected + 1) % n)) ;;
      esac
    fi
  done

  printf '\033[?25h' >&2
  trap - EXIT INT TERM

  TYPE="${ALLOWED_TYPES[$selected]}"
}

# type이 비어 있으면 인터랙티브 선택
if [[ -z "$TYPE" ]]; then
  select_type_interactive
fi

# type 검증
TYPE_VALID=0
for t in "${ALLOWED_TYPES[@]}"; do
  if [[ "$TYPE" == "$t" ]]; then
    TYPE_VALID=1
    break
  fi
done

if [[ $TYPE_VALID -eq 0 ]]; then
  echo "❌ type '$TYPE'은 허용되지 않습니다."
  echo "   허용: feat | fix | refactor | docs | research | data | chore"
  exit 1
fi

# name이 비어 있으면 프롬프트로 입력
if [[ -z "$NAME" ]]; then
  if [[ ! -t 0 ]]; then
    echo "❌ 인터랙티브 모드는 TTY가 필요합니다."
    echo "   인자를 직접 지정하세요: $0 <type> <name>"
    exit 1
  fi
  printf '브랜치 이름을 입력하세요: ' >&2
  IFS= read -r NAME
fi

# name을 kebab-case로 정규화: 소문자화 + 공백/언더스코어를 하이픈으로
NAME_NORMALIZED=$(echo "$NAME" \
  | tr '[:upper:]' '[:lower:]' \
  | tr ' _' '--' \
  | sed 's/--*/-/g' \
  | sed 's/^-//' \
  | sed 's/-$//')

if [[ -z "$NAME_NORMALIZED" ]]; then
  echo "❌ name을 빈 문자열로 지정할 수 없습니다."
  exit 1
fi

# 정규식 검증 (workflow 정규식과 동일)
if [[ ! "$NAME_NORMALIZED" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "❌ name '$NAME_NORMALIZED'이 규칙(소문자+숫자+하이픈)을 위반합니다."
  exit 1
fi

BRANCH="${TYPE}/${NAME_NORMALIZED}"

# main 최신화
echo "🔍 main 브랜치 최신화 중..."
git checkout main
git pull --ff-only

# 브랜치 존재 여부 확인
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  echo "❌ 브랜치 '$BRANCH'이 이미 존재합니다."
  echo "   이미 있는 브랜치로 전환: git checkout $BRANCH"
  exit 1
fi

# 새 브랜치 생성
git checkout -b "$BRANCH"

echo ""
echo "✅ 새 브랜치 생성: $BRANCH"
echo "   작업 후: ./scripts/finish-branch.sh"
