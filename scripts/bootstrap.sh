#!/usr/bin/env bash
# bootstrap.sh — 키트 의존성(gh, lefthook) 일괄 설치 + lefthook 훅 설치
#
# Usage: ./scripts/bootstrap.sh [--yes]
#
# 1회성 설정 스크립트. 환경(OS + 패키지 매니저)을 감지하고
# 누락된 의존성을 검출해 사용자 확인을 받은 뒤 설치한다.
#
#   --yes : 모든 확인 프롬프트를 자동 승인 (CI/비대화형 환경용)

set -euo pipefail

ASSUME_YES=0

# 결과 상태 (print_summary가 사용)
#   already             — 이미 설치됨
#   installed           — 이번 실행에서 설치 성공
#   installed-no-path   — 설치는 했으나 현재 셸 PATH에서 인식 안 됨
#   declined            — 사용자가 설치를 거절
#   manual              — 자동 설치 매트릭스에 없어 URL 안내만 함
#   missing             — 검사 안 함 (예외 케이스)
STATUS_GH="missing"
STATUS_LEFTHOOK="missing"
STATUS_HOOKS="missing"
STATUS_ALIASES="missing"
STATUS_GITATTRIBUTES="missing"

# Git alias 이름 → 실행 명령 매핑 (name=command)
# 모두 `!bash ./scripts/*.sh` 형태로 repo top level 기준 상대 경로 사용.
GIT_ALIASES=(
  "nb=!bash ./scripts/new-branch.sh"
  "fb=!bash ./scripts/finish-branch.sh"
  "cleanup=!bash ./scripts/cleanup-merged.sh"
  "bootstrap=!bash ./scripts/bootstrap.sh"
)

# ----------------------------------------------------------------------------
# 환경 감지
# ----------------------------------------------------------------------------

detect_os() {
  case "$(uname -s)" in
    Darwin*) echo "macos" ;;
    Linux*)
      if grep -qi microsoft /proc/version 2>/dev/null; then
        echo "wsl"
      else
        echo "linux"
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    *) echo "unknown" ;;
  esac
}

detect_pm() {
  local os="$1"
  case "$os" in
    macos)
      command -v brew >/dev/null 2>&1 && { echo "brew"; return; }
      ;;
    linux|wsl)
      command -v brew    >/dev/null 2>&1 && { echo "brew";   return; }
      command -v apt-get >/dev/null 2>&1 && { echo "apt";    return; }
      command -v dnf     >/dev/null 2>&1 && { echo "dnf";    return; }
      command -v pacman  >/dev/null 2>&1 && { echo "pacman"; return; }
      ;;
    windows)
      command -v winget     >/dev/null 2>&1 && { echo "winget"; return; }
      command -v winget.exe >/dev/null 2>&1 && { echo "winget"; return; }
      command -v scoop      >/dev/null 2>&1 && { echo "scoop";  return; }
      ;;
  esac
  echo "unknown"
}

# ----------------------------------------------------------------------------
# 설치 명령 매트릭스
# ----------------------------------------------------------------------------

install_cmd() {
  local tool="$1" pm="$2"
  # winget: 패키지 ID는 대소문자 정확히 일치해야 한다 (-e 플래그 사용 시).
  # --accept-*-agreements 두 플래그는 첫 사용 시 약관 수락 프롬프트로 비대화형 실패하는 것을 방지한다.
  local winget_flags="-e --accept-source-agreements --accept-package-agreements"
  case "${tool}:${pm}" in
    gh:brew)             echo "brew install gh" ;;
    gh:winget)           echo "winget install --id GitHub.cli ${winget_flags}" ;;
    gh:scoop)            echo "scoop install gh" ;;
    gh:dnf)              echo "sudo dnf install -y gh" ;;
    gh:pacman)           echo "sudo pacman -S --noconfirm github-cli" ;;
    lefthook:brew)       echo "brew install lefthook" ;;
    lefthook:winget)     echo "winget install --id evilmartians.lefthook ${winget_flags}" ;;
    lefthook:scoop)      echo "scoop install lefthook" ;;
    *)                   echo "" ;;
  esac
}

manual_url() {
  local tool="$1"
  case "$tool" in
    gh)       echo "https://cli.github.com/" ;;
    lefthook) echo "https://github.com/evilmartians/lefthook/blob/master/docs/install.md" ;;
    *)        echo "" ;;
  esac
}

# ----------------------------------------------------------------------------
# 사용자 확인
# ----------------------------------------------------------------------------

confirm() {
  local prompt="$1"
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    echo "   ${prompt} [y/N]: y (--yes)"
    return 0
  fi
  local ans=""
  read -r -p "   ${prompt} [y/N]: " ans
  [[ "$ans" =~ ^[yY]$ ]]
}

# ----------------------------------------------------------------------------
# 단일 도구 설치 흐름
# ----------------------------------------------------------------------------

ensure_tool() {
  local tool="$1" pm="$2"
  local status_var="STATUS_$(echo "$tool" | tr '[:lower:]' '[:upper:]')"

  if command -v "$tool" >/dev/null 2>&1; then
    printf -v "$status_var" "%s" "already"
    echo "✅ ${tool}: 이미 설치됨"
    return 0
  fi

  echo "❌ ${tool}: 설치되어 있지 않습니다."

  local cmd
  cmd="$(install_cmd "$tool" "$pm")"

  if [[ -z "$cmd" ]]; then
    printf -v "$status_var" "%s" "manual"
    local url
    url="$(manual_url "$tool")"
    echo "   감지된 환경(PM=${pm})에 자동 설치 명령이 없습니다."
    echo "   수동 설치 가이드: ${url}"
    return 1
  fi

  echo "   설치 명령: ${cmd}"
  if [[ "$cmd" == sudo* ]]; then
    echo "   ⚠️  sudo 비밀번호 입력이 필요할 수 있습니다."
  fi

  if ! confirm "이 명령을 실행하시겠습니까?"; then
    printf -v "$status_var" "%s" "declined"
    echo "   취소됨."
    return 1
  fi

  # 설치 실행 + exit code 캡처 (set -e 우회)
  local install_rc=0
  eval "$cmd" || install_rc=$?

  # 1) 명령 자체가 실패한 경우 — PATH 문제와 명확히 구분
  if [[ "$install_rc" -ne 0 ]]; then
    printf -v "$status_var" "%s" "failed"
    echo "   ❌ 설치 명령이 실패했습니다 (exit ${install_rc})"
    echo "      위 패키지 매니저 출력에서 원인을 확인하세요."
    echo "      수동 설치 가이드: $(manual_url "$tool")"
    return 1
  fi

  # 2) 명령은 성공했지만 현재 셸에서 도구를 못 찾는 경우 — PATH 미갱신
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf -v "$status_var" "%s" "installed-no-path"
    echo "⚠️  설치는 성공했지만 현재 셸에서 '${tool}'을 찾지 못합니다."
    echo "   새 터미널을 열거나 셸을 재시작한 뒤 다시 실행하세요."
    return 1
  fi

  # 3) 명령 성공 + PATH에서 인식 — 완전 성공
  printf -v "$status_var" "%s" "installed"
  echo "✅ ${tool} 설치 완료"
  return 0
}

# ----------------------------------------------------------------------------
# lefthook 훅 설치 (.git/hooks/*)
# ----------------------------------------------------------------------------

ensure_lefthook_hooks() {
  if ! command -v lefthook >/dev/null 2>&1; then
    STATUS_HOOKS="skipped-no-lefthook"
    echo "⚠️  lefthook이 없어서 훅 설치를 건너뜁니다."
    return 1
  fi

  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    STATUS_HOOKS="skipped-no-git"
    echo "⚠️  현재 디렉터리가 git repo가 아니라서 훅을 설치하지 않습니다."
    return 1
  fi

  echo "🔍 lefthook 훅 설치 중..."
  if lefthook install >/dev/null; then
    STATUS_HOOKS="installed"
    echo "✅ .git/hooks/ 에 훅 설치 완료"
    return 0
  fi

  STATUS_HOOKS="failed"
  echo "❌ lefthook install 실패"
  return 1
}

# ----------------------------------------------------------------------------
# .gitattributes 점검 (CRLF/LF 유령 modified 방지)
# ----------------------------------------------------------------------------
# Windows의 core.autocrlf=true 와 .gitattributes 부재가 결합하면
# 키트의 .sh/.yml 파일이 수정한 적 없는데도 git status에 'M'으로 뜨는
# 유령 modified 현상이 발생한다 (SETUP_GUIDE.md 트러블슈팅 참고).
# 강제 차단이 아닌 advisory warning — 종료 코드에 영향 없음.

check_gitattributes() {
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    STATUS_GITATTRIBUTES="skipped-no-git"
    return 0
  fi

  echo "🔍 .gitattributes 점검 중..."

  if [[ ! -f .gitattributes ]]; then
    STATUS_GITATTRIBUTES="not-found"
    echo "⚠️  .gitattributes 파일이 없습니다."
    echo "   Windows 팀원에게 .yml/.sh 파일이 '유령 modified'로 뜨는 문제가 발생할 수 있습니다."
    echo "   해결: 키트의 .gitattributes를 복사하세요 (SETUP_GUIDE.md Phase 2-1)."
    return 0
  fi

  # 핵심 규칙: *.sh, *.yml, *.yaml, *.bash 에 eol=lf 가 모두 있어야 함.
  # eol=lf 가 적용된 패턴(첫 칼럼)을 모아 fixed-string 정확 일치로 검증한다.
  # (regex 메타문자 escape 이슈를 피하기 위함)
  local lf_patterns
  lf_patterns=$(grep -E 'eol=lf' .gitattributes 2>/dev/null | awk '{print $1}' || true)

  local missing_rules=()
  local pattern
  for pattern in '*.sh' '*.yml' '*.yaml' '*.bash'; do
    if ! printf '%s\n' "$lf_patterns" | grep -Fxq -- "$pattern"; then
      missing_rules+=("$pattern")
    fi
  done

  if [[ ${#missing_rules[@]} -gt 0 ]]; then
    STATUS_GITATTRIBUTES="incomplete"
    echo "⚠️  .gitattributes에 다음 규칙이 누락되었습니다: ${missing_rules[*]}"
    echo "   각 패턴에 'eol=lf'가 적용되어야 Windows에서 유령 modified가 방지됩니다."
    echo "   참고: SETUP_GUIDE.md 트러블슈팅 'CRLF 관련 에러'"
    return 0
  fi

  STATUS_GITATTRIBUTES="ok"
  echo "✅ .gitattributes: 핵심 LF 규칙 OK"
  return 0
}

# ----------------------------------------------------------------------------
# Git aliases 설치 (.git/config 의 [alias] 섹션)
# ----------------------------------------------------------------------------

ensure_git_aliases() {
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    STATUS_ALIASES="skipped-no-git"
    echo "⚠️  현재 디렉터리가 git repo가 아니라서 alias를 설치하지 않습니다."
    return 1
  fi

  echo "🔍 Git aliases 설치 중..."
  local installed=0
  local entry name cmd current
  for entry in "${GIT_ALIASES[@]}"; do
    name="${entry%%=*}"
    cmd="${entry#*=}"
    current=$(git config --local --get "alias.$name" 2>/dev/null || true)
    if [[ "$current" == "$cmd" ]]; then
      echo "   ✅ git $name: 이미 설치됨"
    else
      git config --local "alias.$name" "$cmd"
      echo "   ✅ git $name: 설치 완료"
      installed=$((installed + 1))
    fi
  done

  if [[ $installed -gt 0 ]]; then
    STATUS_ALIASES="installed"
  else
    STATUS_ALIASES="already"
  fi
  return 0
}

# ----------------------------------------------------------------------------
# 결과 요약
# ----------------------------------------------------------------------------

format_status() {
  case "$1" in
    already)            echo "✅ 이미 설치됨" ;;
    installed)          echo "✅ 설치 완료" ;;
    installed-no-path)  echo "⚠️  설치 후 PATH 갱신 필요 (셸 재시작)" ;;
    declined)           echo "❌ 사용자 거절" ;;
    manual)             echo "❌ 수동 설치 필요 (URL 안내됨)" ;;
    skipped-no-lefthook) echo "⏭  lefthook 미설치로 건너뜀" ;;
    skipped-no-git)     echo "⏭  git repo가 아니라서 건너뜀" ;;
    failed)             echo "❌ 실패" ;;
    ok)                 echo "✅ OK" ;;
    incomplete)         echo "⚠️  핵심 규칙 누락 (위 경고 참고)" ;;
    not-found)          echo "⚠️  파일 없음 (위 경고 참고)" ;;
    missing)            echo "—" ;;
    *)                  echo "$1" ;;
  esac
}

print_summary() {
  echo ""
  echo "============================================================"
  echo "📋 부트스트랩 결과"
  echo "============================================================"
  printf "  %-14s %s\n" "gh"             "$(format_status "$STATUS_GH")"
  printf "  %-14s %s\n" "lefthook"       "$(format_status "$STATUS_LEFTHOOK")"
  printf "  %-14s %s\n" "hooks"          "$(format_status "$STATUS_HOOKS")"
  printf "  %-14s %s\n" "aliases"        "$(format_status "$STATUS_ALIASES")"
  printf "  %-14s %s\n" "gitattributes"  "$(format_status "$STATUS_GITATTRIBUTES")"
  echo "============================================================"
  echo ""

  # 다음 단계 안내
  local need_restart=0
  [[ "$STATUS_GH" == "installed-no-path" || "$STATUS_LEFTHOOK" == "installed-no-path" ]] && need_restart=1

  local has_declined=0
  [[ "$STATUS_GH" == "declined" || "$STATUS_LEFTHOOK" == "declined" ]] && has_declined=1

  local has_manual=0
  [[ "$STATUS_GH" == "manual" || "$STATUS_LEFTHOOK" == "manual" ]] && has_manual=1

  local has_failed=0
  [[ "$STATUS_GH" == "failed" || "$STATUS_LEFTHOOK" == "failed" ]] && has_failed=1

  echo "다음 단계:"
  if [[ "$need_restart" -eq 1 ]]; then
    echo "  - 새 터미널을 열고 PATH가 갱신됐는지 확인:"
    [[ "$STATUS_GH" == "installed-no-path" ]]       && echo "      gh --version"
    [[ "$STATUS_LEFTHOOK" == "installed-no-path" ]] && echo "      lefthook version"
    echo "  - 그 후 ./scripts/bootstrap.sh 스크립트를 한 번 더 실행하면 lefthook 훅까지 마무리됩니다."
  fi
  if [[ "$has_failed" -eq 1 ]]; then
    echo "  - 설치 명령이 실패한 도구가 있습니다. 위 패키지 매니저 출력을 확인하고,"
    echo "    가이드대로 수동 설치한 뒤 ./scripts/bootstrap.sh 를 다시 실행하세요."
  fi
  if [[ "$has_declined" -eq 1 ]]; then
    echo "  - 거절한 도구는 직접 설치한 뒤 ./scripts/bootstrap.sh 를 다시 실행하세요."
  fi
  if [[ "$has_manual" -eq 1 ]]; then
    echo "  - URL 안내를 받은 도구는 가이드대로 수동 설치 후 ./scripts/bootstrap.sh 를 다시 실행하세요."
  fi
  if [[ "$STATUS_HOOKS" == "installed" ]]; then
    echo "  - 작업 시작: git nb <type> <name>   (또는 ./scripts/new-branch.sh ...)"
  fi
  if [[ "$STATUS_ALIASES" == "installed" || "$STATUS_ALIASES" == "already" ]]; then
    echo "  - 사용 가능한 Git alias:"
    echo "      git nb <type> <name>   — 새 작업 브랜치"
    echo "      git fb                 — PR 생성"
    echo "      git cleanup            — 머지된 브랜치 정리"
    echo "      git bootstrap          — 이 스크립트 재실행"
  fi
  echo ""
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------

print_usage() {
  echo "Usage: $0 [--yes]"
  echo "  --yes, -y : 모든 확인 프롬프트를 자동 승인 (CI/비대화형 환경용)"
}

parse_args() {
  case "${1:-}" in
    "")          ;;
    --yes|-y)    ASSUME_YES=1 ;;
    -h|--help)   print_usage; exit 0 ;;
    *)
      echo "❌ 알 수 없는 인자: $1"
      print_usage
      exit 1
      ;;
  esac
}

main() {
  parse_args "$@"

  echo "🔍 환경 감지 중..."
  local os pm
  os="$(detect_os)"
  pm="$(detect_pm "$os")"
  echo "   OS: ${os}"
  echo "   PM: ${pm}"
  echo ""

  echo "🔍 의존성 확인 중..."
  ensure_tool "gh"       "$pm" || true
  ensure_tool "lefthook" "$pm" || true
  echo ""

  ensure_lefthook_hooks || true
  echo ""

  check_gitattributes || true
  echo ""

  ensure_git_aliases || true

  print_summary

  # 종료 코드 결정: 모든 필수 구성요소가 OK일 때만 0
  local ok=1
  case "$STATUS_GH"       in already|installed) ;; *) ok=0 ;; esac
  case "$STATUS_LEFTHOOK" in already|installed) ;; *) ok=0 ;; esac
  case "$STATUS_HOOKS"    in installed)         ;; *) ok=0 ;; esac
  case "$STATUS_ALIASES"  in already|installed) ;; *) ok=0 ;; esac
  [[ "$ok" -eq 1 ]] && exit 0 || exit 1
}

main "$@"
