#!/bin/bash
# WhaTap 설치확인서 자동 수집 스크립트

# set -e 미사용: grep 매치 실패 등 사소한 exit 1로 스크립트가 죽지 않도록 함
# (치명적 실패는 fail() 메시지로 표시하고 계속 진행 — JSON은 항상 출력)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"   # 출력 경로 폴백용 (기본은 실행 위치)

# awk/printf 의 %f 는 LC_NUMERIC 을 따른다. de_DE 등 소수점이 ','인 로케일에서는
# 따옴표 없는 JSON 숫자가 "daily_bytes": 1234,5 로 나와 파싱이 불가해진다.
# 숫자 포맷만 C 로 고정 (한글 메시지 출력용 LANG/LC_CTYPE 은 그대로 유지).
export LC_NUMERIC=C

# 구버전 curl은 --http1.1 옵션 미지원 → 지원할 때만 사용
_CURL_HTTP11=""
if curl --http1.1 -s -o /dev/null "file:///dev/null" 2>/dev/null; then
  _CURL_HTTP11="--http1.1"
fi

# ── 컬러 로그 헬퍼 ──
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✔${NC}  $1: ${GREEN}$2${NC}"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1: ${YELLOW}$2${NC}"; }
fail() { echo -e "  ${RED}✘${NC}  $1: ${RED}$2${NC}"; }
info() { echo -e "  ${CYAN}→${NC}  $1"; }
section() { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

# ── 출력 디렉터리: '실행한 위치'(현재 작업 디렉터리) ──────────────────────────
# 스크립트 파일이 어디에 있든 사용자가 실행한 자리에 JSON 을 떨군다.
#   예전엔 스크립트 파일 위치($SCRIPT_DIR) 기준이라, /opt/whatap 에 둔 스크립트를
#   하위 작업 디렉터리에서 ../collect.sh 로 실행하면 JSON 이 상위 디렉터리에 생겨
#   "내가 실행한 데는 없는데?" 가 됐다.
# 실제로 파일을 만들어 보고 판단한다 — root 는 읽기전용 마운트에서도 test -w 가
#   통과해 버려서, 권한 비트만 보면 쓰기 실패를 못 걸러낸다.
OUT_DIR="$PWD"
if ! ( : > "$OUT_DIR/.whatap_write_test" ) 2>/dev/null; then
  OUT_DIR="$SCRIPT_DIR"
  warn "출력 경로" "현재 디렉터리에 쓸 수 없어 스크립트 위치에 저장합니다: $OUT_DIR"
else
  rm -f "$OUT_DIR/.whatap_write_test" 2>/dev/null
fi
OUTPUT_JSON="$OUT_DIR/collected_data.json"

# ── 프롬프트 입력 편집: 한글이 글자 단위로 지워지게 ──────────────────────────
# read -rp 는 readline 을 쓰지 않아 터미널 드라이버가 '바이트' 단위로 지운다.
#   UTF-8 한글은 한 글자가 3바이트라 백스페이스 한 번에 1/3 만 사라지고 화면엔 깨진
#   잔여 바이트가 남는다 → 고객사명/담당자 입력에서 뭐가 지워졌는지 알 수 없게 된다.
#   read -e (readline) 로 받으면 글자 단위 삭제와 ←/→·Home/End 편집이 된다.
# 단 readline 은 로케일 문자셋으로 글자 경계를 잡는다. C/POSIX(US-ASCII) 로케일에선
#   8비트 입력을 \355 같은 이스케이프로 찍어 오히려 더 나빠지므로, 그럴 때만 시스템에
#   있는 UTF-8 로케일로 LC_CTYPE 을 올린다. 이미 UTF-8/EUC-KR 등 다바이트면 손대지 않는다
#   (EUC-KR 서버를 UTF-8 로 바꾸면 그쪽 입력이 깨진다).
_READ_E="-e"
case "$(locale charmap 2>/dev/null || echo '')" in
  UTF-8|utf8|EUC-KR|eucKR|EUCKR|CP949|UHC|*949*|BIG5|GB*|*JIS*) : ;;   # 이미 다바이트 인식
  *)
    _u=""
    for _c in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8 ko_KR.UTF-8 ko_KR.utf8; do
      if [ "$(LC_ALL="$_c" locale charmap 2>/dev/null)" = "UTF-8" ]; then _u="$_c"; break; fi
    done
    if [ -n "$_u" ]; then
      # LC_ALL 이 걸려 있으면 LC_CTYPE 을 덮어써 무효화된다 → LC_ALL 은 풀고 개별 카테고리로.
      #   (LC_ALL 을 세우는 쪽으로 맞추면 위에서 고정한 LC_NUMERIC=C 까지 덮어써 버린다.)
      if [ -n "${LC_ALL:-}" ]; then export LANG="${LANG:-$LC_ALL}"; unset LC_ALL; fi
      export LC_CTYPE="$_u"
    else
      _READ_E=""     # UTF-8 로케일이 없음 → readline 이 한글을 이스케이프로 찍는다, 종전 방식 유지
      warn "입력 편집" "UTF-8 로케일이 없어 한글 지우기가 바이트 단위로 동작합니다 (백스페이스 3번)"
    fi
    ;;
esac

# ── JSON 헬퍼 (전역 정의 필수) ────────────────────────────────────────────
# 주의: 이 두 함수는 emit_main_json() 뿐 아니라 Eureka 섹션 등 함수 밖에서도
#       호출된다. 함수 내부에 정의하면 호출 시점에 미정의 상태가 되어
#       "_j: command not found" 로 값이 통째로 유실되므로 반드시 최상위에 둔다.
# JSON 특수문자 이스케이프. 문자열 내 raw 제어문자는 JSON 사양 위반이라
# (Node JSON.parse 가 "Bad control character" 로 거부) 탭/개행/CR 은 공백으로,
# 나머지 제어문자는 제거한다.
# LC_ALL=C 필수: tr 의 바이트 범위는 로케일 문자셋으로 해석된다. 서버 로케일이
#   ko_KR.eucKR 같은 비UTF-8 다바이트면 한글 바이트가 범위에 걸려 통째로 지워진다
#   (고객사명·담당자명이 깨져서 나갔다). C 로케일에서는 순수 바이트 단위로 동작해
#   ≥0x80 인 한글/UTF-8 다바이트를 건드리지 않는다.
_j() {
  LC_ALL=C printf '%s' "$1" \
    | LC_ALL=C tr '\011\012\015' '   ' \
    | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' \
    | LC_ALL=C sed 's/\\/\\\\/g; s/"/\\"/g'
}
# 공백 구분 목록을 최대 N개(기본10)까지만, 초과분은 "외 M개"로 요약
_summ() {
  local n="${2:-10}"; local -a a=($1); local c=${#a[@]}
  if [ "$c" -le "$n" ]; then printf '%s' "$1"; else printf '%s 외 %d개' "${a[*]:0:$n}" "$((c-n))"; fi
}
# conf 값 읽기: 주석 제외, 첫 매칭, '=' 이후 전체(값에 = 포함 가능), CR·공백 trim.
# xargs 는 따옴표를 해석하고(비밀번호의 ' 에서 unterminated quote) 백슬래시를
# 먹고 CR 도 남기므로 trim 용도로 쓰지 않는다.
# 매칭은 2단계: ① 줄머리에 정확히 그 키 → ② 없으면 접두사 허용(account.db_driver 등).
# 이렇게 해야 'notihub.admin.email' 이 'admin.email' 보다 먼저 잡히는 일이 없다.
_trim() { sed -e 's/\r$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }
_conf_get() {
  local v
  v=$(grep -iE "^[[:space:]]*$2[[:space:]]*=" "$1" 2>/dev/null | head -1 | cut -d'=' -f2- | _trim)
  [ -z "$v" ] && v=$(grep -iE "^[^#]*$2[[:space:]]*=" "$1" 2>/dev/null | head -1 | cut -d'=' -f2- | _trim)
  printf '%s' "$v"
}

# 파일 소유자 "이름:그룹". UID/GID 가 /etc/passwd·/etc/group 에 없으면 stat 이
#   "UNKNOWN:UNKNOWN" 을 내놓는다 — 컨테이너 안에서 호스트 파일을 보거나, 계정이
#   삭제됐거나, NFS id 매핑이 없을 때 생긴다. 이때는 숫자 UID:GID 로 대체해
#   최소한 식별은 가능하게 한다(UNKNOWN 만 적히면 확인서에서 쓸모가 없다).
_owner_of() {
  local o n
  o=$(stat -c '%U:%G' "$1" 2>/dev/null || echo "")
  case "$o" in
    ""|*UNKNOWN*)
      n=$(stat -c '%u:%g' "$1" 2>/dev/null || echo "")
      [ -n "$n" ] && o="$n"
      ;;
  esac
  printf '%s' "$o"
}

# ── agents API 응답 파서 ──────────────────────────────────────────────────────
# /open/api/json/project/agents 는 active 필터가 없어(OpenApiController.getProjectAgents)
# 예전에 붙었다 죽은 에이전트까지 전부 내려준다. 대수는 "활성"만 세야 실제 운영 대수와 맞는다.
#
# 출력: active(1/0/-1) <TAB> subtypeName <TAB> ip <TAB> version   (에이전트 1대당 1줄)
#   active = -1 은 응답에 active 키가 아예 없다는 뜻. 서버 버전이나 에이전트 모델
#   (DBAgentInfo/ContainerInfo 등 하위 클래스)에 따라 없을 수 있어, 이때는 활성 필터를
#   끄고 전수 집계로 폴백한다. 필터를 그냥 걸면 대수가 통째로 0 이 되어버리기 때문.
# 응답은 한 줄 JSON 이라 '{' 로 쪼개면 에이전트 객체 하나가 한 줄이 된다(기존 파싱과 동일 방식).
_agents_parse() {
  printf '%s' "$1" | tr '{' '\n' | awk '
    /"oid"/ {
      act=-1; st=""; ip=""; ver=""
      if (match($0, /"active":(true|false)/)) act = (substr($0, RSTART+9, 4) == "true") ? 1 : 0
      if (match($0, /"subtypeName":"[^"]*"/)) st  = substr($0, RSTART+15, RLENGTH-16)
      if (match($0, /"ip":"[^"]*"/))          ip  = substr($0, RSTART+6,  RLENGTH-7)
      if (match($0, /"version":"[^"]*"/))     ver = substr($0, RSTART+11, RLENGTH-12)
      printf "%d\t%s\t%s\t%s\n", act, st, ip, ver
    }'
}
# 집계 대상만 남기는 순수 필터 (stdin → stdout).
#   active 정보가 한 줄도 없으면(전부 -1) 전수 통과, 아니면 active==1 만 통과.
#   ※ 상태값을 반환하지 않는다 — 아래 _agents_stats 와 분리한 이유는, 이 함수는
#     $(...) 안에서 쓰이는데 명령치환은 서브셸이라 함수 안에서 설정한 전역이
#     호출부로 돌아오지 않기 때문. 카운터는 반드시 호출부 셸에서 계산해야 한다.
_agents_filter() {
  awk -F'\t' '
    { l[NR]=$0; if ($1==-1) noact=1; if ($1==1) act[NR]=1 }
    END { for (i=1; i<=NR; i++) if (noact || (i in act)) print l[i] }'
}
# 전체 파싱 결과($1)로 _AG_TOTAL / _AG_INACTIVE / _AG_NOACT 를 설정한다.
# 반드시 명령치환 없이 그냥 호출할 것 (`_agents_stats "$all"`) — 그래야 전역이 남는다.
_agents_stats() {
  _AG_TOTAL=$(printf '%s' "$1" | grep -c . || true)
  _AG_NOACT=$(printf '%s' "$1" | awk -F'\t' '$1==-1' | grep -c . || true)
  if [ "${_AG_NOACT:-0}" -gt 0 ] 2>/dev/null; then
    _AG_INACTIVE=0            # active 정보 없음 → 전수 집계 폴백 (제외한 게 없음)
  else
    _AG_INACTIVE=$(printf '%s' "$1" | awk -F'\t' '$1==0' | grep -c . || true)
  fi
}
# SMS subtypeName → 보고서 표기 라벨.
#   서버 SMEnum 은 linux/window/osx/hpux/aix/sunos/openbsd/freebsd 8종이고,
#   매핑에 없는 subtype 은 숫자 문자열로 내려온다(SMEnum.toString 의 마지막 return).
#   예전엔 4종만 세서 Solaris 등이 총계에만 잡히고 내역에서 빠져 합이 안 맞았다.
#   (emit_main_json 에서도 쓰이므로 반드시 최상위 — 파일 상단 주석의 _j/_summ 과 같은 이유)
_sms_os_label() {
  case "$1" in
    linux)   printf 'Linux' ;;   window|windows) printf 'Windows' ;;
    aix)     printf 'AIX' ;;     hpux)           printf 'HP-UX' ;;
    sunos)   printf 'Solaris' ;; osx)            printf 'macOS' ;;
    openbsd) printf 'OpenBSD' ;; freebsd)        printf 'FreeBSD' ;;
    "")      printf '미상' ;;
    *)       printf '기타(%s)' "$1" ;;
  esac
}

# 활성 집계가 한 번이라도 폴백됐는지 / 비활성이 몇 대 제외됐는지 (보고서 근거 표기용)
_AGENT_COUNT_BASIS="활성 에이전트만 집계"
_AGENT_INACTIVE_TOTAL=0
_AGENT_NOACT_SEEN=0
# 프로젝트 1건 처리 후 누적 (호출부에서 _agents_stats 직후 호출)
_agents_tally() {
  _AGENT_INACTIVE_TOTAL=$(( _AGENT_INACTIVE_TOTAL + ${_AG_INACTIVE:-0} ))
  if [ "${_AG_NOACT:-0}" -gt 0 ] 2>/dev/null; then
    _AGENT_NOACT_SEEN=1
    _AGENT_COUNT_BASIS="전체 에이전트(활성 여부 미제공 — 비활성 포함 가능)"
  fi
}

# 디스크 용량 JSON 경로 (설치확인서 JSON 과 별도 파일 — 한 번 실행 시 JSON 2개 생성)
DISK_OUTPUT_JSON="$OUT_DIR/disk_usage.json"
_DISK_TMP=""      # 디스크 스캔 임시파일 (중단 시 정리)
_DISK_ROOT=""     # yardbase 경로 (3번/6번 섹션에서 결정)

# ══════════════════════════════════════════════════════════════════════════
# 안전장치: 어느 지점에서 스크립트가 멈춰도(정상/오류/Ctrl+C/종료신호) 설치확인서
#           JSON 은 항상 남긴다.
#           - 메인 JSON: 지금까지 수집된 값으로 조립 → 임시파일 후 원자적 교체
#           - 디스크 JSON: 사용자가 '수집'(y)을 골랐을 때만 만든다 (아래 참고)
# ══════════════════════════════════════════════════════════════════════════
_MAIN_JSON_EMITTED=0

# 지금까지 수집된 값으로 collected_data.json 을 조립·저장 (한 번만 수행).
# 미수집 변수는 빈 값으로 채워져도 JSON 은 항상 유효하게 출력된다.
emit_main_json() {
  [ "$_MAIN_JSON_EMITTED" = "1" ] && return 0
  _MAIN_JSON_EMITTED=1
  local _main_tmp="${OUTPUT_JSON}.part"

# (_j / _summ 는 최상위에 정의됨 — Eureka 섹션 등 함수 밖에서도 쓰이기 때문)

# ── 제품 존재 여부에 따라 JSON 섹션을 조건부 조립 (없는 제품은 키 생략) ──
_awk_kv='{printf "%s\"%s\":%s", (NR>1?",":""), $1, $2}'

# agentCount 내용 (존재하는 제품만)
_AC=""
_acadd() { [ -n "$_AC" ] && _AC="${_AC}, "; _AC="${_AC}$1"; }
[ "$_APM_INCLUDE" = "1" ] && _acadd "\"apm\": ${_APM_TOTAL}, \"apmByPlatform\": {$(echo "$_APM_PLAT_COUNTS" | tr ',' '\n' | grep -v '^$' | awk -F: "$_awk_kv" || true)}"
# K8s 내 APM: 호스트 APM 과 뭉치지 않도록 별도 항목 (apm 에서는 이미 차감됨)
[ "${_K8S_APM_TOTAL:-0}" -gt 0 ] 2>/dev/null && _acadd "\"k8sApm\": ${_K8S_APM_TOTAL}"
# smsByOs: 4종 고정이 아니라 수집된 subtype 전부를 라벨로 변환해 넣는다(내역 합 == sms 총계).
_SMS_BYOS=""
if [ "$_SMS_FOUND" = "1" ]; then
  while IFS=':' read -r _st _n; do
    [ -z "$_st" ] && continue
    _SMS_BYOS="${_SMS_BYOS}${_SMS_BYOS:+,}\"$(_j "$(_sms_os_label "$_st")")\":${_n}"
  done <<_BYOS_EOF
$(echo "$_SMS_OS_COUNTS" | tr ',' '\n' | grep -v '^$' | sort -t: -k2,2nr)
_BYOS_EOF
fi
[ "$_SMS_FOUND" = "1" ]   && _acadd "\"sms\": ${_SMS_TOTAL}, \"smsByOs\": {${_SMS_BYOS}}"
[ "$_DPM_FOUND" = "1" ]   && _acadd "\"dpm\": ${_DPM_TOTAL}, \"dpmByDb\": {$(echo "$_DPM_DB_COUNTS" | tr ',' '\n' | grep -v '^$' | awk -F: "$_awk_kv" || true)}"
[ "$_CPM_FOUND" = "1" ]   && _acadd "\"cpm\": ${_CPM_TOTAL_AGENTS}, \"cpmByRole\": {\"master\":${_CPM_TOTAL_MASTER},\"node\":${_CPM_TOTAL_NODE}}"
# total 에는 k8sApm 도 포함한다 — 분리 집계는 "표기를 쪼개는 것"이지 대수를 빼는 게 아니다.
# (_APM_TOTAL 에서 이미 차감했으므로 여기서 다시 더해야 총 대수가 유지된다)
_acadd "\"total\": $(( _APM_TOTAL + ${_K8S_APM_TOTAL:-0} + _SMS_TOTAL + _DPM_TOTAL + _CPM_TOTAL_AGENTS ))"
# 집계 기준을 보고서에 명시하기 위한 메타 (활성만 셌는지 / 제외된 비활성이 몇 대인지)
_acadd "\"basis\": \"$(_j "${_AGENT_COUNT_BASIS}")\", \"inactiveExcluded\": $(( ${_AGENT_INACTIVE_TOTAL:-0} ))"

# 각 제품 섹션 (존재할 때만, 앞에 콤마 포함)
_JSON_APM=""; _JSON_SMS=""; _JSON_DPM=""; _JSON_CPM=""; _JSON_RUM=""; _JSON_WPM=""
[ "$_APM_INCLUDE" = "1" ] && _JSON_APM=$(cat <<APMEOF
,
  "apm": {
    "version": "$(_j "$APM_VERSION")",
    "agentCount": $(( _APM_TOTAL )),
    "agentCountByPlatform": {$(echo "$_APM_PLAT_COUNTS" | tr ',' '\n' | grep -v '^$' | awk -F: "$_awk_kv" || true)},
    "installPath": "$(_j "$APM_INSTALL_PATH")",
    "logPath": "$(_j "${APM_INSTALL_PATH:+$APM_INSTALL_PATH/logs}")",
    "language": "$(_j "$APM_LANG")",
    "was": "$(_j "$APM_WAS")",
    "javaVersion": "$(_j "$APM_JAVA_VERSION")",
    "selfInstalled": "$(_j "$APM_SELF_INSTALLED")",
    "startPointOption": "$(_j "$APM_START_POINT")",
    "weavingOption": "$(_j "$APM_WEAVING")",
    "runUser": "$(_j "$APM_RUN_USER")",
    "fileOwner": "$(_j "$APM_FILE_OWNER")"
  }
APMEOF
)
[ "$_SMS_FOUND" = "1" ] && _JSON_SMS=$(cat <<SMSEOF
,
  "sms": {
    "version": "$(_j "$SMS_VERSION")",
    "agentCount": $(( _SMS_TOTAL )),
    "installPath": "$(_j "$SMS_INSTALL_PATH")",
    "logPath": "$(_j "$SMS_LOG_PATH")",
    "os": "$(_j "$SMS_OS_SUMMARY")",
    "agentCountByOs": {${_SMS_BYOS}},
    "selfExcluded": $(( ${_SMS_SELF_COUNT:-0} )),
    "selfInstalled": "$(_j "$SMS_SELF_INSTALLED")"
  }
SMSEOF
)
[ "$_DPM_FOUND" = "1" ] && _JSON_DPM=$(cat <<DPMEOF
,
  "dpm": {
    "version": "$(_j "$DPM_VERSION")",
    "agentCount": $(( _DPM_TOTAL )),
    "agentCountByDb": {$(echo "$_DPM_DB_COUNTS" | tr ',' '\n' | grep -v '^$' | awk -F: "$_awk_kv" || true)},
    "installPath": "$(_j "$DPM_INSTALL_PATH")",
    "logPath": "$(_j "${DPM_INSTALL_PATH:+$DPM_INSTALL_PATH/logs}")",
    "dbType": "$(_j "$DPM_DB_TYPE")",
    "xosInstalled": "$(_j "$XOS_INSTALLED")",
    "xosCores": "$(_j "$DPM_XOS_CORES")",
    "xosMissingAgents": "$(_j "$(_summ "$(echo "$_DPM_XOS_MISSING" | xargs)")")",
    "slowSetting": "$(_j "$DPM_SLOW_SETTING")",
    "slowSettingOffProjects": "$(_j "$_DPM_SLOW_OFF_NAMES")",
    "dbVersionList": "$(_j "$DPM_DB_VERSION_LIST")",
    "runUser": "$(_j "$DPM_RUN_USER")",
    "fileOwner": "$(_j "$DPM_FILE_OWNER")",
    "filePerm": "$(_j "$DPM_FILE_PERM")"
  }
DPMEOF
)
[ "$_CPM_FOUND" = "1" ] && _JSON_CPM=$(cat <<CPMEOF
,
  "cpm": {
    "version": "$(_j "$CPM_VERSION")",
    "agentCount": $(( _CPM_TOTAL_AGENTS )),
    "agentCountMaster": $(( _CPM_TOTAL_MASTER )),
    "agentCountNode": $(( _CPM_TOTAL_NODE )),
    "agentCountUninstalled": $(( _CPM_TOTAL_UNINSTALLED )),
    "installMethod": "$(_j "$CPM_INSTALL_METHOD")",
    "kubeletVersion": "$(_j "$KUBELET_VERSION")",
    "containerRuntime": "$(_j "$CONTAINER_RUNTIME")",
    "k8sDistro": "$(_j "$CPM_K8S_DISTRO")",
    "operatorVersion": "$(_j "$CPM_OPERATOR_VERSION")",
    "installPath": "$(_j "$CPM_INSTALL_PATH")",
    "projects": [ ${_CPM_PROJ_JSON} ],
    "apm": {
      "used": $([ "$CPM_APM_USED" = "사용" ] && echo true || echo false),
      "projectCode": "$(_j "$CPM_APM_PCODE")",
      "agentCount": $(( ${_K8S_APM_TOTAL:-0} )),
      "installMethod": "$(_j "$CPM_APM_INSTALL_METHOD")",
      "detectMethod": "$(_j "$CPM_APM_DETECT_METHOD")",
      "detectError": "$(_j "$CPM_APM_DETECT_ERROR")",
      "target": "$(_j "$CPM_APM_TARGET")",
      "language": "$(_j "$CPM_APM_LANG")",
      "version": "$(_j "$CPM_APM_VERSION")"
    }
  }
CPMEOF
)
[ "${_has_rum:-0}" -gt 0 ] 2>/dev/null && _JSON_RUM=$(cat <<RUMEOF
,
  "rum": {
    "used": true,
    "projectCount": $(( ${_has_rum:-0} )),
    "version": "$(_j "$RUM_VERSION")",
    "server": "$(_j "$RUM_SERVER")",
    "installPath": "$(_j "$RUM_INSTALL_PATH")",
    "ctlServer": "$(_j "$RUM_CTL_SERVER")",
    "ctlInstallPath": "$(_j "$RUM_CTL_PATH")",
    "proxyServer": "$(_j "$RUM_PROXY_SERVER")",
    "proxyInstallPath": "$(_j "$RUM_PROXY_PATH")",
    "site": "$(_j "$RUM_SITE")",
    "edgeDomain": "$(_j "$RUM_EDGE_DOMAIN")",
    "edgeSsl": "$(_j "$RUM_EDGE_SSL")",
    "scriptGuide": "$(_j "$RUM_SCRIPT_GUIDE")"
  }
RUMEOF
)
[ "${_has_wpm:-0}" -gt 0 ] 2>/dev/null && _JSON_WPM=$(cat <<WPMEOF
,
  "wpm": {
    "used": true,
    "projectCount": $(( ${_has_wpm:-0} )),
    "version": "$(_j "$WPM_VERSION")",
    "server": "$(_j "$WPM_SERVER")",
    "installPath": "$(_j "$WPM_INSTALL_PATH")",
    "urlCount": "$(_j "$WPM_URL_COUNT")"
  }
WPMEOF
)

cat > "$_main_tmp" 2>/dev/null << EOF
{
  "apiOk": ${API_OK:-false},
  "apiHttpStatus": "$(_j "${API_HTTP_STATUS:-}")",
  "apiFailReason": "$(_j "${API_FAIL_REASON:-}")",
  "apiUrl": "$(_j "${API_URL_USED:-}")",
  "agentQueryFailed": "$(_j "${_AGENT_QUERY_FAIL:-}")",
  "projectCount": ${PROJ_COUNT:-0},
  "eureka": { "serverCount": ${EUREKA_SERVER_COUNT:-0}, "byHost": "$(_j "${EUREKA_BY_HOST:-}")", "modules": [ ${EUREKA_JSON_MODULES:-} ] },
  "customer": {
    "name": "$(_j "$CUSTOMER_NAME")",
    "contact": "$(_j "$CONTACT_PERSON")",
    "installDate": "$(_j "$INSTALL_DATE")",
    "engineer": "$(_j "$ENGINEER")"
  },
  "collector": {
    "ip": "$(_j "$SERVER_IP")",
    "os": "$(_j "$SERVER_OS")",
    "cpu": "$(_j "$SERVER_CPU")",
    "memory": "$(_j "$SERVER_MEM")",
    "disk": "$(_j "$SERVER_DISK")",
    "infraType": "$(_j "${INFRA_TYPE:-}")",
    "storageType": "$(_j "${STORAGE_TYPE:-}")",
    "jdkVersion": "$(_j "$JAVA_VERSION")",
    "jdkPath": "$(_j "$JAVA_HOME_DIR")",
    "whatapVersion": "$(_j "$WHATAP_VERSION")",
    "moduleVersions": {$MODULE_VERSIONS},
    "customReport": "$(_j "${CUSTOM_REPORT_FOUND:-}")",
    "customReportJars": "$(_j "${CUSTOM_REPORT_JARS:-}")",
    "installPath": "$(_j "$SERVER_INSTALL_PATH")",
    "logPath": "$(_j "$SERVER_INSTALL_PATH/logs")",
    "yardbasePath": "$(_j "$YARDBASE")",
    "runUser": "$(_j "$SERVER_RUN_USER")",
    "fileOwner": "$(_j "$FILE_OWNER")",
    "filePerm": "$(_j "$FILE_PERM")",
    "url": "$(_j "$SERVER_URL")",
    "adminEmail": "$(_j "$ADMIN_EMAIL")",
    "dbType": "$(_j "$DB_TYPE")",
    "dbVersion": "$(_j "$DB_VERSION")",
    "dbInstallPath": "$(_j "$DB_INSTALL_PATH")"
  },
  "agentCount": {
    ${_AC}
  }${_JSON_APM}${_JSON_SMS}${_JSON_DPM}${_JSON_CPM}${_JSON_RUM}${_JSON_WPM}
}
EOF

  # 임시파일이 정상 생성됐을 때만 원자적 교체 (부분 기록으로 인한 손상 방지)
  if [ -s "$_main_tmp" ]; then
    mv -f "$_main_tmp" "$OUTPUT_JSON" 2>/dev/null || cp -f "$_main_tmp" "$OUTPUT_JSON" 2>/dev/null
    ok "JSON 저장" "$OUTPUT_JSON"
  else
    rm -f "$_main_tmp" 2>/dev/null
    fail "JSON 저장" "출력 생성 실패: $OUTPUT_JSON"
  fi
}

# 디스크 JSON 스켈레톤(빈 결과) 기록 — 사용자가 '수집'(y)을 골라 실제 스캔에 들어갈
# 때만 호출한다(스캔이 중단돼도 유효한 JSON 이 남게 하는 용도).
#   수집하지 않았을 때는 절대 만들지 않는다: 값이 0 인 디스크 JSON 은 "수집했는데
#   용량 0" 으로 읽혀 잘못된 정보가 되고, 미수집이면 파일 자체가 의미가 없다.
write_disk_skeleton() {
  local _h _n _r
  _h="$(hostname 2>/dev/null || echo unknown)"
  _n="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
  # LC_ALL=C: EUC-KR 등 비UTF-8 다바이트 로케일은 한글 둘째 바이트에 0x5C(백슬래시)가
  #   올 수 있어, 로케일을 안 고정하면 sed 가 그걸 이스케이프 대상으로 오인해 깨진다.
  _r="$(LC_ALL=C printf '%s' "${_DISK_ROOT:-}" | LC_ALL=C sed 's/\\/\\\\/g; s/"/\\"/g')"
  cat > "$DISK_OUTPUT_JSON" 2>/dev/null <<EOF
{
  "schema_version": 2,
  "collected_at": "$(_j "$_n")",
  "host": "$(_j "$_h")",
  "root": "$(_j "$_r")",
  "size_mode": "apparent",
  "observed": { "interval_sec": 1 },
  "grand_total_bytes": 0,
  "scanned_total_bytes": 0,
  "unclassified": { "bytes": 0, "file_count": 0 },
  "excluded_deleted_projects": { "count": 0, "bytes": 0 },
  "root_files": { "bytes": 0, "file_count": 0 },
  "projects": [],
  "incomplete": true
}
EOF
}

# 임시파일 정리
_cleanup_tmp() {
  [ -n "${_DISK_TMP:-}" ] && rm -f "$_DISK_TMP" 2>/dev/null
  [ -n "${_TPS_MAP:-}" ] && rm -f "$_TPS_MAP" 2>/dev/null
  [ -n "${_DISK_FIND_ERR:-}" ] && rm -f "$_DISK_FIND_ERR" 2>/dev/null
  _DISK_TMP=""
  rm -f "${OUTPUT_JSON}.part" 2>/dev/null
  return 0
}

# 종료 시(정상/오류/신호) 설치확인서 JSON 이 남도록 보장하는 최종 처리
# (디스크 JSON 은 여기서 만들지 않는다 — 수집을 실제로 한 경우에만 존재해야 한다)
_on_exit() {
  emit_main_json          # 아직 안 나갔으면 지금까지 값으로 저장 (가드로 중복 방지)
  _cleanup_tmp
}
trap '_on_exit' EXIT
trap 'echo >&2; warn "중단 감지" "지금까지 수집된 데이터로 JSON 저장 후 종료합니다"; exit 130' INT
trap 'exit 143' TERM HUP

echo -e "${CYAN}"
echo "╔════════════════════════════════════════╗"
echo "║  WhaTap 설치확인서 자동 수집 스크립트  ║"
echo "╚════════════════════════════════════════╝"
echo -e "${NC}"


# ══════════════════════════════════════════
# 1. 사용자 입력
# ══════════════════════════════════════════
# stdin 이 터미널이 아니면 read 가 사용자 입력 대신 stdin 내용을 읽어버린다.
# 특히 `curl ... | bash` 로 실행하면 stdin 이 스크립트 본문이라 read 가
# 스크립트 자기 소스코드를 한 줄씩 먹고, 그 줄들은 실행되지도 않는다.
# (bash 는 stdin 이 비터미널이면 read -p 프롬프트조차 출력하지 않아 원인 파악도 어렵다.)
# → /dev/tty 로 전환 가능하면 전환하고, 불가하면 안내 후 중단한다.
if [ ! -t 0 ]; then
  if [ -c /dev/tty ] && (: < /dev/tty) 2>/dev/null; then
    exec < /dev/tty
    warn "실행 방식" "stdin 이 터미널이 아님 → /dev/tty 로 전환 (파이프 실행 감지)"
  else
    fail "실행 방식" "대화형 입력이 불가한 환경입니다 (stdin 비터미널, /dev/tty 없음)"
    echo -e "${RED}▶ 'curl ... | bash' 이나 cron/nohup, '< /dev/null' 로 실행하면"
    echo -e "  입력값이 비거나 스크립트 소스코드로 채워져 확인서가 통째로 잘못 생성됩니다."
    echo -e "  파일로 내려받아 터미널에서 'bash collect.sh' 로 실행해 주세요.${NC}"
    trap - EXIT INT TERM HUP     # 잘못된 JSON 을 남기지 않도록 종료 훅 해제
    exit 1
  fi
fi

# ── API 토큰 입력 보정 ────────────────────────────────────────────────────
# 토큰 붙여넣기 실패는 원인이 거의 정해져 있다.
#   ① 앞뒤 공백 / 줄바꿈(\r\n) / 탭  ② 따옴표째 복사  ③ 'x-whatap-token:' 헤더째 복사
#   ④ 콘솔에서 줄바꿈된 채로 복사돼 토큰 중간에 개행이 들어간 경우
# ①~③ 은 문자 제거로, ④ 는 _read_token() 의 잔여입력 흡수로 처리한다.
_sanitize_token() {
  printf '%s' "$1" \
    | LC_ALL=C tr -d '[:space:]' \
    | sed -e "s/^[\"']*//;s/[\"']*$//" \
          -e 's/^[Xx]-[Ww][Hh][Aa][Tt][Aa][Pp]-[Tt][Oo][Kk][Ee][Nn]:*//' \
          -e 's/^[Tt][Oo][Kk][Ee][Nn]:*//' \
          -e "s/^[\"']*//;s/[\"']*$//"
}

# read 는 한 줄만 읽는다. 줄바꿈이 낀 토큰을 붙여넣으면 뒷부분이 그대로 남아
#   '수집서버 URL' 같은 다음 질문의 답으로 들어가 버린다(입력한 사람은 눈치채기 어렵다).
#   → 프롬프트 직후 버퍼에 남아 있는 줄을 전부 흡수해서 한 줄로 이어 붙인다.
#   타임아웃은 이미 붙여넣어진 입력만 걷어내는 용도라 짧을수록 좋지만,
#   bash 3 은 소수점 -t 를 못 받으므로 1초로 떨어뜨린다.
_DRAIN_T=1
[ "${BASH_VERSINFO[0]:-3}" -ge 4 ] 2>/dev/null && _DRAIN_T=0.05
_read_token() {          # $1=프롬프트  → 결과: _TOKEN_IN (_TOKEN_EOF=1 이면 더 받을 입력이 없음)
  local _line="" _extra=""
  _TOKEN_EOF=0
  read -r $_READ_E -p "$1" _line || { _TOKEN_EOF=1; _line=""; }
  while IFS= read -r -t "$_DRAIN_T" _extra 2>/dev/null; do
    _line="${_line}${_extra}"
  done
  _TOKEN_IN=$(_sanitize_token "$_line")
}

_token_report() {        # 입력된 토큰의 겉모양 점검 (통과/실패 판정은 실제 API 호출로 한다)
  local _t="$1"
  if [ -z "$_t" ]; then
    warn "API 토큰" "입력 없음 — 프로젝트 목록 조회 단계에서 다시 물어봅니다"
  elif printf '%s' "$_t" | grep -q '[^A-Za-z0-9_-]'; then
    warn "API 토큰" "허용되지 않은 문자 포함 — 잘못 복사됐는지 확인하세요 (길이 ${#_t})"
  elif [ "${#_t}" -lt 16 ]; then
    warn "API 토큰" "길이가 짧습니다 (${#_t}) — 일부만 복사됐는지 확인하세요"
  else
    ok "API 토큰" "입력됨 (길이 ${#_t})"
  fi
}

section "기본 정보 입력"
read -r $_READ_E -p "  고객사 명: " CUSTOMER_NAME
read -r $_READ_E -p "  담당자: " CONTACT_PERSON
read -r $_READ_E -p "  설치 엔지니어: " ENGINEER
INSTALL_DATE=$(date +"%Y-%m-%d")
echo ""
_read_token "  Admin 계정 API 토큰: "
WHATAP_ACCOUNT_TOKEN="$_TOKEN_IN"
_token_report "$WHATAP_ACCOUNT_TOKEN"

# 에이전트별 사용자 입력은 API 조회 후 아래에서 처리
APM_INSTALL_PATH=""
APM_RUN_USER=""
APM_FILE_OWNER=""
APM_START_POINT=""
APM_WEAVING=""
SMS_DEFAULT_PATH="/usr/whatap/infra"   # SMS 기본 설치 경로 (로그는 <설치경로>/logs)
SMS_INSTALL_PATH="$SMS_DEFAULT_PATH"
SMS_LOG_PATH="$SMS_DEFAULT_PATH/logs"
DPM_INSTALL_PATH=""
DPM_RUN_USER=""
DPM_FILE_OWNER=""
DPM_FILE_PERM=""
CPM_INSTALL_PATH=""
CPM_INSTALL_METHOD=""
CPM_OPERATOR_VERSION=""
CPM_APM_USED=""
CPM_APM_PCODE=""
CPM_APM_INSTALL_METHOD=""
CPM_APM_TARGET=""
CPM_APM_LANG=""
CPM_APM_VERSION=""
CPM_APM_DETECT_METHOD=""
CPM_APM_DETECT_ERROR=""
RUM_VERSION=""          # rum-onpremise-pkg 버전
RUM_SERVER=""           # 레거시(구 템플릿 호환) — rumctl 값을 그대로 넣는다
RUM_INSTALL_PATH=""
RUM_CTL_SERVER=""       # rumctl 설치 서버 / 위치
RUM_CTL_PATH=""
RUM_PROXY_SERVER=""     # rumproxy·rumagent 설치 서버 / 위치
RUM_PROXY_PATH=""
RUM_SITE=""
RUM_EDGE_DOMAIN=""
RUM_EDGE_SSL=""
RUM_SCRIPT_GUIDE=""
WPM_VERSION=""
WPM_SERVER=""
WPM_INSTALL_PATH=""
WPM_URL_COUNT=""

# ══════════════════════════════════════════
# 2. WhaTap 수집서버 설정 읽기
# ══════════════════════════════════════════
# 3. 시스템 정보 수집
# ══════════════════════════════════════════
section "수집서버 시스템 정보"

# IP
#   주의: `A | awk || B` 는 파이프라인 종료코드가 마지막 awk(항상 0)라서 B가
#   절대 실행되지 않는다. 단계별로 빈 값을 확인해 폴백해야 한다.
#   또한 docker0(172.17.x) 가 먼저 잡히지 않도록 실제 송신 IP(src)를 우선한다.
SERVER_IP=""
if command -v ip >/dev/null 2>&1; then
  SERVER_IP=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
fi
if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -vE '^$|^127\.' | head -1)
fi
if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')
fi
if [ -n "$SERVER_IP" ]; then ok "IP 주소" "$SERVER_IP"
else fail "IP 주소" "ip route / hostname -I 모두 실패 — API 호출·에이전트 self 제외가 동작하지 않습니다"; fi

# OS
if [ -f /etc/os-release ]; then
  # -m1 + ^앵커: 주석줄이나 중복 항목이 함께 잡혀 값에 개행이 섞이는 것 방지
  SERVER_OS=$(grep -m1 '^PRETTY_NAME=' /etc/os-release | cut -d'"' -f2)
  ok "OS" "$SERVER_OS"
elif [ -f /etc/redhat-release ]; then
  SERVER_OS=$(cat /etc/redhat-release)
  ok "OS" "$SERVER_OS"
else
  SERVER_OS=$(uname -s -r)
  warn "OS" "$SERVER_OS (상세 정보 없음 — /etc/os-release 없음)"
fi

# CPU
CPU_COUNT=$(nproc 2>/dev/null || echo "")
if [ -n "$CPU_COUNT" ]; then
  SERVER_CPU="${CPU_COUNT}core"
  ok "CPU" "$SERVER_CPU"
else
  SERVER_CPU="?"
  fail "CPU" "nproc 실패 — /proc/cpuinfo 확인 필요"
fi

# Memory
#   free -h 는 procps-ng 3.3.10+ 전용이라 CentOS/RHEL 6(procps 3.2.8)에서 실패하고,
#   'Mem:' 라벨은 로케일 번역 대상이라 매칭이 깨질 수 있다 → /proc/meminfo 직독 우선.
SERVER_MEM=$(awk '/^MemTotal:/{printf "%.1fGi", $2/1048576}' /proc/meminfo 2>/dev/null)
[ -z "$SERVER_MEM" ] && SERVER_MEM=$(LC_ALL=C free -m 2>/dev/null | awk '$1 ~ /^Mem/{printf "%.1fGi", $2/1024}')
if [ -n "$SERVER_MEM" ]; then ok "Memory" "$SERVER_MEM"
else fail "Memory" "/proc/meminfo·free 모두 실패"; SERVER_MEM="?"; fi

# ── WhaTap 수집서버 모듈 감지 (front|yard 하나라도 있으면 진행) ──
#   설치경로/기동계정은 감지된 프로세스에서, 역할(front/yard/all)은 conf·yardbase 존재로 판별.
SERVER_INSTALL_PATH=""
SERVER_RUN_USER=""
ANY_PROC=$(ps -efww 2>/dev/null | grep -v grep | grep -iE "whatap\.server|/whatap/.*server|whatap.*(yard|front)" | head -1 || echo "")
if [ -z "$ANY_PROC" ]; then
  trap - EXIT INT TERM HUP        # 종료 훅 해제 → JSON 미생성
  echo ""
  fail "WhaTap 수집서버" "실행 중인 수집서버 모듈(front/yard 등)이 없습니다"
  echo -e "${RED}▶ 이 서버에 WhaTap 수집서버가 떠있지 않습니다. front 또는 yard 가 기동된 서버에서 실행해 주세요.${NC}"
  exit 1
fi
# 대표 프로세스에서 설치경로·기동계정 (yard 우선 → 없으면 아무 whatap 모듈)
REF_PROC=$(ps -efww 2>/dev/null | grep -v grep | grep -i whatap | grep -iE "yard" | head -1 || echo "")
[ -z "$REF_PROC" ] && REF_PROC="$ANY_PROC"
_pid=$(echo "$REF_PROC" | awk '{print $2}')
SERVER_RUN_USER=$(echo "$REF_PROC" | awk '{print $1}')
_cmd=$(tr '\0' ' ' < "/proc/$_pid/cmdline" 2>/dev/null || echo "$REF_PROC")
SERVER_INSTALL_PATH=$(echo "$_cmd" | grep -oE '\-Dwhatap\.home=[^ ]+' | head -1 | cut -d= -f2)
if [ -z "$SERVER_INSTALL_PATH" ]; then
  _jar=$(echo "$_cmd" | grep -oE '/[^ ]*whatap\.server\.[^ ]*\.jar' | head -1)
  [ -n "$_jar" ] && SERVER_INSTALL_PATH=$(dirname "$(dirname "$_jar")")
fi
[ -z "$SERVER_INSTALL_PATH" ] && SERVER_INSTALL_PATH=$(readlink -f "/proc/$_pid/cwd" 2>/dev/null || echo "")
[ -z "$SERVER_INSTALL_PATH" ] && SERVER_INSTALL_PATH="${WHATAP_HOME:-/usr/whatap/server}"
# 설치경로가 실행 스크립트의 bin/ 디렉터리로 잡히는 경우(cwd가 bin이거나 whatap.home이 bin까지 포함) 보정
SERVER_INSTALL_PATH="${SERVER_INSTALL_PATH%/bin}"
ok "설치 경로" "$SERVER_INSTALL_PATH"
ok "기동 계정" "$SERVER_RUN_USER"

# ── 역할 판별: front.conf(front측) / yard.conf·yardbase(yard측) 로컬 존재로 ──
HAS_FRONT_LOCAL=0; [ -f "$SERVER_INSTALL_PATH/conf/front.conf" ] && HAS_FRONT_LOCAL=1
HAS_YARD_LOCAL=0; { [ -f "$SERVER_INSTALL_PATH/conf/yard.conf" ] || [ -d "$SERVER_INSTALL_PATH/yardbase" ]; } && HAS_YARD_LOCAL=1
if   [ "$HAS_FRONT_LOCAL" = 1 ] && [ "$HAS_YARD_LOCAL" = 1 ]; then COLLECT_ROLE="all";   ok   "구성 역할" "올인원 (front+yard 동일 서버) — 전 항목 수집"
elif [ "$HAS_YARD_LOCAL" = 1 ];                                then COLLECT_ROLE="yard";  warn "구성 역할" "yard 서버 — 디스크/yardbase 수집 (URL/DB/관리자는 front 서버 정보)"
elif [ "$HAS_FRONT_LOCAL" = 1 ];                              then COLLECT_ROLE="front"; warn "구성 역할" "front 서버 — 본문(URL/DB/관리자/구성) 수집, 디스크는 yard 노드에서"
else                                                               COLLECT_ROLE="other"; warn "구성 역할" "front.conf·yardbase 둘 다 로컬에 없음 (경로 확인 필요)"
fi
DEPLOY_MODE=$([ "$COLLECT_ROLE" = "all" ] && echo "all-in-one" || echo "split")

# ── 설정 파일: {설치경로}/conf/front.conf ──
section "WhaTap 수집서버 설정"
FRONT_CONF="$SERVER_INSTALL_PATH/conf/front.conf"
WHATAP_CONF="$SERVER_INSTALL_PATH/conf/whatap.conf"

if [ -f "$FRONT_CONF" ]; then
  ok "설정 파일" "$FRONT_CONF"
else
  fail "설정 파일" "$FRONT_CONF 없음"
fi


# 관리자 계정 (account.conf)
ACCOUNT_CONF="$SERVER_INSTALL_PATH/conf/account.conf"
ADMIN_EMAIL=$(_conf_get "$ACCOUNT_CONF" 'admin\.email')
if [ -n "$ADMIN_EMAIL" ]; then ok "관리자 계정" "$ADMIN_EMAIL"
else warn "관리자 계정" "account.conf 에서 admin.email 없음"; ADMIN_EMAIL="admin@whatap.io"; fi

# DB 설정 (account.conf — 주석 제외한 활성 db_driver 기준)
DB_TYPE="H2DB"
DB_PATH=""
if [ -f "$ACCOUNT_CONF" ]; then
  _driver=$(_conf_get "$ACCOUNT_CONF" 'db_driver')
  case "$_driver" in
    *mysql*|*MySQL*)             DB_TYPE="MySQL" ;;
    *mariadb*|*MariaDB*)         DB_TYPE="MariaDB" ;;
    *oracle*|*Oracle*)           DB_TYPE="Oracle" ;;
    *postgresql*|*PostgreSQL*)   DB_TYPE="PostgreSQL" ;;
    *h2*|*H2*)                   DB_TYPE="H2DB" ;;
  esac
  # -f2- : jdbc_url 은 값에 '=' 가 포함되므로(?useSSL=false) 뒷부분까지 살려야 한다
  DB_PATH=$(_conf_get "$ACCOUNT_CONF" 'jdbc_url')
fi
ok "수집서버 DB" "$DB_TYPE"
DB_VERSION=""
DB_INSTALL_PATH=""
if [ "$DB_TYPE" != "H2DB" ]; then
  DB_VERSION=$(mysql --version 2>/dev/null | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1 || echo "")
  [ -n "$DB_VERSION" ] && ok "DB 버전" "$DB_VERSION" || warn "DB 버전" "mysql 명령 없음 — 수기 작성 필요"
  _mysql_bin=$(which mysql 2>/dev/null || echo "")
  [ -n "$_mysql_bin" ] && DB_INSTALL_PATH=$(dirname "$(readlink -f "$_mysql_bin" 2>/dev/null || echo "$_mysql_bin")" | sed 's|/bin$||')
  [ -n "$DB_INSTALL_PATH" ] && ok "DB 설치 경로" "$DB_INSTALL_PATH" || warn "DB 설치 경로" "mysql 명령 없음 — 수기 작성 필요"
fi

# Disk — 우선순위: ① yardbase 경로 ② WhaTap 설치경로 ③ /
#   yardbase 가 별도 마운트(디스크)면 그 디스크의 사용량을 보고한다.
YARD_CONF="$SERVER_INSTALL_PATH/conf/yard.conf"
_yb_raw=$(_conf_get "$YARD_CONF" 'yardbase')
# 경로 정규화: 절대경로는 그대로 / 상대경로는 설치경로 기준 / 미지정은 설치경로/yardbase
case "$_yb_raw" in
  /*) YARDBASE="$_yb_raw" ;;
  "") YARDBASE="$SERVER_INSTALL_PATH/yardbase" ;;
  *)  YARDBASE="$SERVER_INSTALL_PATH/${_yb_raw#./}" ;;
esac
# 로그 보관일(전역) — 디스크 산정 웹앱이 로그 tier 를 1일로 가정하던 것을 실제값으로 대체한다.
#   주의: log_keep_days 는 yard.log 파일 로테이션용이라 로그 '데이터' 보관과 무관하다.
#   실제 로그 데이터는 logsink1=logsink_keep_date(기본 1), logsinkm=logsink_mcube_keep_date(기본 15).
#   (yard 는 logsink1 을 카테고리별로도 override 하므로 이 값은 전역 근사치다)
LOGSINK_KEEP=$(_conf_get "$YARD_CONF" 'logsink_keep_date')
LOGSINK_MCUBE_KEEP=$(_conf_get "$YARD_CONF" 'logsink_mcube_keep_date')

# 그래도 없으면 설치경로 하위에서 yardbase 디렉터리 탐색
if [ ! -d "$YARDBASE" ] && [ -d "$SERVER_INSTALL_PATH" ]; then
  _alt=$(find "$SERVER_INSTALL_PATH" -maxdepth 4 -type d -name yardbase 2>/dev/null | head -1 || true)
  [ -n "$_alt" ] && YARDBASE="$_alt"
fi
# df 는 -P(POSIX 출력) 없이 쓰면 장치명이 길 때(예: /dev/mapper/vg_root-lv_data) 줄을 접어
# 2번째 줄에 장치명만 오고 숫자는 3번째 줄로 밀린다 → NR==2 의 $2 가 빈 값이 된다.
# -P 는 파일시스템당 항상 한 줄을 보장하므로 반드시 붙인다.
_disk_line() { df -Ph "$1" 2>/dev/null | awk 'NR==2{printf "%s (사용 %s / %s)", $2, $5, $3}'; }  # 총량(사용률/사용량)
if [ -d "$YARDBASE" ] && df "$YARDBASE" &>/dev/null; then
  SERVER_DISK=$(df -Ph "$YARDBASE" | awk 'NR==2{print $2}')
  ok "Disk" "$(_disk_line "$YARDBASE") — 기준: $YARDBASE (yardbase)"
elif df "$SERVER_INSTALL_PATH" &>/dev/null; then
  SERVER_DISK=$(df -Ph "$SERVER_INSTALL_PATH" | awk 'NR==2{print $2}')
  warn "Disk" "$(_disk_line "$SERVER_INSTALL_PATH") — 기준: $SERVER_INSTALL_PATH (yardbase 못 찾아 설치경로 기준)"
elif df / &>/dev/null; then
  SERVER_DISK=$(df -Ph / | awk 'NR==2{print $2}')
  warn "Disk" "$(_disk_line /) — 기준: / (yardbase/설치경로 마운트 없음)"
else
  SERVER_DISK="?"
  fail "Disk" "df 명령 실패"
fi
# 디스크 총량(bytes) — 디스크 산정 차트의 '최대 디스크' 기준선용
_DISK_REF="$YARDBASE"; { [ -n "$_DISK_REF" ] && [ -d "$_DISK_REF" ]; } || _DISK_REF="$SERVER_INSTALL_PATH/yardbase"; [ -d "$_DISK_REF" ] || _DISK_REF="$SERVER_INSTALL_PATH"; [ -d "$_DISK_REF" ] || _DISK_REF="/"
SERVER_DISK_BYTES=$(df -P -B1 "$_DISK_REF" 2>/dev/null | awk 'NR==2{print $2}')
[ -n "$SERVER_DISK_BYTES" ] || SERVER_DISK_BYTES=0

# ── 인프라 구성 자동 감지 (VM/물리/컨테이너) ──
# systemd-detect-virt 는 systemd 패키지 소속이라 CentOS/RHEL 6(SysV init)에는 없다.
# 명령이 없는 것(빈 값)과 실제 물리서버("none")를 구분하지 않으면 RHEL6 VM 이
# "물리"로 확정 출력되므로, 명령 부재 시 다른 근거로 판별한다.
_virt=$(systemd-detect-virt 2>/dev/null || echo "")
_virt_unsure=0
if [ -z "$_virt" ]; then
  if [ -f /.dockerenv ] || grep -qE '(docker|containerd|kubepods|lxc)' /proc/1/cgroup 2>/dev/null; then
    _virt="container"
  elif command -v virt-what >/dev/null 2>&1; then
    _virt=$(virt-what 2>/dev/null | head -1)
  elif grep -qE '^flags.* hypervisor' /proc/cpuinfo 2>/dev/null; then
    # hypervisor 플래그가 있으면 가상화 게스트 (제품명은 DMI 에서, non-root 도 읽힘)
    _virt=$(cat /sys/class/dmi/id/product_name 2>/dev/null | head -1)
    [ -z "$_virt" ] && _virt="vm"
  fi
  [ -z "$_virt" ] && { _virt="none"; _virt_unsure=1; }
fi
if [ "$_virt" = "none" ]; then INFRA_TYPE="물리"
elif echo "$_virt" | grep -qiE "docker|lxc|podman|openvz|rkt|container"; then INFRA_TYPE="컨테이너 ($_virt)"
else INFRA_TYPE="VM ($_virt)"; fi
if [ "$_virt_unsure" = "1" ]; then
  warn "인프라 구성" "$INFRA_TYPE (추정 — systemd-detect-virt·virt-what 없음, 확인 필요)"
else
  ok "인프라 구성" "$INFRA_TYPE"
fi

# ── 스토리지 타입 자동 감지 (NAS(NFS)/SSD/HDD) ──
STORAGE_TYPE="모름"
_fstype=$(df -T "$_DISK_REF" 2>/dev/null | awk 'NR==2{print $2}')
if echo "$_fstype" | grep -qiE "nfs|cifs|smb"; then
  STORAGE_TYPE="NAS($_fstype)"
else
  _src=$(findmnt -no SOURCE --target "$_DISK_REF" 2>/dev/null | head -1)
  # rotational(0=SSD/1=HDD) 조회 — lsblk가 LVM/device-mapper/파티션까지 뚫어줌
  _rot=""
  if [ -n "$_src" ] && command -v lsblk >/dev/null 2>&1; then
    # 소스가 dm/LVM이면 하위 물리디스크들의 ROTA를 모두 보고 판단
    _rot=$(lsblk -rno ROTA "$_src" 2>/dev/null | grep -vx '' | sort -u | head -1)
    # 값이 여러 개면(혼합) 첫 값 사용, 비면 부모 디스크 기준 재시도
    [ -z "$_rot" ] && _rot=$(lsblk -rno ROTA "$_src" 2>/dev/null | head -1)
  fi
  # lsblk 실패 시 /sys/block 폴백 (파티션 번호 제거)
  if [ -z "$_rot" ]; then
    _dev=$(basename "$_src" 2>/dev/null | sed 's/p\?[0-9]*$//')
    [ -n "$_dev" ] && [ -r "/sys/block/$_dev/queue/rotational" ] && _rot=$(cat "/sys/block/$_dev/queue/rotational" 2>/dev/null)
  fi
  [ "$_rot" = "0" ] && STORAGE_TYPE="SSD" || { [ "$_rot" = "1" ] && STORAGE_TYPE="HDD"; }
fi
ok "스토리지 타입" "$STORAGE_TYPE (fs: ${_fstype:-?}, src: ${_src:-?})"

# JDK (날짜/LTS 부분 제거, 버전만)
JAVA_VERSION=$(java -version 2>&1 | head -1 | sed 's/.*version "\([^"]*\)".*/\1/' || echo "")
JAVA_PATH=$(readlink -f "$(which java 2>/dev/null)" 2>/dev/null || echo "")
JAVA_HOME_DIR=$(echo "$JAVA_PATH" | sed 's|/bin/java||')
if [ -n "$JAVA_VERSION" ]; then ok "JDK" "$JAVA_VERSION  경로: $JAVA_HOME_DIR"
else fail "JDK" "java 명령 없음 — PATH 확인 필요"; fi

# 기동 계정 (설치경로 감지 시 whatap 프로세스에서 이미 잡았으면 유지)
[ -z "$SERVER_RUN_USER" ] && SERVER_RUN_USER=$(echo "$REF_PROC" | awk '{print $1}' || echo "")
if [ -n "$SERVER_RUN_USER" ]; then ok "기동 계정" "$SERVER_RUN_USER"
else warn "기동 계정" "whatap 프로세스 못 찾음 — 수집서버 기동 여부/실행계정 확인 필요"; fi

# 파일 소유자
# 소유자:그룹 형태로 기재 (예: root:root) — 소유자만으로는 그룹 권한을 알 수 없다
FILE_OWNER=$(_owner_of "$SERVER_INSTALL_PATH")
if [ -z "$FILE_OWNER" ] || [ "$FILE_OWNER" = ":" ]; then
  FILE_OWNER=$(ls -la "$(dirname "$SERVER_INSTALL_PATH")" 2>/dev/null | awk -v d="$(basename "$SERVER_INSTALL_PATH")" '$NF==d{print $3":"$4}' | head -1 || echo "")
fi
if [ -n "$FILE_OWNER" ]; then ok "파일 소유자" "$FILE_OWNER"
else warn "파일 소유자" "확인 불가"; fi

# 설치 파일 권한
FILE_PERM=$(stat -c '%a' "$SERVER_INSTALL_PATH" 2>/dev/null || echo "")
if [ -n "$FILE_PERM" ]; then ok "설치 디렉터리 권한" "$FILE_PERM ($SERVER_INSTALL_PATH)"
else warn "설치 디렉터리 권한" "확인 불가"; fi

# 모듈별 정보 수집(버전 + 파일 소유자:그룹 + 기동 계정) + WhaTap 버전 (account jar 기준)
#   기동 계정·소유자는 모듈마다 다를 수 있어(예: yard 만 별도 계정) 모듈 단위로 수집한다.
#   전역 SERVER_RUN_USER/FILE_OWNER 하나로는 그 차이를 담을 수 없다.
info "모듈별 정보 수집 중..."
MODULE_VERSIONS=""
WHATAP_VERSION=""
for _mod in front account notihub eureka gateway yard proxy keeper router flexreport; do
  _jar=$(find "$SERVER_INSTALL_PATH/lib" -maxdepth 2 -name "whatap.server.${_mod}-*.jar" 2>/dev/null | head -1 || echo "")
  if [ -z "$_jar" ]; then
    _jar=$(find "$SERVER_INSTALL_PATH" -maxdepth 4 -name "whatap.server.${_mod}-*.jar" 2>/dev/null | head -1 || echo "")
  fi
  _ver=""; _mowner=""; _muser=""; _mfile=""
  if [ -n "$_jar" ]; then
    _mfile=$(basename "$_jar")
    _ver=$(basename "$_jar" | sed "s/whatap.server.${_mod}-//;s/\.jar$//")
    _mowner=$(_owner_of "$_jar")
    # 기동 계정: 해당 모듈 jar 로 떠 있는 프로세스의 실행 계정
    _muser=$(ps -eo user=,args= 2>/dev/null | grep "whatap\.server\.${_mod}[-.]" | grep -v grep \
      | awk '{print $1}' | head -1 || true)
    ok "  ${_mod}" "${_mowner:+$_mowner }${_mfile}${_muser:+ ($_muser)}"
    # account jar 버전을 WhaTap 대표 버전으로 사용
    if [ "$_mod" = "account" ] && [ -z "$WHATAP_VERSION" ]; then
      WHATAP_VERSION="$_ver"
    fi
  else
    warn "  ${_mod}" "jar 파일 없음"
  fi
  if [ -n "$MODULE_VERSIONS" ]; then MODULE_VERSIONS="${MODULE_VERSIONS},"; fi
  # 값을 객체로 낸다. 구버전 보고서는 문자열(버전)만 있으므로 렌더러가 둘 다 받는다.
  #   file 은 jar 파일명 원본 — 보고서에 ls -al 처럼 그대로 싣는다(버전 뒤 빌드번호까지 보존).
  MODULE_VERSIONS="${MODULE_VERSIONS}\"${_mod}\":{\"file\":\"$(_j "$_mfile")\",\"version\":\"$(_j "$_ver")\",\"owner\":\"$(_j "$_mowner")\",\"runUser\":\"$(_j "$_muser")\"}"
done
if [ -n "$WHATAP_VERSION" ]; then ok "WhaTap 버전" "$WHATAP_VERSION (account jar 기준)"
else warn "WhaTap 버전" "account jar 없음 — 버전 미확인"; fi

# ── 커스텀 보고서 검사 (기본 jar 외 custom jar 존재 여부) ──
#   개별 보고서: {설치경로}/migTools/report / 통합 보고서: {설치경로}/flexreport
info "커스텀 보고서 확인 중..."
CUSTOM_REPORT_FOUND="없음"; CUSTOM_REPORT_JARS=""
# 이름에 custom 이 들어가지만 기본 배포에 포함되는 jar — 커스텀 보고서로 세지 않는다.
#   (파일명 기준, 소문자 비교. 늘어나면 여기에만 추가하면 된다)
_CUSTOM_REPORT_DEFAULTS="custom.gpu.report.jar"
_custom_jar_list=$(find "$SERVER_INSTALL_PATH/migTools/report" "$SERVER_INSTALL_PATH/flexreport" -maxdepth 2 -type f -iname "*custom*.jar" 2>/dev/null || true)
while IFS= read -r _cjar; do
  [ -n "$_cjar" ] || continue
  _cname=$(basename "$_cjar")
  _clow=$(printf '%s' "$_cname" | tr 'A-Z' 'a-z')
  case " $_CUSTOM_REPORT_DEFAULTS " in
    *" $_clow "*) info "  기본 보고서 jar 제외: $_cname"; continue ;;
  esac
  ok "  커스텀 보고서" "$_cname"
  [ -n "$CUSTOM_REPORT_JARS" ] && CUSTOM_REPORT_JARS="${CUSTOM_REPORT_JARS}, "
  CUSTOM_REPORT_JARS="${CUSTOM_REPORT_JARS}${_cname}"
done <<EOF_CJAR
$_custom_jar_list
EOF_CJAR
# 기본 jar 만 있던 경우도 '없음' 이 되도록 목록이 실제로 찼는지로 판정한다
if [ -n "$CUSTOM_REPORT_JARS" ]; then
  CUSTOM_REPORT_FOUND="있음"
else
  warn "커스텀 보고서" "없음 (기본 jar만 존재)"
fi

# ── 수집서버 구성 (Eureka 서비스 레지스트리 조회) ──
#   eureka.conf 의 replicas.location(인증 포함 URL)을 읽어 /eureka/apps 조회.
#   전체 모듈·서버 IP·버전·상태를 원격으로 수집 → 분리/다중 서버 인벤토리.
section "수집서버 구성 (Eureka 조회)"
EUREKA_JSON_MODULES=""
EUREKA_SERVER_COUNT=0
EUREKA_BY_HOST=""    # "ip: mod1, mod2  /  ip2: mod3" — 다중 서버일 때 특이사항에 넣는다
EUREKA_CONF="$SERVER_INSTALL_PATH/conf/eureka.conf"
_eureka_loc=$(_conf_get "$EUREKA_CONF" 'eureka\.replicas\.location')
if [ -n "$_eureka_loc" ]; then
  _scheme="http"; case "$_eureka_loc" in https://*) _scheme="https" ;; esac
  _no_scheme=${_eureka_loc#http://}; _no_scheme=${_no_scheme#https://}
  _creds=""; _hostpart="$_no_scheme"
  case "$_no_scheme" in *@*) _creds=${_no_scheme%%@*}; _hostpart=${_no_scheme#*@} ;; esac
  _apps_url="${_scheme}://${_hostpart%/}/apps"
  _resp=$(curl -s ${_CURL_HTTP11} --connect-timeout 10 --max-time 30 ${_creds:+-u "$_creds"} -H "Accept: application/json" "$_apps_url" 2>/dev/null || echo "")
  if echo "$_resp" | grep -q '"application"'; then
    _parsed=$(printf '%s' "$_resp" | awk 'BEGIN{RS="\"instanceId\":\""} NR>1{
      id=$0; sub(/".*/,"",id); rec=$0;
      ip=""; if(match(rec,/"ipAddr":"[^"]*"/)) ip=substr(rec,RSTART+10,RLENGTH-11);
      port=""; if(match(rec,/"port":\{"\$":[0-9]+/)){s=substr(rec,RSTART,RLENGTH); sub(/.*:/,"",s); port=s}
      ver=""; if(match(rec,/"version":"[^"]*"/)) ver=substr(rec,RSTART+11,RLENGTH-12);
      sub(/ [0-9]{8}-/,".",ver);
      st=""; if(match(rec,/"status":"[^"]*"/)) st=substr(rec,RSTART+10,RLENGTH-11);
      printf "%s\t%s\t%s\t%s\t%s\n", id, ip, port, ver, st }')
    _ips_tmp=""
    while IFS="	" read -r _id _ip _port _ver _st; do
      [ -z "$_id" ] && continue
      ok "  $_id" "$_ip:$_port ($_ver, $_st)"
      [ -n "$EUREKA_JSON_MODULES" ] && EUREKA_JSON_MODULES="$EUREKA_JSON_MODULES,"
      EUREKA_JSON_MODULES="$EUREKA_JSON_MODULES{\"module\":\"$(_j "$_id")\",\"host\":\"$(_j "$_ip")\",\"port\":\"$(_j "$_port")\",\"version\":\"$(_j "$_ver")\",\"status\":\"$(_j "$_st")\"}"
      case "$_ip" in 127.*|"") : ;; *) _ips_tmp="${_ips_tmp}${_ip}
" ;; esac
    done <<EOF_EU
$_parsed
EOF_EU
    EUREKA_SERVER_COUNT=$(printf '%s' "$_ips_tmp" | sort -u | sed '/^$/d' | wc -l | tr -d ' ')
    [ -n "$EUREKA_SERVER_COUNT" ] || EUREKA_SERVER_COUNT=0
    ok "수집서버 구성" "서버 ${EUREKA_SERVER_COUNT}개 (고유 IP 기준)"

    # IP 별로 어떤 모듈이 떠 있는지 묶는다. 다중 서버 구성이면 확인서 특이사항에 그대로 넣는다
    #   — '기동 모듈 정보' 표는 스크립트를 실행한 서버 것만 담기 때문에, 나머지 서버는
    #   이 요약이 없으면 확인서 어디에도 안 남는다.
    #   instanceId 는 "host:module:port" 형태가 흔해 가운데 토큰을 모듈명으로 쓴다.
    EUREKA_BY_HOST=$(printf '%s\n' "$_parsed" | awk -F'\t' '
      $1 == "" { next }
      {
        ip = ($2 == "" ? "?" : $2); id = $1
        n = split(id, t, ":"); mod = (n >= 2 ? t[2] : id)
        if (!(ip in mods)) { order[++cnt] = ip; mods[ip] = "" }
        # 같은 모듈이 한 서버에 여러 인스턴스로 뜰 수 있어 중복 제거 (문자열 검색이
        #   아니라 키로 판단 — 구분자가 쉼표라 " mod " 검색은 빗나간다)
        if (!((ip SUBSEP mod) in seen)) {
          seen[ip SUBSEP mod] = 1
          mods[ip] = mods[ip] (mods[ip] == "" ? "" : ", ") mod
        }
      }
      END { for (i = 1; i <= cnt; i++) printf "%s%s: %s", (i > 1 ? "  /  " : ""), order[i], mods[order[i]] }')
    if [ "$EUREKA_SERVER_COUNT" -gt 1 ] 2>/dev/null; then
      warn "다중 서버 구성" "서버별 기동 모듈 — $EUREKA_BY_HOST"
      info "  └ 위 내용이 확인서 '수집서버 > 특이사항' 에 자동으로 들어갑니다"
    elif [ -n "$EUREKA_BY_HOST" ]; then
      ok "서버별 기동 모듈" "$EUREKA_BY_HOST"
    fi
  else
    warn "Eureka" "조회 실패(인증/응답 이상) — 로컬 모듈 정보만 사용"
  fi
else
  warn "Eureka" "eureka.conf 의 replicas.location 못 찾음 — 스킵"
fi

# 대시보드 포트: front.conf의 web.port, 없으면 8080
WHATAP_API_PORT=$(_conf_get "$FRONT_CONF" 'web\.port')
if [ -n "$WHATAP_API_PORT" ]; then
  ok "대시보드 포트" "$WHATAP_API_PORT ($FRONT_CONF)"
else
  WHATAP_API_PORT="8080"
  warn "대시보드 포트" "$WHATAP_API_PORT (기본값 — front.conf 내 web.port 옵션 없음)"
fi
_key_store=$(_conf_get "$FRONT_CONF" 'key_store')

# 붙여넣은 URL 다듬기: 공백·따옴표 제거, 끝 슬래시 제거, 스킴 없으면 http:// 보정
#   (끝 슬래시가 남으면 요청 경로가 //open/api/... 가 되어 앞단 프록시에서 404 가 난다)
_normalize_url() {
  local _u
  _u=$(printf '%s' "$1" | LC_ALL=C tr -d '[:space:]' | sed -e "s/^[\"']*//;s/[\"']*$//")
  while [ "${_u%/}" != "$_u" ]; do _u="${_u%/}"; done
  [ -z "$_u" ] && return 0
  case "$_u" in http://*|https://*) : ;; *) _u="http://$_u" ;; esac
  printf '%s' "$_u"
}

# URL 에서 호스트만 뽑는다 (스킴·인증정보·포트·경로 제거)
_url_host() {
  printf '%s' "$1" | sed -e 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' -e 's#^[^@]*@##' -e 's#[/?].*##' -e 's#:[0-9]*$##'
}

# 호스트가 IP 가 아니면(=도메인이면) 0
_is_domain() {
  case "$1" in
    "")        return 1 ;;
    *[!0-9.]*) return 0 ;;
    *)         return 1 ;;
  esac
}

# ── 확인서에 실릴 대시보드 주소 ─────────────────────────────────────────────
# 도메인으로 접속하는 환경이면 도메인만 적어 두면 나중에 서버를 못 찾고,
#   IP 만 적어 두면 고객이 실제로 쓰는 주소가 사라진다 → "도메인 (IP:포트)" 로 둘 다 남긴다.
#   API 호출 주소가 중간에 내부 IP 로 갈아타더라도 이 표기는 도메인을 잃지 않는다.
_URL_DOMAIN_SEEN=""
_note_url() {            # 입력/자동감지된 주소가 도메인이면 기억해 둔다
  _is_domain "$(_url_host "$1")" && _URL_DOMAIN_SEEN="$1"
  return 0
}
_display_url() {         # $1=현재 API 주소 → 확인서 표기 문자열
  if [ -z "$_URL_DOMAIN_SEEN" ]; then
    printf '%s' "$1"
  elif [ -n "${SERVER_IP:-}" ]; then
    printf '%s (%s)' "$_URL_DOMAIN_SEEN" "${SERVER_IP}:${WHATAP_API_PORT}"
  else
    printf '%s' "$_URL_DOMAIN_SEEN"
  fi
}

if [ -n "$_key_store" ]; then
  ok "SSL" "key_store 감지 ($FRONT_CONF) — HTTPS 사용"
  _API_URL_AUTO="https://${SERVER_IP}:${WHATAP_API_PORT}"
  echo ""
  read -r $_READ_E -p "  수집서버 URL (Enter=${_API_URL_AUTO}, 예: https://monitoring.example.com): " _url_input || true
  _url_input=$(_normalize_url "$_url_input")
  WHATAP_API_HOST="${_url_input:-$_API_URL_AUTO}"
  ok "수집서버 URL" "$WHATAP_API_HOST"
else
  _API_URL_AUTO="http://${SERVER_IP}:${WHATAP_API_PORT}"
  WHATAP_API_HOST="$_API_URL_AUTO"
  info "수집서버 URL (자동 감지): $WHATAP_API_HOST"
  read -r $_READ_E -p "  수집서버 URL 직접 입력 (Enter=자동 감지값 사용, 예: http://192.168.1.101:8080): " _url_input || true
  _url_input=$(_normalize_url "$_url_input")
  [ -n "$_url_input" ] && WHATAP_API_HOST="$_url_input"
  ok "수집서버 URL" "$WHATAP_API_HOST"
fi
# 확인서에 실리는 대시보드 주소는 '사람이 쓰는 주소' 로 고정한다.
#   아래에서 API 호출이 서버 내부 주소로 갈아타더라도 이 값은 따라가지 않는다
#   (앞단 도메인 환경에서 확인서에 127.0.0.1 이 박히면 문서로서 쓸모가 없다).
_note_url "$WHATAP_API_HOST"
SERVER_URL=$(_display_url "$WHATAP_API_HOST")
[ "$SERVER_URL" != "$WHATAP_API_HOST" ] && info "확인서 표기: $SERVER_URL"

# ══════════════════════════════════════════
# 4. WhaTap API: 프로젝트 목록
# ══════════════════════════════════════════
# 4. WhaTap 프로젝트 목록 조회 (로컬 서버)
# ══════════════════════════════════════════
section "WhaTap 프로젝트 목록"


# API 호출 헬퍼 (계정 토큰 기반)
call_api() {
  local path="$1" pcode="${2:-}" ptoken="${3:-}"
  local _token="${ptoken:-$WHATAP_ACCOUNT_TOKEN}"
  curl -skL ${_CURL_HTTP11} --connect-timeout 10 --max-time 30 \
    -H "Content-Type: application/json" \
    -H "x-whatap-token: $_token" \
    ${pcode:+-H "x-whatap-pcode: $pcode"} \
    "$WHATAP_API_HOST${path}" 2>/dev/null || echo ""
}

# ── 제품별 에이전트 목록 조회 ───────────────────────────────────────────────
# 호출이 실패하면 응답이 빈 문자열이라, 그대로 세면 '에이전트 0대' 와 구분되지 않는다.
#   → 확인서에 "미설치/0대" 로 잘못 박히고, 그 프로젝트가 그 제품의 유일한 프로젝트였다면
#     제품 섹션이 통째로 빠져 '해당 제품 없음' 으로 읽힌다. 빈 확인서보다 나쁘다.
#   상태코드까지 받아 '조회 실패' 와 '진짜 0대' 를 구분하고, 일시적 실패(연결 실패·5xx)는
#   자동으로 몇 번 더 걸어 본다. 프로젝트 수만큼 반복되는 호출이라 여기서는 사람에게
#   되묻지 않는다 (한 번만 묻는 계정 토큰 단계와 다른 점).
# 결과: _AG_RESP=본문 / _AG_HTTP=상태코드(빈 값이면 연결 실패) / _AG_FAIL=1 이면 조회 실패
_AGENTS_TRY_MAX=3        # 총 시도 횟수(첫 호출 포함)
_AGENTS_RETRY_WAIT=2     # 재시도 간격(초)
_AGENT_QUERY_FAIL=""     # "APM/95(HTTP 000)" 누적 — 실패 사실을 JSON 까지 끌고 간다
_APM_QFAIL=0; _SMS_QFAIL=0; _DPM_QFAIL=0; _CPM_QFAIL=0
fetch_agents() {         # $1=pcode  $2=projectToken  $3=제품명(로그·기록용)
  local _pc="$1" _tk="$2" _prod="${3:-?}" _try=0 _raw=""
  _AG_RESP=""; _AG_HTTP=""; _AG_FAIL=0
  while [ "$_try" -lt "$_AGENTS_TRY_MAX" ]; do
    _try=$(( _try + 1 ))
    _raw=$(curl -skL ${_CURL_HTTP11} -w "\n__HTTP_STATUS__%{http_code}" \
      --connect-timeout 10 --max-time 30 \
      -H "x-whatap-token: $_tk" \
      -H "x-whatap-pcode: $_pc" \
      "$WHATAP_API_HOST/open/api/json/project/agents" 2>/dev/null || echo "")
    _AG_HTTP=$(printf '%s' "$_raw" | grep -o '__HTTP_STATUS__[0-9]*' | grep -o '[0-9]*')
    _AG_RESP=$(printf '%s' "$_raw" | sed 's/__HTTP_STATUS__[0-9]*//')
    [ "$_AG_HTTP" = "200" ] && return 0
    case "${_AG_HTTP:-}" in
      ""|000|5??)   # 연결 실패·서버 오류는 일시적일 수 있다 → 자동 재시도
        if [ "$_try" -lt "$_AGENTS_TRY_MAX" ]; then
          warn "  └ ${_prod} 조회 실패" "HTTP ${_AG_HTTP:-연결실패} (${_try}/${_AGENTS_TRY_MAX}) — ${_AGENTS_RETRY_WAIT}초 후 재시도"
          sleep "$_AGENTS_RETRY_WAIT"
          continue
        fi ;;
      *) break ;;   # 4xx(토큰·권한·경로) 는 다시 걸어도 같은 답 — 즉시 포기
    esac
  done
  _AG_FAIL=1
  _AGENT_QUERY_FAIL="${_AGENT_QUERY_FAIL}${_AGENT_QUERY_FAIL:+, }${_prod}/${_pc}(HTTP ${_AG_HTTP:-연결실패})"
  return 1
}

# 프로젝트 목록 1회 조회 → HTTP_STATUS / PROJECTS / _FETCH_ERR
_fetch_projects() {
  local _err _resp
  _err=$(mktemp)
  _resp=$(curl -skL ${_CURL_HTTP11} -w "\n__HTTP_STATUS__%{http_code}" --connect-timeout 10 --max-time 30 \
    -H "Content-Type: application/json" \
    -H "x-whatap-token: $WHATAP_ACCOUNT_TOKEN" \
    "$WHATAP_API_HOST/open/api/json/projects" 2>"$_err" || echo "")
  _FETCH_ERR=$(head -c 300 "$_err" 2>/dev/null)
  rm -f "$_err"
  HTTP_STATUS=$(echo "$_resp" | grep -o '__HTTP_STATUS__[0-9]*' | grep -o '[0-9]*')
  PROJECTS=$(echo "$_resp" | sed 's/__HTTP_STATUS__[0-9]*//')
}

# ── 연결 실패 진단 / 서버 내부 주소로 자동 전환 ─────────────────────────────
# 앞단에 도메인을 붙여 둔 환경(밖에서는 https 도메인, 안에서는 front 8080)에서는
#   밖에서 쓰는 대시보드 주소를 그대로 넣어도 정작 수집서버 안에서는 그 도메인이
#   안 풀리거나(내부 DNS 없음) 방화벽에 막혀 접속이 안 된다.
#   예전에는 여기서 'HTTP 000' 만 찍고 넘어가 프로젝트·에이전트가 통째로 빈 확인서가
#   나왔고, 보고서 화면에서는 "토큰이 잘못됐다" 로 읽혀 원인을 엉뚱한 데서 찾게 됐다.
#   → 연결 자체가 안 되면 토큰을 다시 묻기 전에 URL 부터 의심한다:
#     이름이 풀리는지 알려 주고, 같은 서버에서 직접 닿는 주소로 갈아타 본다.

# 도메인이 이 서버에서 풀리는지 확인 — 연결 실패의 제일 흔한 원인이라 먼저 짚는다
_dns_hint() {
  local _h _ip=""
  _h=$(_url_host "$1")
  _is_domain "$_h" || return 0          # IP 로 넣었으면 이름 확인할 것 없음
  if command -v getent >/dev/null 2>&1; then
    _ip=$(getent hosts "$_h" 2>/dev/null | head -1 | awk '{print $1}')
  fi
  if [ -z "$_ip" ] && command -v host >/dev/null 2>&1; then
    _ip=$(host "$_h" 2>/dev/null | awk '/has address/{print $NF; exit}')
  fi
  if [ -z "$_ip" ] && command -v nslookup >/dev/null 2>&1; then
    _ip=$(nslookup "$_h" 2>/dev/null | awk '/^Address: /{print $2; exit}')
  fi
  if [ -z "$_ip" ] && command -v ping >/dev/null 2>&1; then
    _ip=$(ping -c 1 -W 1 "$_h" 2>/dev/null | head -1 | sed -n 's/.*(\([0-9.]*\)).*/\1/p')
  fi
  if [ -n "$_ip" ]; then
    info "  └ DNS: $_h → $_ip"
  else
    warn "  └ DNS 조회 실패" "$_h"
  fi
}

# 후보 URL 로 프로젝트 목록을 한 번 걸어 보고 상태코드만 돌려준다 (연결 실패면 000)
#   '|| echo 000' 으로 실패를 보정하면 안 된다 — curl 이 이미 %{http_code} 로 000 을
#   찍은 뒤 종료코드 0 이 아니라서 "000000" 이 되고, 연결 실패가 '응답 왔음'으로
#   잘못 분류된다. 종료코드는 무시하고 출력에서 숫자 3자리만 뽑는다.
_probe_api_url() {
  local _c
  _c=$(curl -skL ${_CURL_HTTP11} -o /dev/null -w '%{http_code}' \
    --connect-timeout 5 --max-time 10 \
    -H "Content-Type: application/json" \
    -H "x-whatap-token: $WHATAP_ACCOUNT_TOKEN" \
    "$1/open/api/json/projects" 2>/dev/null) || true
  _c=$(printf '%s' "$_c" | LC_ALL=C tr -dc '0-9' | sed 's/.*\(...\)$/\1/')
  printf '%s' "${_c:-000}"
}

# 같은 서버에서 직접 닿는 주소를 찾아 'API 호출 주소'만 그쪽으로 돌린다 (성공 시 0).
#   확인서에 실리는 주소($SERVER_URL)는 입력한 도메인 그대로 둔다 — 여기서 건드리지 않는다.
_URL_FALLBACK_DONE=0
_try_local_api_urls() {
  local _cand _code _tried=" $WHATAP_API_HOST " _reachable="" _rcode=""
  info "  └ 내부 IP(${SERVER_IP:-127.0.0.1}:${WHATAP_API_PORT})로 재시도"
  for _cand in "http://${SERVER_IP}:${WHATAP_API_PORT}" "https://${SERVER_IP}:${WHATAP_API_PORT}" \
               "http://127.0.0.1:${WHATAP_API_PORT}" "https://127.0.0.1:${WHATAP_API_PORT}"; do
    case "$_tried" in *" $_cand "*) continue ;; esac
    _tried="${_tried}${_cand} "
    _code=$(_probe_api_url "$_cand")
    case "$_code" in
      200) WHATAP_API_HOST="$_cand"
           ok "조회 주소" "$_cand"
           return 0 ;;
      000) info "     · $_cand → 연결 실패" ;;
      *)   info "     · $_cand → HTTP $_code"
           [ -z "$_reachable" ] && { _reachable="$_cand"; _rcode="$_code"; } ;;
    esac
  done
  # 200 은 아니지만 응답이 오는 주소가 있으면 그쪽으로 옮긴다.
  #   '연결 안 됨' 과 '연결은 되는데 거부됨' 은 사람이 볼 원인이 완전히 다르다.
  if [ -n "$_reachable" ]; then
    WHATAP_API_HOST="$_reachable"
    warn "조회 주소" "$_reachable (HTTP $_rcode)"
    return 0
  fi
  return 1
}

# 실패 원인을 상태코드별로 짚어 준다 (무엇을 고쳐 재입력할지 알 수 있게)
_api_fail_hint() {
  case "${HTTP_STATUS:-}" in
    401|403) fail "프로젝트 목록" "HTTP $HTTP_STATUS — 토큰이 거부됐습니다 (Admin 계정 API 토큰이 맞는지 / 만료·재발급 여부 확인)" ;;
    404)     fail "프로젝트 목록" "HTTP 404 — 경로 없음 (수집서버 URL 이 대시보드 주소가 맞는지 확인)" ;;
    ""|000)  fail "프로젝트 목록" "연결 실패 — $WHATAP_API_HOST"
             [ -n "${_FETCH_ERR:-}" ] && warn "curl 오류" "$_FETCH_ERR"
             _dns_hint "$WHATAP_API_HOST" ;;
    5??)     fail "프로젝트 목록" "HTTP $HTTP_STATUS — 수집서버 오류 (front 모듈 상태 확인)" ;;
    *)       fail "프로젝트 목록" "HTTP $HTTP_STATUS — $WHATAP_API_HOST/open/api/json/projects" ;;
  esac
  [ -n "${PROJECTS:-}" ] && warn "응답 원문" "$(echo "$PROJECTS" | head -c 300)"
}

# ── 프로젝트 목록: 성공할 때까지 재시도 ─────────────────────────────────────
# 여기서 실패하면 확인서의 절반(프로젝트·에이전트 정보)이 통째로 비어 나온다.
#   한 번 실패하고 넘어가지 말고, 토큰(또는 URL)을 다시 받아 성공할 때까지 되묻는다.
#   빠져나가는 길: skip 입력 / Ctrl+C / 입력 불가(EOF)
API_OK="false"; PROJ_COUNT=0; HTTP_STATUS=""; PROJECTS=""
_api_try=0
while : ; do
  _api_try=$(( _api_try + 1 ))
  if [ -n "$WHATAP_ACCOUNT_TOKEN" ]; then
    ok "Admin 계정 API 토큰" "${WHATAP_ACCOUNT_TOKEN:0:8}... (길이 ${#WHATAP_ACCOUNT_TOKEN})"
    info "프로젝트 목록 조회 (${_api_try}회차): $WHATAP_API_HOST/open/api/json/projects"
    _fetch_projects
    if [ "$HTTP_STATUS" = "200" ]; then
      PROJ_COUNT=$(echo "$PROJECTS" | grep -o '"projectCode"' | wc -l | tr -d ' ')
      if [ "${PROJ_COUNT:-0}" -gt 0 ] 2>/dev/null; then
        API_OK="true"
        ok "프로젝트 목록" "${PROJ_COUNT}개 조회"
        echo "$PROJECTS" | tr '{' '\n' | grep '"projectCode"' | while IFS= read -r proj; do
          pcode=$(echo "$proj" | grep -o '"projectCode"[^,}]*' | grep -o '[0-9]\+')
          ptype=$(echo "$proj" | grep -o '"productType":"[^"]*"' | cut -d'"' -f4)
          name=$(echo "$proj"  | grep -o '"projectName":"[^"]*"' | cut -d'"' -f4)
          printf "    pcode=%-8s [%-15s] %s\n" "$pcode" "$ptype" "$name"
        done
        echo ""
        break
      fi
      warn "프로젝트 목록" "HTTP 200 이지만 프로젝트가 0개 — 다른 계정의 토큰일 수 있습니다"
      warn "응답 원문" "$(echo "$PROJECTS" | head -c 500)"
    else
      _api_fail_hint
      # 연결 자체가 안 됐으면 토큰이 아니라 주소 문제다 — 사람에게 되묻기 전에
      #   서버 내부 주소로 한 번 갈아타 본다 (한 번만: 실패하면 그때 물어본다)
      case "${HTTP_STATUS:-}" in
        ""|000)
          if [ "${_URL_FALLBACK_DONE:-0}" = "0" ]; then
            _URL_FALLBACK_DONE=1
            if _try_local_api_urls; then echo ""; continue; fi
            warn "조회 주소" "닿는 주소 없음"
          fi ;;
      esac
    fi
  else
    fail "Admin 계정 API 토큰" "입력 없음 — 프로젝트 목록 조회 불가"
  fi

  echo ""
  # 마지막 실패가 '연결 실패' 면 토큰을 다시 받는 게 아무 소용이 없다 — 안내를 바꾼다
  case "${HTTP_STATUS:-}" in
    ""|000)
      echo -e "  ${YELLOW}▶ 수집서버 접속 실패 — 주소 확인 필요${NC} (내부 주소 예: ${CYAN}${_API_URL_AUTO:-http://${SERVER_IP}:${WHATAP_API_PORT}}${NC})" ;;
    *)
      echo -e "  ${YELLOW}▶ 조회에 실패했습니다. Admin 계정 API 토큰을 다시 붙여넣어 주세요.${NC}"
      echo -e "    (앞뒤 공백·줄바꿈·따옴표는 자동으로 걷어냅니다)" ;;
  esac
  echo -e "    ${CYAN}Enter${NC}=지금 값 그대로 재시도   ${CYAN}url${NC}=수집서버 URL 다시 입력   ${CYAN}skip${NC}=API 없이 계속(비권장)"
  _read_token "  Admin 계정 API 토큰(재입력): "
  if [ "${_TOKEN_EOF:-0}" = "1" ]; then
    warn "재시도 중단" "더 이상 입력을 받을 수 없어(EOF) API 없이 진행합니다"
    break
  fi
  case "$_TOKEN_IN" in
    [Ss][Kk][Ii][Pp])
      [ "$HTTP_STATUS" = "200" ] && API_OK="true"
      warn "API 조회" "건너뜁니다 — 프로젝트·에이전트 정보가 빈 채로 확인서가 만들어집니다"
      break ;;
    [Uu][Rr][Ll])
      read -r $_READ_E -p "  수집서버 URL (예: http://192.168.1.101:8080): " _url_input || _url_input=""
      _url_input=$(_normalize_url "$_url_input")
      if [ -n "$_url_input" ]; then
        WHATAP_API_HOST="$_url_input"
        _note_url "$WHATAP_API_HOST"
        # 도메인을 넣었다가 내부 IP 로 바꿔 넣은 경우에도 확인서에는 둘 다 남는다
        SERVER_URL=$(_display_url "$WHATAP_API_HOST")
        _URL_FALLBACK_DONE=0              # 주소가 바뀌었으니 자동 전환도 다시 허용
        ok "수집서버 URL" "$WHATAP_API_HOST"
        [ "$SERVER_URL" != "$WHATAP_API_HOST" ] && info "확인서 표기: $SERVER_URL"
      fi ;;
    "")
      info "같은 값으로 재시도합니다" ;;
    *)
      WHATAP_ACCOUNT_TOKEN="$_TOKEN_IN"
      _token_report "$WHATAP_ACCOUNT_TOKEN" ;;
  esac
  echo ""
done

if [ "$API_OK" != "true" ]; then
  PROJECTS='[]'
  PROJ_COUNT=0
fi
API_HTTP_STATUS="${HTTP_STATUS:-}"
: "${API_OK:=false}" ; : "${PROJ_COUNT:=0}"

# 실패 사유를 코드로 남긴다. 보고서 생성 화면이 이걸 보고 안내를 고른다 —
#   connect(연결 실패) 를 '토큰이 잘못됐다' 로 안내하면 엉뚱한 데를 고치게 된다.
API_FAIL_REASON=""
if [ "$API_OK" != "true" ]; then
  if [ -z "$WHATAP_ACCOUNT_TOKEN" ]; then
    API_FAIL_REASON="notoken"
  else
    case "${API_HTTP_STATUS:-}" in
      200)      API_FAIL_REASON="empty" ;;     # 응답은 정상인데 프로젝트가 0개
      401|403)  API_FAIL_REASON="auth" ;;
      404)      API_FAIL_REASON="notfound" ;;
      ""|000)   API_FAIL_REASON="connect" ;;
      5??)      API_FAIL_REASON="server" ;;
      *)        API_FAIL_REASON="http" ;;
    esac
  fi
fi
API_URL_USED="$WHATAP_API_HOST"    # 실제로 호출한 주소(자동 전환됐을 수 있다)

# pcode / 토큰 추출 헬퍼 (grep/sed 기반)
get_pcode() {
  local ptype="$1"
  echo "$PROJECTS" | tr '{' '\n' | grep -i "\"$ptype\"" \
    | grep -o '"projectCode"[^,}]*' | grep -o '[0-9]\+' | head -1
}

get_api_token() {
  local ptype="$1"
  echo "$PROJECTS" | tr '{' '\n' | grep -i "\"$ptype\"" \
    | grep -o '"apiToken":"[^"]*"' | cut -d'"' -f4 | head -1
}

# ── Self 모니터링 검사 (로컬 프로세스 기반 — 제품 검사 전에 수행) ─────────────
section "Self 모니터링 검사"

# APM self install: 각 수집서버 모듈 프로세스에 -javaagent 옵션 확인
info "APM self 설치 확인 중 (수집서버 모듈 -javaagent 검사)..."
APM_SELF_INSTALLED="미설치"
_apm_self_found=0
_apm_self_missing=""
for _mod in front account notihub eureka gateway yard proxy keeper router flexreport; do
  _has=$(ps -efww 2>/dev/null | grep -v grep | grep "whatap.server.${_mod}" | grep "\-javaagent" 2>/dev/null | wc -l | tr -d ' ')
  if [ "${_has:-0}" -gt 0 ] 2>/dev/null; then
    _apm_self_found=$(( _apm_self_found + 1 ))
  else
    # 해당 모듈 프로세스가 아예 없으면 skip (미기동 모듈은 체크 불필요)
    _running=$(ps -efww 2>/dev/null | grep -v grep | grep "whatap.server.${_mod}" 2>/dev/null | wc -l | tr -d ' ')
    if [ "${_running:-0}" -gt 0 ] 2>/dev/null; then
      _apm_self_missing="${_apm_self_missing}${_mod} "
    fi
  fi
done
# 하나라도 -javaagent가 적용돼 있으면 '설치'로 판정 (일부 미적용 모듈은 참고 표기)
if [ "$_apm_self_found" -gt 0 ]; then
  if [ -z "$_apm_self_missing" ]; then
    APM_SELF_INSTALLED="설치"
    ok "APM Self 설치" "설치 (${_apm_self_found}개 모듈 -javaagent 확인)"
  else
    _apm_self_missing=$(echo "$_apm_self_missing" | xargs | tr ' ' ',')
    APM_SELF_INSTALLED="설치 (미적용: ${_apm_self_missing})"
    ok "APM Self 설치" "설치 (${_apm_self_found}개 확인, 미적용: ${_apm_self_missing})"
  fi
else
  APM_SELF_INSTALLED="미설치"
  warn "APM Self 설치" "$APM_SELF_INSTALLED"
fi

# SMS self install: whatap_infrad 프로세스 확인 (foreground 또는 watchdog)
info "SMS self 설치 확인 중 (whatap_infrad 프로세스)..."
SMS_SELF_INSTALLED="미설치"
_infrad_cnt=$(ps -efww 2>/dev/null | grep "whatap_infrad" | grep -v grep | wc -l | tr -d ' ')
if [ "${_infrad_cnt:-0}" -gt 0 ] 2>/dev/null; then
  SMS_SELF_INSTALLED="설치"
  ok "SMS Self 설치" "설치 (whatap_infrad 프로세스 확인)"
else
  warn "SMS Self 설치" "미설치 (whatap_infrad 프로세스 없음)"
fi

# ── API로 에이전트 존재 여부 확인 후 조건부 사용자 입력 ──────────────────────
section "에이전트 추가 정보 입력 (API 조회 기반)"

# grep -c 는 매칭 0건이어도 "0"을 출력(그리고 exit 1)하므로 '|| echo 0'을 붙이면
# "0\n0" 이 되어 뒤쪽 JSON $(( )) 산술에서 "operator expected" 에러가 난다. 붙이지 않는다.
_has_apm=$(echo "$PROJECTS" | grep -ic '"APM"')
_has_sms=$(echo "$PROJECTS" | grep -ic '"SMS"')
_has_dpm=$(echo "$PROJECTS" | grep -i '"DB"' 2>/dev/null | wc -l | tr -d ' ')
_has_cpm=$(echo "$PROJECTS" | grep -ic '"CPM"')
_has_rum=$(echo "$PROJECTS" | tr '{' '\n' | grep -c '"productType":"BROWSER"')
# URL 모니터링: 계정/버전에 따라 productType 이 WPM 또는 URL 로 내려온다
_has_wpm=$(echo "$PROJECTS" | tr '{' '\n' | grep -cE '"productType":"(WPM|URL)"')

if [ "${_has_apm:-0}" -gt 0 ] 2>/dev/null; then
  info "APM 프로젝트 감지 — APM 에이전트 정보 입력"
  read -r $_READ_E -p "  APM 에이전트 설치 경로 (없으면 Enter): " APM_INSTALL_PATH
  read -r $_READ_E -p "  APM 기동 계정 (없으면 Enter): " APM_RUN_USER
  read -r $_READ_E -p "  APM 파일 소유자 (소유자:그룹, 예: root:root, 없으면 Enter): " APM_FILE_OWNER
  read -r $_READ_E -p "  APM 시작점 옵션 적용 여부 (적용/미적용, 설정값 있으면 함께 기입, 없으면 Enter): " APM_START_POINT
  read -r $_READ_E -p "  APM weaving 옵션 적용 여부 (적용/미적용, 설정값 있으면 함께 기입, 없으면 Enter): " APM_WEAVING

else
  info "APM 프로젝트 없음 — APM 입력 생략"
fi

if [ "${_has_dpm:-0}" -gt 0 ] 2>/dev/null; then
  info "DPM 프로젝트 감지 — DPM 에이전트 정보 입력"
  # 수집서버에 dbx(DPM 에이전트) 프로세스가 떠있으면 경로·기동계정 자동 탐지
  _dpm_proc=$(ps -efww 2>/dev/null | grep -v grep | grep -i "dbx" | head -1 || echo "")
  if [ -n "$_dpm_proc" ]; then
    _dpm_pid=$(echo "$_dpm_proc" | awk '{print $2}')
    DPM_RUN_USER=$(echo "$_dpm_proc" | awk '{print $1}')
    DPM_INSTALL_PATH=$(readlink -f "/proc/$_dpm_pid/cwd" 2>/dev/null || echo "")
    DPM_INSTALL_PATH="${DPM_INSTALL_PATH%/bin}"
    [ -n "$DPM_INSTALL_PATH" ] && ok "DPM 설치 경로 (자동 탐지: dbx 프로세스)" "$DPM_INSTALL_PATH"
    [ -n "$DPM_RUN_USER" ] && ok "DPM 기동 계정 (자동 탐지)" "$DPM_RUN_USER"
  fi
  [ -z "$DPM_INSTALL_PATH" ] && read -r $_READ_E -p "  DPM 에이전트 설치 경로 (없으면 Enter): " DPM_INSTALL_PATH
  [ -z "$DPM_RUN_USER" ] && read -r $_READ_E -p "  DPM 기동 계정 (없으면 Enter): " DPM_RUN_USER
  [ -n "$DPM_INSTALL_PATH" ] && DPM_FILE_OWNER=$(_owner_of "$DPM_INSTALL_PATH")
  [ -z "$DPM_FILE_OWNER" ] && read -r $_READ_E -p "  DPM 파일 소유자 (소유자:그룹, 예: root:root, 없으면 Enter): " DPM_FILE_OWNER
  if [ -n "$DPM_INSTALL_PATH" ]; then
    DPM_FILE_PERM=$(stat -c '%a' "$DPM_INSTALL_PATH" 2>/dev/null || echo "")
    [ -n "$DPM_FILE_PERM" ] && ok "DPM 디렉터리 권한" "$DPM_FILE_PERM"
  fi
else
  info "DPM 프로젝트 없음 — DPM 입력 생략"
fi

if [ "${_has_sms:-0}" -gt 0 ] 2>/dev/null; then
  info "SMS 프로젝트 감지 — SMS 에이전트 설치 경로 확인"
  read -r $_READ_E -p "  SMS 설치 경로가 기본 경로(${SMS_DEFAULT_PATH})입니까? (Enter=예 / n=아니오): " _sms_def_ans || true
  case "$_sms_def_ans" in
    n|N|아니오)
      read -r $_READ_E -p "  실제 SMS 설치 경로: " SMS_INSTALL_PATH || true
      [ -z "$SMS_INSTALL_PATH" ] && SMS_INSTALL_PATH="$SMS_DEFAULT_PATH"
      ;;
    *) SMS_INSTALL_PATH="$SMS_DEFAULT_PATH" ;;
  esac
  SMS_INSTALL_PATH="${SMS_INSTALL_PATH%/}"
  SMS_LOG_PATH="$SMS_INSTALL_PATH/logs"
  ok "SMS 설치 경로" "$SMS_INSTALL_PATH"
  ok "SMS 로그 경로" "$SMS_LOG_PATH"
else
  info "SMS 프로젝트 없음 — SMS 입력 생략"
fi

if [ "${_has_cpm:-0}" -gt 0 ] 2>/dev/null; then
  info "CPM 프로젝트 감지 — 설치 방식 자동 확인 중 (operator 이미지 조회)..."
  # 먼저 whatap-operator 이미지 자동 감지 → 있으면 Operator 방식 확정, 없으면 수동 선택
  _op_stime=$(( $(date +%s) * 1000 - 300000 )); _op_etime=$(( $(date +%s) * 1000 ))
  while IFS= read -r _cp; do
    [ -n "$CPM_OPERATOR_VERSION" ] && break
    _cpc=$(echo "$_cp" | grep -o '"projectCode"[^,}]*' | grep -o '[0-9]\+')
    _cpt=$(echo "$_cp" | grep -o '"apiToken":"[^"]*"' | cut -d'"' -f4)
    [ -z "$_cpc" ] || [ -z "$_cpt" ] && continue
    _ci=$(curl -skL ${_CURL_HTTP11} --connect-timeout 10 --max-time 30 \
      -X POST "$WHATAP_API_HOST/open/api/json/mxql/text" \
      -H "Content-Type: application/json" -H "x-whatap-token: $_cpt" -H "x-whatap-pcode: $_cpc" \
      -d "{\"stime\":${_op_stime},\"etime\":${_op_etime},\"mql\":\"CATEGORY container\\nTAGLOAD\\nSELECT\",\"limit\":500}" 2>/dev/null || echo "")
    _oi=$(echo "$_ci" | tr '{' '\n' | grep '"namespace":"whatap-monitoring"' \
      | grep -o '"image":"[^"]*whatap-operator[^"]*"' | head -1 | cut -d'"' -f4)
    _ov=$(echo "$_oi" | grep -o ':[^:]*$' | tr -d ':')
    [ -n "$_ov" ] && CPM_OPERATOR_VERSION="$_ov"
  done < <(echo "$PROJECTS" | tr '{' '\n' | grep -i '"CPM"' || true)

  if [ -n "$CPM_OPERATOR_VERSION" ]; then
    CPM_INSTALL_METHOD="Operator"
    ok "CPM 설치 방식 (자동)" "Operator — operator 이미지 감지 (버전 ${CPM_OPERATOR_VERSION})"
  else
    echo "  1) Operator  2) Yaml  3) Helm  Enter) 생략"
    read -r $_READ_E -p "  CPM 설치 방식 선택 [1-3]: " _cpm_choice || true
    case "$_cpm_choice" in
      1) CPM_INSTALL_METHOD="Operator" ;;
      2) CPM_INSTALL_METHOD="Yaml" ;;
      3) CPM_INSTALL_METHOD="Helm" ;;
      *) CPM_INSTALL_METHOD="" ;;
    esac
    [ -n "$CPM_INSTALL_METHOD" ] && ok "CPM 설치 방식" "$CPM_INSTALL_METHOD"
    # Yaml 방식은 설치 위치를 수기 입력
    if [ "$CPM_INSTALL_METHOD" = "Yaml" ]; then
      read -r $_READ_E -p "  CPM(Yaml) 설치 위치 (없으면 Enter): " CPM_INSTALL_PATH || true
    fi
  fi
else
  info "CPM 프로젝트 없음 — CPM 입력 생략"
fi

# 설치 서버/위치 입력. 결과는 전역 _ANS_SRV/_ANS_PATH 로 반환한다.
#   $2 = "fixed" 면 수집서버로 고정하고 서버는 묻지 않는다(경로만 입력).
#   (탭 구분 문자열로 반환하면 안 됨: 탭은 IFS whitespace 라서 서버명을 빈 채로
#    Enter 치면 선행 탭이 스킵되어 경로가 서버 변수로 밀려 들어간다.)
_ANS_SRV=""; _ANS_PATH=""
_ask_server_path() {
  local label="$1" fixed="${2:-}" same srv path
  srv=""; path=""
  if [ "$fixed" = "fixed" ]; then
    srv="수집서버(${SERVER_IP})"
  else
    read -r $_READ_E -p "  ${label} 설치 서버가 수집서버(현재 서버 ${SERVER_IP})와 동일합니까? (Enter=예 / n=아니오): " same || true
    case "$same" in n|N|아니오) same="n" ;; *) same="y" ;; esac
    if [ "$same" = "y" ]; then
      srv="수집서버(${SERVER_IP})"
    else
      read -r $_READ_E -p "  ${label} 설치 서버: " srv || true
    fi
  fi
  read -r $_READ_E -p "  ${label} 설치 위치: " path || true
  _ANS_SRV="$srv"; _ANS_PATH="$path"
}

# 예/아니오 질문 → 보고서 라디오가 인식하는 두 값 중 하나로 변환한다.
#   예전엔 "(적용/미적용)" 처럼 값을 직접 받아, y 나 Y 를 치면 그 글자가 그대로
#   문서에 찍혔다(라디오는 정확히 "적용"/"미적용" 일 때만 ● 을 켠다).
#   $1=질문  $2=Enter 일 때 값  $3=n 일 때 값  → _ANS_YN
_ask_yn() {
  local a
  read -r $_READ_E -p "  $1 (Enter=$2 / n=$3): " a || true
  case "$a" in n|N|아니오) _ANS_YN="$3" ;; *) _ANS_YN="$2" ;; esac
}

if [ "${_has_rum:-0}" -gt 0 ] 2>/dev/null; then
  info "RUM(브라우저 모니터링) 프로젝트 감지 (${_has_rum}개) — RUM 정보 입력"
  read -r $_READ_E -p "  rum-onpremise-pkg 버전 (없으면 Enter): " RUM_VERSION
  # RUM 은 구성요소마다 설치 위치가 다를 수 있어 rumctl 과 rumproxy/rumagent 를 따로 받는다.
  #   rumctl 은 keeper 가 관리하는 서버 컴포넌트라(worker_server_info 에 yard·dbctl·agency
  #   와 함께 등록) 항상 수집서버에 깔린다 → 서버는 묻지 않고 경로만 받는다.
  _ask_server_path "rumctl" fixed;      RUM_CTL_SERVER="$_ANS_SRV";   RUM_CTL_PATH="$_ANS_PATH"
  _ask_server_path "rumproxy/rumagent"; RUM_PROXY_SERVER="$_ANS_SRV"; RUM_PROXY_PATH="$_ANS_PATH"
  # 구 템플릿({r_server}/{r_installPath})이 빈칸으로 나가지 않도록 rumctl 값을 레거시 키에도 채운다
  RUM_SERVER="$RUM_CTL_SERVER"; RUM_INSTALL_PATH="$RUM_CTL_PATH"
  read -r $_READ_E -p "  RUM 적용 사이트/도메인 (없으면 Enter): " RUM_SITE
  read -r $_READ_E -p "  엣지 서버 도메인 (없으면 Enter): " RUM_EDGE_DOMAIN
  _ask_yn "엣지 서버 SSL 설정"        "적용" "미적용";  RUM_EDGE_SSL="$_ANS_YN"
  _ask_yn "스크립트 삽입 가이드 제공"  "제공" "미제공";  RUM_SCRIPT_GUIDE="$_ANS_YN"
else
  info "RUM(브라우저 모니터링) 프로젝트 없음 — RUM 입력 생략"
fi

if [ "${_has_wpm:-0}" -gt 0 ] 2>/dev/null; then
  info "URL 모니터링 프로젝트 감지 (${_has_wpm}개) — URL 모니터링 정보 입력"
  _ask_server_path "URL 모니터링"; WPM_SERVER="$_ANS_SRV"; WPM_INSTALL_PATH="$_ANS_PATH"
  read -r $_READ_E -p "  webcheck 버전 (없으면 Enter): " WPM_VERSION

  # ── 등록 URL 수 자동 조회 (url_check 지표) ──
  #   region_name 이 태그라 URL 1개가 체크 리전 수만큼 행으로 나온다
  #   → 행을 세면 안 되고 pk 인 request_id 를 distinct 로 세야 한다.
  #   지표 기반이라 "최근 1시간 내 실제 체크된 URL" 이며, 미기동·일시중지 URL 은 빠진다.
  #   (등록 설정 원본 /wc/v3/... 은 콘솔 세션 API 라 open API 토큰으로 접근 불가)
  _wpm_auto=0
  _u_stime=$(( $(date +%s) * 1000 - 3600000 )); _u_etime=$(( $(date +%s) * 1000 ))
  _u_mql="CATEGORY url_check\nTIME-RANGE {recent: 1h}\nTAGLOAD {backward: true}\nSELECT"
  while IFS= read -r _wp; do
    [ -z "$_wp" ] && continue
    _wpc=$(echo "$_wp" | grep -o '"projectCode"[^,}]*' | grep -o '[0-9]\+')
    _wpt=$(echo "$_wp" | grep -o '"apiToken":"[^"]*"' | cut -d'"' -f4)
    { [ -z "$_wpc" ] || [ -z "$_wpt" ]; } && continue
    _ur=$(curl -skL ${_CURL_HTTP11} --connect-timeout 10 --max-time 30 \
      -X POST "$WHATAP_API_HOST/open/api/json/mxql/text" \
      -H "Content-Type: application/json" \
      -H "x-whatap-token: $_wpt" -H "x-whatap-pcode: $_wpc" \
      -d "{\"stime\":${_u_stime},\"etime\":${_u_etime},\"mql\":\"${_u_mql}\",\"limit\":1000}" 2>/dev/null || echo "")
    # request_id 는 문자열/숫자 어느 쪽으로도 올 수 있어 둘 다 받는다
    _uc=$(echo "$_ur" | tr '{' '\n' \
      | grep -oE '"request_id":("[^"]*"|[0-9]+)' | sed 's/.*://; s/"//g' \
      | grep -v '^$' | sort -u | grep -c . || true)
    if [ "${_uc:-0}" -gt 0 ] 2>/dev/null; then
      ok "  └ 등록 URL [pcode $_wpc]" "${_uc}개 (최근 1시간 체크 기준)"
      _wpm_auto=$(( _wpm_auto + _uc ))
    else
      warn "  └ 등록 URL [pcode $_wpc]" "url_check 데이터 없음 — 응답: $(echo "$_ur" | head -c 200)"
    fi
  done << _WPM_EOF
$(echo "$PROJECTS" | tr '{' '\n' | grep -E '"productType":"(WPM|URL)"' || true)
_WPM_EOF

  if [ "$_wpm_auto" -gt 0 ] 2>/dev/null; then
    ok "등록 URL 수 (자동 집계)" "${_wpm_auto}개"
  fi
  read -r $_READ_E -p "  등록 URL 수${_wpm_auto:+ [Enter=${_wpm_auto}]}: " WPM_URL_COUNT || true
  [ -z "$WPM_URL_COUNT" ] && [ "$_wpm_auto" -gt 0 ] 2>/dev/null && WPM_URL_COUNT="$_wpm_auto"
else
  info "URL 모니터링 프로젝트 없음 — URL 모니터링 입력 생략"
fi

# ══════════════════════════════════════════
# 5. 에이전트 버전 수집
# ══════════════════════════════════════════
section "에이전트 버전 수집"

# 파일명에서 버전 추출 헬퍼 (예: whatap.agent-2.3.1.jar → 2.3.1)
extract_version() {
  echo "$1" | grep -o '[0-9]\+\.[0-9]\+\.[0-9][0-9a-zA-Z._-]*' | sed 's/\.jar$//;s/\.tar\.gz$//' | head -1
}

# 파일 탐색 + 버전 출력 헬퍼
find_agent_jar() {
  local pattern="$1" label="$2"
  local found
  found=$(find / -maxdepth 10 -name "$pattern" 2>/dev/null | head -1)
  if [ -n "$found" ]; then
    local ver
    ver=$(extract_version "$(basename "$found")")
    if [ -n "$ver" ]; then
      ok "$label 버전" "$ver ($(basename "$found"))"
    else
      warn "$label 버전" "파일 발견됐으나 버전 파싱 실패: $(basename "$found")"
    fi
    echo "$ver"
  else
    warn "$label 버전" "$pattern 파일 없음"
    echo ""
  fi
}

UPDATE_DIR="$SERVER_INSTALL_PATH/update"

# ── APM: 모든 APM 프로젝트 agents API로 버전 수집 + self 설치 확인
APM_VERSION=""
APM_INSTALL_PATH="${APM_INSTALL_PATH:-}"
APM_LANG=""
# APM_SELF_INSTALLED 는 위 'Self 모니터링 검사'(-javaagent 프로세스 검사)에서 이미 판정됨.
# 여기서 리셋하면 그 결과가 지워지므로 재초기화하지 않는다.
_APM_VERSIONS=""
_APM_VER_LANG=""   # "버전\t언어" 쌍 누적 (보고서 버전 표기에 언어 병기용)
_APM_TOTAL=0
_APM_FOUND=0
_APM_SELF_COUNT=0
_APM_PLAT_COUNTS=""  # "JAVA:3,NODE.JS:2" 형태로 누적
# pcode 별 집계 원장 — K8s 내 APM(컨테이너 APM) 으로 확정된 프로젝트를 나중에 빼기 위함.
#   컨테이너 APM 은 이 루프가 끝난 뒤(1400번대)에야 어느 pcode 인지 정해지므로,
#   여기서 pcode 별 수량/플랫폼을 남겨두고 확정 후에 차감한다.
_APM_PCODE_COUNTS=""   # "95:15,123:5"
_APM_PCODE_PLAT=""     # "95:JAVA,123:JAVA"
_K8S_APM_TOTAL=0       # 컨테이너 APM 으로 분리된 대수
_K8S_APM_PLAT=""       # 컨테이너 APM 의 platform

# agents 응답에서 대표 버전(가장 많이 쓰인 값)을 뽑는다.
#   언어/에이전트 종류에 따라 키 이름이나 형식이 달라 "version":"..." 하나만 보면 놓친다.
#   (예: Python 프로젝트는 콘솔에 1.9.2 가 보이는데 이 패턴으로는 안 잡혔다)
#   후보 키를 순서대로, 각 키마다 문자열형 → 따옴표 없는 숫자형 순으로 시도한다.
_ver_pick() {
  _vp_resp="$1"; _vp_out=""
  for _vp_k in version agentVersion ver appVersion agent_version; do
    _vp_out=$(echo "$_vp_resp" | grep -o "\"${_vp_k}\":\"[^\"]*\"" \
      | sort | uniq -c | sort -rn | head -1 | grep -o '"[^"]*"$' | tr -d '"')
    [ -n "$_vp_out" ] && break
    _vp_out=$(echo "$_vp_resp" | grep -oE "\"${_vp_k}\":[0-9][0-9A-Za-z._-]*" \
      | sed "s/\"${_vp_k}\"://" | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
    [ -n "$_vp_out" ] && break
  done
  printf '%s' "$_vp_out"
}

while IFS= read -r proj_block; do
  _pcode=$(echo "$proj_block" | grep -o '"projectCode"[^,}]*' | grep -o '[0-9]\+')
  _token=$(echo "$proj_block" | grep -o '"apiToken":"[^"]*"' | cut -d'"' -f4)
  _name=$(echo "$proj_block" | grep -o '"projectName":"[^"]*"' | cut -d'"' -f4)
  _plat=$(echo "$proj_block" | grep -o '"platform":"[^"]*"' | cut -d'"' -f4)
  [ -z "$_pcode" ] || [ -z "$_token" ] && continue
  info "APM 에이전트 조회 (pcode=$_pcode, $_name)..."
  fetch_agents "$_pcode" "$_token" "APM"
  _resp="$_AG_RESP"
  # 활성 에이전트만 집계 (비활성 = 과거에 붙었다 끊긴 에이전트).
  # _resp_act 는 활성 에이전트 줄만 남긴 것 — 버전/쌍 파싱도 이걸 기준으로 해야
  # 죽은 에이전트의 옛 버전이 대표 버전으로 뽑히지 않는다.
  _ag_all=$(_agents_parse "$_resp"); _agents_stats "$_ag_all"; _agents_tally
  _ag=$(printf '%s' "$_ag_all" | _agents_filter)
  _cnt=$(printf '%s' "$_ag" | grep -c . || true)
  _resp_act=$(printf '%s' "$_resp" | tr '{' '\n' | grep '"oid"' | grep -v '"active":false' || true)
  if [ "${_cnt:-0}" -gt 0 ] 2>/dev/null; then
    _APM_FOUND=1
    _ver=$(_ver_pick "$_resp_act")
    # 수집서버 IP에 뜬 에이전트(=self 모니터링) 수 → 집계에서 제외
    # (grep -c 는 0건일 때 "0" 을 출력하면서 exit 1 이라 '|| echo 0' 을 붙이면
    #  "0\n0" 이 되어 아래 $(( )) 산술이 깨진다. 반드시 '|| true' 로 받는다 — 파일 상단 주석 참고)
    _self=0
    [ -n "$SERVER_IP" ] && _self=$(printf '%s' "$_ag" | awk -F'\t' -v ip="$SERVER_IP" '$3==ip' | grep -c . || true)
    _real=$(( _cnt - _self ))
    [ "$_real" -lt 0 ] && _real=0
    ok "APM [$_name] 에이전트" "활성 ${_cnt}대 (self ${_self}대 제외 → ${_real}대) / 버전: ${_ver:-?} / 플랫폼: ${_plat:-?}"
    [ "${_AG_INACTIVE:-0}" -gt 0 ] 2>/dev/null && info "  └ 비활성 ${_AG_INACTIVE}대 제외 (응답 전체 ${_AG_TOTAL}대)"
    # 버전만 못 뽑은 경우: 응답 키가 예상과 다른 것이므로 원문 앞부분을 남겨 추적 가능하게 한다.
    [ -z "$_ver" ] && warn "  └ APM [$_name] 버전 미확인" "응답에 알려진 버전 키 없음 — 원문: $(echo "$_resp" | head -c 300)"
    _APM_TOTAL=$(( _APM_TOTAL + _real ))
    _APM_SELF_COUNT=$(( _APM_SELF_COUNT + _self ))
    _APM_PCODE_COUNTS="${_APM_PCODE_COUNTS:+${_APM_PCODE_COUNTS},}${_pcode}:${_real}"
    _APM_PCODE_PLAT="${_APM_PCODE_PLAT:+${_APM_PCODE_PLAT},}${_pcode}:${_plat}"
    _APM_VERSIONS=$(printf '%s\n%s' "$_APM_VERSIONS" "$_ver" | grep -v '^$' | sort -u | tr '\n' ',' | sed 's/,$//')
    # 에이전트별 (버전, 언어) 쌍 — 보고서에 "2.2.75 (Java), 2.3.0 (Python)" 으로 병기하기 위함.
    #   언어는 프로젝트 단위 속성(platform)이라 그 프로젝트 에이전트에 그대로 붙인다.
    #   수집서버 IP 에 뜬 self 에이전트는 수량과 마찬가지로 제외.
    #   에이전트 줄에서 버전을 못 읽으면 프로젝트 대표 버전(projver)으로 채운다
    #   — 언어별로 버전 키가 달라 줄 단위 파싱이 실패해도 언어 병기는 살린다.
    #   맨 앞에 pcode 를 붙여둔다 — 컨테이너 APM 으로 확정된 프로젝트의 버전/언어를
    #   호스트 APM 버전 표기에서 빼야 하기 때문(분리 집계).
    _pairs=$(printf '%s' "$_resp_act" | awk -v pc="$_pcode" -v plat="$_plat" -v selfip="$SERVER_IP" -v projver="$_ver" '
      {
        ver=""; ip=""
        if (match($0, /"version":"[^"]*"/)) { ver=substr($0, RSTART+11, RLENGTH-12) }
        if (ver == "" && $0 ~ /"oid"/) ver=projver
        if (match($0, /"ip":"[^"]*"/))      { ip=substr($0, RSTART+6, RLENGTH-7) }
        if (ver != "" && plat != "" && ip != selfip) print pc "\t" ver "\t" plat
      }' || true)
    [ -n "$_pairs" ] && _APM_VER_LANG=$(printf '%s\n%s' "$_APM_VER_LANG" "$_pairs")
    # 플랫폼별 개수 누적 (self 제외 실 수량 기준)
    if [ -n "$_plat" ] && [ "$_real" -gt 0 ]; then
      _existing=$(echo "$_APM_PLAT_COUNTS" | tr ',' '\n' | grep "^${_plat}:" | cut -d':' -f2 || echo "0")
      _existing="${_existing:-0}"
      _new=$(( _existing + _real ))
      _APM_PLAT_COUNTS=$(echo "$_APM_PLAT_COUNTS" | tr ',' '\n' | grep -v "^${_plat}:" | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
      _APM_PLAT_COUNTS="${_APM_PLAT_COUNTS:+${_APM_PLAT_COUNTS},}${_plat}:${_new}"
    fi
  else
    if [ "${_AG_FAIL:-0}" = "1" ]; then
      # 조회 자체가 실패했다 — 0대로 세면 확인서에 '미설치' 로 박힌다. 집계하지 않고 실패로 남긴다.
      _APM_QFAIL=$(( _APM_QFAIL + 1 ))
      fail "APM [$_name]" "에이전트 조회 실패 (pcode=$_pcode, HTTP ${_AG_HTTP:-연결실패}) — 0대로 집계하지 않습니다"
    else
      warn "APM [$_name]" "에이전트 미연결 (pcode=$_pcode) — 응답: $(echo "$_resp" | head -c 200)"
    fi
  fi
done << _APM_EOF
$(echo "$PROJECTS" | tr '{' '\n' | grep -i '"APM"' || true)
_APM_EOF

# APM 집계 확정: 포함 판정 + 버전/언어 표기.
#   $1 이 주어지면 그 pcode(=컨테이너 APM)를 호스트 APM 집계에서 제외한다.
#   컨테이너 APM 확정은 이 시점 이후(1400번대)라, 확정 뒤 같은 함수를 다시 불러 재계산한다.
_apm_finalize() {
  local _ex="${1:-}"
  # self 제외 실 에이전트가 있어야 제품 섹션 출력 (전부 수집서버 self면 스킵)
  _APM_INCLUDE=0
if [ "$_APM_FOUND" = "1" ] && [ "$_APM_TOTAL" -gt 0 ]; then
  _APM_INCLUDE=1
  # 버전 뒤에 언어를 괄호로: "2.2.75 (Java, Python), 2.3.0 (Node.js)"
  #   (버전별로 언어가 여러 개면 모두 나열. 쌍 파싱 실패 시 기존 버전 목록으로 폴백)
  APM_VERSION=$(printf '%s\n' "$_APM_VER_LANG" | grep -v '^$' \
    | { [ -n "$_ex" ] && awk -F'\t' -v x="$_ex" '$1!=x' || cat; } \
    | cut -f2- | sort -u | awk -F'\t' '
    {
      lbl=toupper($2)
      if      (lbl=="JAVA")                        lbl="Java"
      else if (lbl=="PYTHON")                      lbl="Python"
      else if (lbl=="NODE" || lbl=="NODEJS" || lbl=="NODE.JS") lbl="Node.js"
      else if (lbl=="PHP")                         lbl="PHP"
      else if (lbl=="DOTNET" || lbl==".NET")       lbl=".NET"
      else if (lbl=="GO" || lbl=="GOLANG")         lbl="Go"
      else                                         lbl=$2
      if (!(($1 SUBSEP lbl) in seen)) {
        seen[$1 SUBSEP lbl]=1
        if (!($1 in ord)) { ord[$1]=++n; vers[n]=$1 }
        langs[$1] = langs[$1] (langs[$1]=="" ? "" : ", ") lbl
      }
    }
    END {
      for (i=1; i<=n; i++) {
        v=vers[i]; lab=langs[v]
        if (i>1 && lab==prevlab) { grp = grp ", " v }
        else {
          if (i>1) out = out (out=="" ? "" : " / ") grp " (" prevlab ")"
          grp = v
        }
        prevlab=lab
      }
      if (n>0) out = out (out=="" ? "" : " / ") grp " (" prevlab ")"
      print out
    }')
  [ -z "$APM_VERSION" ] && APM_VERSION="$_APM_VERSIONS"
  ok "APM 버전(통합)" "$APM_VERSION (총 ${_APM_TOTAL}대, 수집서버 self ${_APM_SELF_COUNT}대 제외)"
  [ -n "$_APM_PLAT_COUNTS" ] && ok "APM 플랫폼별 에이전트" "$(echo "$_APM_PLAT_COUNTS" | tr ',' ' | ')"
elif [ "$_APM_FOUND" = "1" ]; then
  # 호스트 APM 이 0대가 되는 사유는 둘 — 전부 수집서버 self 이거나, 전부 컨테이너 APM 이거나.
  if [ -n "$_ex" ] && [ "${_K8S_APM_TOTAL:-0}" -gt 0 ] 2>/dev/null; then
    warn "APM" "호스트 APM 0대 — APM 에이전트가 전부 컨테이너 APM(K8s ${_K8S_APM_TOTAL}대), 호스트 APM 섹션 스킵"
  else
    warn "APM" "APM 에이전트가 전부 수집서버 self(${_APM_SELF_COUNT}대) — APM 제품 섹션 스킵"
  fi
else
  if [ "${_APM_QFAIL:-0}" -gt 0 ] 2>/dev/null; then
    fail "APM" "프로젝트 ${_APM_QFAIL}개 조회 실패 — 설치 여부를 확인하지 못했습니다 (미설치와 다릅니다)"
  else
    warn "APM" "APM 프로젝트 없음 또는 에이전트 미연결"
  fi
fi

  # APM 언어: 프로젝트 목록의 platform 필드에서 수집 (중복 제거). 컨테이너 APM 제외.
  #   여길 안 빼면 컨테이너가 Node.js 일 때 호스트 APM 섹션 언어에 Node.js 가 켜진다.
  APM_LANG=$(echo "$PROJECTS" | tr '{' '\n' | grep -i '"APM"' \
    | { [ -n "$_ex" ] && grep -vE '"projectCode":[[:space:]]*'"$_ex"'([,}]|$)' || cat; } \
    | grep -o '"platform":"[^"]*"' | cut -d'"' -f4 \
    | sort -u | tr '\n' ',' | sed 's/,$//')
  [ -n "$APM_LANG" ] && ok "APM 언어(platform)" "$APM_LANG"
}
_apm_finalize

# ── K8s 내 APM(컨테이너 APM) 자동 감지 + 확인
#    감지 방식: CPM 프로젝트의 kube_pod 목록(pod 이름/네임스페이스)과 APM 에이전트 이름(oname)을 대조.
#      1순위 pod 이름 정확 일치 → 확실, 2순위 pod 이름 prefix(워크로드명) 일치 → 추정,
#      pod 목록을 못 얻으면 oname 이 K8s pod 이름 패턴(...-<해시>-<해시>)인지로 추정.
#    자동 감지값은 기본값으로만 제시하고 최종 확정은 사용자가 한다(오탐 방지).
#    (아래 호스트 APM 지표 합산에서 이 pcode를 제외해야 하므로 지표 조회보다 먼저 수행)
if [ "${_has_cpm:-0}" -gt 0 ] && [ "${_has_apm:-0}" -gt 0 ] 2>/dev/null; then
  info "K8s 클러스터 내 APM(컨테이너 APM) 자동 감지 중..."

  # 1) CPM 프로젝트들에서 pod 목록 수집 → "namespace<TAB>podName"
  _POD_TMP=$(mktemp 2>/dev/null || echo "/tmp/whatap_pods.$$"); : > "$_POD_TMP"
  _POD_ERR=""
  # pod 수가 이 값에 걸리면 응답이 잘린 것 → 대조에서 놓치는 에이전트가 생긴다.
  #   예전엔 1000 이라 pod 1000개 넘는 클러스터에서 조용히 잘렸다(로그엔 "1000개 수집" 으로 성공처럼 보임).
  _POD_LIMIT=20000
  _POD_TRUNC=0
  _pod_mql="CATEGORY kube_pod\nTIME-RANGE {recent: 5m}\nTAGLOAD {backward: true}\nSELECT"
  _pod_stime=$(( $(date +%s) * 1000 - 300000 ))
  _pod_etime=$(( $(date +%s) * 1000 ))
  while IFS= read -r _kp; do
    [ -z "$_kp" ] && continue
    _kpc=$(echo "$_kp" | grep -o '"projectCode"[^,}]*' | grep -o '[0-9]\+')
    _kpt=$(echo "$_kp" | grep -o '"apiToken":"[^"]*"' | cut -d'"' -f4)
    [ -z "$_kpc" ] || [ -z "$_kpt" ] && continue
    _kpr=$(curl -skL ${_CURL_HTTP11} --connect-timeout 10 --max-time 30 \
      -X POST "$WHATAP_API_HOST/open/api/json/mxql/text" \
      -H "Content-Type: application/json" \
      -H "x-whatap-token: $_kpt" \
      -H "x-whatap-pcode: $_kpc" \
      -d "{\"stime\":${_pod_stime},\"etime\":${_pod_etime},\"mql\":\"${_pod_mql}\",\"limit\":${_POD_LIMIT}}" 2>/dev/null || echo "")
    _before=$(wc -l < "$_POD_TMP" 2>/dev/null | tr -d ' '); _before="${_before:-0}"
    echo "$_kpr" | tr '{' '\n' | while IFS= read -r _pl; do
      _pn=$(echo "$_pl" | grep -o '"podName":"[^"]*"' | head -1 | cut -d'"' -f4)
      [ -z "$_pn" ] && _pn=$(echo "$_pl" | grep -o '"pod_name":"[^"]*"' | head -1 | cut -d'"' -f4)
      [ -z "$_pn" ] && _pn=$(echo "$_pl" | grep -o '"pod":"[^"]*"' | head -1 | cut -d'"' -f4)
      # 최후 폴백: kube_pod 카테고리의 "name" 은 pod 이름으로 본다
      [ -z "$_pn" ] && _pn=$(echo "$_pl" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4)
      [ -z "$_pn" ] && continue
      _ns=$(echo "$_pl" | grep -o '"namespace":"[^"]*"' | head -1 | cut -d'"' -f4)
      printf '%s\t%s\n' "${_ns:-?}" "$_pn" >> "$_POD_TMP"
    done
    _after=$(wc -l < "$_POD_TMP" 2>/dev/null | tr -d ' '); _after="${_after:-0}"
    # 이 프로젝트에서 뽑은 pod 수가 limit 과 같으면 응답이 잘렸다고 본다.
    #   잘리면 대조에서 놓치는 에이전트가 생겨 감지가 틀릴 수 있으므로 조용히 넘기지 않는다.
    if [ "$(( _after - _before ))" -ge "$_POD_LIMIT" ] 2>/dev/null; then
      _POD_TRUNC=1
      warn "kube_pod 응답 잘림 (pcode $_kpc)" "limit ${_POD_LIMIT}개에 도달 — pod 가 더 있을 수 있어 감지가 부정확할 수 있음"
    fi
    # 이 프로젝트에서 pod 를 하나도 못 뽑았을 때 원인을 구분한다.
    #   빈 응답은 오류가 아니다 — 네임스페이스 단위 CPM 프로젝트는 pod 지표가
    #   상위 클러스터 프로젝트에 있어서 정상적으로 비어 있다(kube_node 도 동일).
    #   스키마 불일치(키 없음)만 실제 문제로 남긴다.
    if [ "$_after" -le "$_before" ] 2>/dev/null; then
      _trim=$(echo "$_kpr" | tr -d ' \n')
      if [ -z "$_trim" ] || [ "$_trim" = "[]" ]; then
        info "  └ kube_pod 없음 (pcode $_kpc) — 네임스페이스 단위 프로젝트면 정상"
      else
        _keys=$(echo "$_kpr" | grep -o '"[a-zA-Z_][a-zA-Z0-9_]*":' | sort -u | tr -d '":' | tr '\n' ',' | sed 's/,$//')
        fail "kube_pod 파싱 실패 (pcode $_kpc)" "podName/pod_name/pod/name 키 없음 — 스키마 불일치"
        warn "  └ 응답 키 목록" "${_keys:-(없음)}"
        warn "  └ 응답 원문" "$(echo "$_kpr" | head -c 300)"
        _POD_ERR="${_POD_ERR}[pcode $_kpc] pod 이름 키 없음(응답 키: ${_keys:-none}); "
      fi
    fi
  done << _KPOD_EOF
$(echo "$PROJECTS" | tr '{' '\n' | grep -i '"CPM"' || true)
_KPOD_EOF
  _pod_cnt=$(wc -l < "$_POD_TMP" 2>/dev/null | tr -d ' '); _pod_cnt="${_pod_cnt:-0}"
  if [ "$_pod_cnt" -gt 0 ] 2>/dev/null; then
    ok "K8s pod 목록" "${_pod_cnt}개 수집 (kube_pod)${_POD_TRUNC:+ — 일부 잘림 주의}"
    if [ "$_POD_TRUNC" = "1" ]; then
      CPM_APM_DETECT_ERROR="kube_pod 응답이 limit(${_POD_LIMIT})에 걸려 잘림 — 감지 정확도 저하 가능"
    fi
    if [ -n "$_POD_ERR" ]; then
      warn "K8s pod 목록" "일부 CPM 프로젝트에서 수집 실패 — $_POD_ERR"
      CPM_APM_DETECT_ERROR="일부 CPM 프로젝트 pod 수집 실패 — $_POD_ERR"
    fi
  else
    fail "K8s pod 목록 수집 실패" "자동 감지 1·2단계(pod 이름 대조) 불가 — 이름 패턴 추정으로 대체 (정확도 낮음)"
    [ -n "$_POD_ERR" ] && fail "  └ 원인" "$_POD_ERR"
    CPM_APM_DETECT_ERROR="kube_pod 수집 실패 — ${_POD_ERR:-응답 없음}"
  fi

  # 2) APM 프로젝트별로 에이전트 이름을 pod 목록과 대조
  _auto_pcode=""; _auto_reason=""; _auto_ns=""; _auto_name=""
  echo "    ── APM 프로젝트 목록 ──" >&2
  while IFS= read -r _ap; do
    [ -z "$_ap" ] && continue
    _apc=$(echo "$_ap" | grep -o '"projectCode"[^,}]*' | grep -o '[0-9]\+')
    _apt=$(echo "$_ap" | grep -o '"apiToken":"[^"]*"' | cut -d'"' -f4)
    _apn=$(echo "$_ap" | grep -o '"projectName":"[^"]*"' | cut -d'"' -f4)
    _app=$(echo "$_ap" | grep -o '"platform":"[^"]*"' | cut -d'"' -f4)
    [ -z "$_apc" ] || [ -z "$_apt" ] && continue
    _ar=$(curl -skL ${_CURL_HTTP11} --connect-timeout 10 --max-time 30 \
      -H "x-whatap-token: $_apt" -H "x-whatap-pcode: $_apc" \
      "$WHATAP_API_HOST/open/api/json/project/agents" 2>/dev/null || echo "")
    _onames=$(echo "$_ar" | grep -o '"oname":"[^"]*"' | cut -d'"' -f4 | sort -u)
    # 진단: agents 응답 자체가 컨테이너 여부를 알려주면 pod 대조가 통째로 필요 없다.
    #   서버 코드상 container_id 가 0 이 아니면 ContainerInfo 로 직렬화되는데
    #   (AgentInfo.create), 그 하위 클래스가 어떤 키를 더 내보내는지는 소스 스냅샷에
    #   없어 확인이 안 됐다. 실환경 응답에서 컨테이너성 키를 찾으면 로그로 알린다.
    _ckeys=$(echo "$_ar" | grep -oE '"(containerId|container_id|containerName|podName|pod_name|namespace|kube[A-Za-z_]*)":' \
      | tr -d '":' | sort -u | tr '\n' ',' | sed 's/,$//')
    [ -n "$_ckeys" ] && info "  └ [진단] agents 응답에 컨테이너 관련 키 있음 (pcode $_apc): $_ckeys"
    # 에이전트 이름 × pod 목록 대조를 awk 한 번으로 끝낸다.
    #   예전엔 에이전트마다 awk 를 최대 2번 띄우고 그때마다 pod 파일을 통째로 훑어
    #   (에이전트 수 × pod 수), 컨테이너가 많은 환경에서 프로세스가 수천 개 떴다.
    #   이제 pod 를 해시에 한 번만 올리고 에이전트 이름을 흘려보낸다 → O(pod + 에이전트).
    #   접두 후보는 pod 이름의 '-' 경계마다 만들어 두므로 기존 index(pod, oname"-")==1 과 동치.
    _mres=$(printf '%s\n' "$_onames" | awk -v podfile="$_POD_TMP" -v podcnt="$_pod_cnt" '
      BEGIN {
        if (podcnt+0 > 0) {
          while ((getline line < podfile) > 0) {
            split(line, a, "\t"); ns=a[1]; pn=a[2]
            if (pn == "") continue
            if (!(pn in podns)) podns[pn]=ns
            n=split(pn, seg, "-"); p=""
            for (i=1; i<n; i++) { p = (i==1 ? seg[1] : p "-" seg[i]); if (!(p in prefns)) prefns[p]=ns }
          }
          close(podfile)
        }
      }
      $0 == "" { next }
      {
        on=$0
        if (podcnt+0 > 0) {
          if (on in podns)  { ex++;  if (nsx=="") nsx=podns[on];  next }
          if (on in prefns) { pf++;  if (nsp=="") nsp=prefns[on]; next }
        } else {
          # pod 목록을 못 얻었을 때만 이름 패턴으로 추정 (ReplicaSet: <이름>-<해시>-<해시>)
          #   StatefulSet 패턴(<이름>-<숫자>)은 app-server-01 같은 호스트명과 구분이 안 돼 제외
          if (on ~ /^[a-z0-9][a-z0-9.-]*-[0-9a-z]{5,10}-[0-9a-z]{5}$/) pt++
        }
      }
      END { printf "%d\t%d\t%d\t%s\n", ex+0, pf+0, pt+0, (nsx != "" ? nsx : nsp) }
    ')
    _hit_exact=$(printf '%s' "$_mres"  | cut -f1)
    _hit_prefix=$(printf '%s' "$_mres" | cut -f2)
    _hit_pattern=$(printf '%s' "$_mres" | cut -f3)
    _ns_hit=$(printf '%s' "$_mres"     | cut -f4)
    _mark=""
    if [ "$_hit_exact" -gt 0 ]; then
      _mark="← K8s pod 이름 일치 ${_hit_exact}건"
      if [ -z "$_auto_pcode" ] || [ "$_auto_reason" != "pod 이름 일치" ]; then
        _auto_pcode="$_apc"; _auto_reason="pod 이름 일치"; _auto_ns="$_ns_hit"; _auto_name="$_apn"
      fi
    elif [ "$_hit_prefix" -gt 0 ]; then
      _mark="← 워크로드명 일치 ${_hit_prefix}건 (추정)"
      if [ -z "$_auto_pcode" ]; then
        _auto_pcode="$_apc"; _auto_reason="워크로드명 일치(추정)"; _auto_ns="$_ns_hit"; _auto_name="$_apn"
      fi
    elif [ "$_hit_pattern" -gt 0 ]; then
      _mark="← pod 이름 패턴 ${_hit_pattern}건 (추정)"
      if [ -z "$_auto_pcode" ]; then
        _auto_pcode="$_apc"; _auto_reason="에이전트 이름 패턴(추정)"; _auto_name="$_apn"
      fi
    fi
    printf "      pcode=%-8s [%-8s] %s %s\n" "$_apc" "$_app" "$_apn" "$_mark" >&2
  done << _KAPM_EOF
$(echo "$PROJECTS" | tr '{' '\n' | grep -i '"APM"' || true)
_KAPM_EOF
  rm -f "$_POD_TMP" 2>/dev/null || true

  # 3) 자동 감지 결과를 기본값으로 제시 (Enter=수락, n=없음, 숫자=직접 지정)
  #    감지된 게 없으면 K8s 안에 APM 이 없는 것으로 보고 더 묻지 않는다.
  if [ -n "$_auto_pcode" ]; then
    ok "컨테이너 APM 자동 감지" "pcode ${_auto_pcode} (${_auto_name}) — 근거: ${_auto_reason}"
    read -r $_READ_E -p "  이 프로젝트를 K8s 내 APM으로 확정합니까? (Enter=예 / n=없음 / 다른 pcode 입력): " _capm_in || true
    case "$_capm_in" in
      "")      CPM_APM_PCODE="$_auto_pcode" ;;
      n|N|없음) CPM_APM_PCODE="" ;;
      *)       CPM_APM_PCODE="$_capm_in" ;;
    esac
  else
    info "자동 감지 결과: K8s 안에서 도는 APM 없음"
    CPM_APM_PCODE=""
  fi

  if [ -n "$CPM_APM_PCODE" ]; then
    CPM_APM_USED="사용"
    if [ "$CPM_APM_PCODE" = "$_auto_pcode" ] && [ -n "$_auto_reason" ]; then
      CPM_APM_DETECT_METHOD="자동 감지 — ${_auto_reason}"
    else
      CPM_APM_DETECT_METHOD="수동 지정"
    fi
    _capm_line=$(echo "$PROJECTS" | tr '{' '\n' | grep -E '"projectCode":[[:space:]]*'"$CPM_APM_PCODE"'([,}]|$)' | head -1)
    _capm_token=$(echo "$_capm_line" | grep -o '"apiToken":"[^"]*"' | cut -d'"' -f4)
    CPM_APM_LANG=$(echo "$_capm_line" | grep -o '"platform":"[^"]*"' | cut -d'"' -f4)
    # 설치 방식: CPM 이 Operator 설치면 Operator 자동설치를 기본값으로 제시
    _capm_def=""
    [ "$CPM_INSTALL_METHOD" = "Operator" ] && _capm_def="1"
    echo "    설치 방식  1) Operator 자동설치   2) Docker 이미지 주입" >&2
    read -r $_READ_E -p "  APM 설치(주입) 방식 번호${_capm_def:+ [기본 $_capm_def]}: " _capm_m || true
    [ -z "$_capm_m" ] && _capm_m="$_capm_def"
    case "$_capm_m" in
      1) CPM_APM_INSTALL_METHOD="Operator 자동설치" ;;
      2) CPM_APM_INSTALL_METHOD="Docker 이미지 주입" ;;
      *) CPM_APM_INSTALL_METHOD="" ;;
    esac
    # 적용 대상: 자동 감지된 네임스페이스를 기본값으로
    read -r $_READ_E -p "  적용 대상 (네임스페이스/워크로드)${_auto_ns:+ [기본 $_auto_ns]}: " CPM_APM_TARGET || true
    [ -z "$CPM_APM_TARGET" ] && CPM_APM_TARGET="$_auto_ns"
    read -r $_READ_E -p "  컨테이너 APM 에이전트 버전 (없으면 Enter): " CPM_APM_VERSION || true
  else
    CPM_APM_USED="없음"
    info "K8s 내 APM 없음 — 컨테이너 APM 상세 생략"
  fi
fi

# ── 컨테이너 APM 분리 집계 ────────────────────────────────────────────────────
# 컨테이너 APM 도 productType 이 APM 이라 위 APM 루프에 이미 잡혀 있다.
# 그대로 두면 "APM 20대" 안에 호스트 15대와 K8s 5대가 뭉쳐, 확인서를 받는 쪽에서
# K8s 내 APM 섹션의 5대가 별개인지 포함인지 알 수 없다.
# → 해당 pcode 몫을 호스트 APM 집계에서 빼고 k8sApm 으로 따로 세운다. 총 대수는 그대로.
#   수량뿐 아니라 플랫폼별 내역·언어·버전 표기·포함 판정을 함께 옮겨야 숫자가 안 깨진다.
if [ -n "${CPM_APM_PCODE:-}" ]; then
  _K8S_APM_TOTAL=$(echo "$_APM_PCODE_COUNTS" | tr ',' '\n' | grep "^${CPM_APM_PCODE}:" | cut -d':' -f2 | head -1)
  _K8S_APM_TOTAL="${_K8S_APM_TOTAL:-0}"
  _K8S_APM_PLAT=$(echo "$_APM_PCODE_PLAT" | tr ',' '\n' | grep "^${CPM_APM_PCODE}:" | cut -d':' -f2- | head -1)
  if [ "$_K8S_APM_TOTAL" -gt 0 ] 2>/dev/null; then
    _APM_TOTAL=$(( _APM_TOTAL - _K8S_APM_TOTAL ))
    [ "$_APM_TOTAL" -lt 0 ] && _APM_TOTAL=0
    # 플랫폼별 내역에서도 같은 몫을 뺀다 (안 빼면 내역 합 > 총계)
    if [ -n "$_K8S_APM_PLAT" ]; then
      _cur=$(echo "$_APM_PLAT_COUNTS" | tr ',' '\n' | grep "^${_K8S_APM_PLAT}:" | cut -d':' -f2 | head -1)
      _left=$(( ${_cur:-0} - _K8S_APM_TOTAL ))
      [ "$_left" -lt 0 ] && _left=0
      _APM_PLAT_COUNTS=$(echo "$_APM_PLAT_COUNTS" | tr ',' '\n' | grep -v "^${_K8S_APM_PLAT}:" | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
      [ "$_left" -gt 0 ] && _APM_PLAT_COUNTS="${_APM_PLAT_COUNTS:+${_APM_PLAT_COUNTS},}${_K8S_APM_PLAT}:${_left}"
    fi
    ok "컨테이너 APM 분리" "K8s APM ${_K8S_APM_TOTAL}대 (${_K8S_APM_PLAT:-?}) — 호스트 APM ${_APM_TOTAL}대로 조정"
    # 버전/언어/포함 판정 재계산 (컨테이너 pcode 제외).
    #   호스트 APM 이 0대가 되면 _APM_INCLUDE 도 0 이 되어 빈 APM 섹션이 안 나간다
    #   — K8s 만 쓰는 고객이면 실제로 이 경우가 된다.
    _apm_finalize "$CPM_APM_PCODE"
  fi
fi

# ── WAS 종류 / Java 버전: 수기 입력
#    (environment API는 콘솔 세션 전용 + RSA 암호화 로그인/CSRF/CAPTCHA라 자동 수집 불가,
#     MXQL·open API에도 미노출. WhaTap 콘솔 '실행 환경 변수'의 apType/java.version 참고해 입력)
APM_WAS=""
APM_JAVA_VERSION=""
if [ "$_APM_INCLUDE" = "1" ]; then
  echo ""
  info "WAS 종류/Java 버전 입력 (콘솔 > 인스턴스 성능관리 > 실행 환경변수의 apType/java.version 참고)"
  read -r $_READ_E -p "  WAS 종류 (예: Tomcat, JBoss, 없으면 Enter): " APM_WAS || true
  read -r $_READ_E -p "  Java 버전 (예: 17.0.12, 없으면 Enter): " APM_JAVA_VERSION || true
fi

# ── SMS: 모든 SMS 프로젝트 agents API로 버전 + OS 현황 수집
SMS_VERSION=""
SMS_OS_SUMMARY=""
_SMS_VERSIONS=""
_SMS_VER_OS=""      # "버전<TAB>OS" 쌍 누적 (버전별로 어느 OS에 깔렸는지 표기용)
_SMS_TOTAL=0
_SMS_SELF_COUNT=0
# OS별 개수: 4종 하드코딩이 아니라 응답의 subtypeName 을 그대로 누적한다("linux:410,sunos:3").
#   서버의 SMEnum 은 linux/window/osx/hpux/aix/sunos/openbsd/freebsd 8종이고,
#   모르는 subtype 은 숫자 문자열로 내려온다(SMEnum.toString 의 마지막 return).
#   4종만 세면 Solaris 등이 총계에서만 잡히고 내역에서 빠져 합이 안 맞았다.
_SMS_OS_COUNTS=""
_SMS_FOUND=0

while IFS= read -r proj_block; do
  _pcode=$(echo "$proj_block" | grep -o '"projectCode"[^,}]*' | grep -o '[0-9]\+')
  _token=$(echo "$proj_block" | grep -o '"apiToken":"[^"]*"' | cut -d'"' -f4)
  _name=$(echo "$proj_block" | grep -o '"projectName":"[^"]*"' | cut -d'"' -f4)
  [ -z "$_pcode" ] || [ -z "$_token" ] && continue
  info "SMS 에이전트 조회 (pcode=$_pcode, $_name)..."
  fetch_agents "$_pcode" "$_token" "SMS"
  _resp="$_AG_RESP"
  # 활성 에이전트만, 그리고 수집서버 self(APM 과 동일 기준)는 제외
  _ag_all=$(_agents_parse "$_resp"); _agents_stats "$_ag_all"; _agents_tally
  _ag=$(printf '%s' "$_ag_all" | _agents_filter)
  # grep -c 는 0건에도 "0" 출력 + exit 1 → '|| echo 0' 금지("0\n0" 되어 산술 깨짐), '|| true' 사용
  _self=0
  if [ -n "$SERVER_IP" ]; then
    _self=$(printf '%s' "$_ag" | awk -F'\t' -v ip="$SERVER_IP" '$3==ip' | grep -c . || true)
    _ag=$(printf '%s' "$_ag" | awk -F'\t' -v ip="$SERVER_IP" '$3!=ip')
  fi
  _cnt=$(printf '%s' "$_ag" | grep -c . || true)
  _resp_act=$(printf '%s' "$_resp" | tr '{' '\n' | grep '"oid"' | grep -v '"active":false' \
    | { [ -n "$SERVER_IP" ] && grep -v "\"ip\":\"$SERVER_IP\"" || cat; } || true)
  if [ "${_cnt:-0}" -gt 0 ] 2>/dev/null; then
    _SMS_FOUND=1
    _ver=$(_ver_pick "$_resp_act")
    # OS별 개수 누적 (활성·self제외 기준) — subtypeName 을 있는 그대로 센다
    _os_line=""
    while IFS='	' read -r _st _n; do
      [ -z "$_n" ] && continue
      _os_line="${_os_line}${_os_line:+ }$(_sms_os_label "$_st"):${_n}"
      _ex=$(echo "$_SMS_OS_COUNTS" | tr ',' '\n' | grep "^${_st}:" | cut -d':' -f2 || echo "0")
      _SMS_OS_COUNTS=$(echo "$_SMS_OS_COUNTS" | tr ',' '\n' | grep -v "^${_st}:" | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
      _SMS_OS_COUNTS="${_SMS_OS_COUNTS:+${_SMS_OS_COUNTS},}${_st}:$(( ${_ex:-0} + _n ))"
    done <<_SMS_OS_EOF
$(printf '%s' "$_ag" | awk -F'\t' '{c[$2]++} END{for(k in c) printf "%s\t%s\n", k, c[k]}')
_SMS_OS_EOF
    ok "SMS [$_name] 에이전트" "활성 ${_cnt}대 (self ${_self}대 제외) / 버전: ${_ver:-?} / ${_os_line:-OS 미상}"
    [ "${_AG_INACTIVE:-0}" -gt 0 ] 2>/dev/null && info "  └ 비활성 ${_AG_INACTIVE}대 제외 (응답 전체 ${_AG_TOTAL}대)"
    _SMS_TOTAL=$(( _SMS_TOTAL + _cnt ))
    _SMS_SELF_COUNT=$(( _SMS_SELF_COUNT + _self ))
    _SMS_VERSIONS=$(printf '%s\n%s' "$_SMS_VERSIONS" "$_ver" | grep -v '^$' | sort -u | tr '\n' ',' | sed 's/,$//')
    # 에이전트별 (버전, OS) 쌍: 같은 버전이 여러 OS에 깔려 있으면 괄호에 함께 표기하기 위함
    _pairs=$(printf '%s' "$_resp_act" | awk '
      {
        ver=""; os=""
        if (match($0, /"version":"[^"]*"/))     { ver=substr($0, RSTART+11, RLENGTH-12) }
        if (match($0, /"subtypeName":"[^"]*"/)) { os=substr($0, RSTART+15, RLENGTH-16) }
        if (ver != "" && os != "") print ver "\t" os
      }' || true)
    [ -n "$_pairs" ] && _SMS_VER_OS=$(printf '%s\n%s' "$_SMS_VER_OS" "$_pairs")
  else
    if [ "${_AG_FAIL:-0}" = "1" ]; then
      # 조회 자체가 실패했다 — 0대로 세면 확인서에 '미설치' 로 박힌다. 집계하지 않고 실패로 남긴다.
      _SMS_QFAIL=$(( _SMS_QFAIL + 1 ))
      fail "SMS [$_name]" "에이전트 조회 실패 (pcode=$_pcode, HTTP ${_AG_HTTP:-연결실패}) — 0대로 집계하지 않습니다"
    else
      warn "SMS [$_name]" "에이전트 미연결 (pcode=$_pcode) — 응답: $(echo "$_resp" | head -c 200)"
    fi
  fi
done << _SMS_EOF
$(echo "$PROJECTS" | tr '{' '\n' | grep -i '"SMS"' || true)
_SMS_EOF

if [ "$_SMS_FOUND" = "1" ]; then
  # 버전 뒤에 설치 OS를 괄호로: "2.9.19 (Linux, Windows), 2.9.3 (Windows)"
  #   (버전별로 OS가 여러 개면 모두 나열. 쌍 파싱 실패 시 기존 버전 목록으로 폴백)
  SMS_VERSION=$(printf '%s\n' "$_SMS_VER_OS" | grep -v '^$' | sort -u | awk -F'\t' '
    {
      lbl=$2
      if      (lbl=="linux")                    lbl="Linux"
      else if (lbl=="window" || lbl=="windows") lbl="Windows"
      else if (lbl=="aix")                      lbl="AIX"
      else if (lbl=="hpux")                     lbl="HP-UX"
      else if (lbl=="sunos")                    lbl="Solaris"
      else if (lbl=="osx")                      lbl="macOS"
      else if (lbl=="openbsd")                  lbl="OpenBSD"
      else if (lbl=="freebsd")                  lbl="FreeBSD"
      else if (lbl!="")                         lbl="기타(" lbl ")"
      if (!(($1 SUBSEP lbl) in seen)) {
        seen[$1 SUBSEP lbl]=1
        if (!($1 in ord)) { ord[$1]=++n; vers[n]=$1 }
        osl[$1] = osl[$1] (osl[$1]=="" ? "" : ", ") lbl
      }
    }
    END {
      for (i=1; i<=n; i++) {
        v=vers[i]; lab=osl[v]
        if (i>1 && lab==prevlab) { grp = grp ", " v }
        else {
          if (i>1) out = out (out=="" ? "" : " / ") grp " (" prevlab ")"
          grp = v
        }
        prevlab=lab
      }
      if (n>0) out = out (out=="" ? "" : " / ") grp " (" prevlab ")"
      print out
    }')
  [ -z "$SMS_VERSION" ] && SMS_VERSION="$_SMS_VERSIONS"
  # OS 현황: 수집된 subtype 을 전부 나열 (많은 순) — 내역 합 == 총계가 되도록
  SMS_OS_SUMMARY=""
  while IFS=':' read -r _st _n; do
    [ -z "$_st" ] && continue
    SMS_OS_SUMMARY="${SMS_OS_SUMMARY}$(_sms_os_label "$_st") ${_n}대 "
  done <<_SMS_SUM_EOF
$(echo "$_SMS_OS_COUNTS" | tr ',' '\n' | grep -v '^$' | sort -t: -k2,2nr)
_SMS_SUM_EOF
  SMS_OS_SUMMARY="${SMS_OS_SUMMARY}(총 ${_SMS_TOTAL}대)"
  ok "SMS 버전(통합)" "$SMS_VERSION"
  ok "SMS 서버 현황(통합)" "$SMS_OS_SUMMARY"
else
  if [ "${_SMS_QFAIL:-0}" -gt 0 ] 2>/dev/null; then
    fail "SMS" "프로젝트 ${_SMS_QFAIL}개 조회 실패 — 설치 여부를 확인하지 못했습니다 (미설치와 다릅니다)"
  else
    warn "SMS" "SMS 프로젝트 없음 또는 에이전트 미연결"
  fi
fi

# ── DPM: 모든 DB 프로젝트 agents API로 버전 수집
DPM_VERSION=""
DPM_DB_TYPE=""
_DPM_VERSIONS=""
_DPM_PLATFORMS=""
_DPM_TOTAL=0
_DPM_FOUND=0
_DPM_DB_COUNTS=""      # "MySQL:3,PostgreSQL:1" 형태로 누적
# Slow SQL 설정: 예전엔 한 프로젝트라도 on 이면 전체가 "설정"으로 굳었다(off 로 되돌아가지 않음).
#   프로젝트 3개 중 1개만 켜져 있어도 확인서에는 전부 켜진 것처럼 나와서,
#   XOS_INSTALLED 와 같은 3단계(설정/일부설정/미설정)로 바꾸고 미설정 프로젝트명을 남긴다.
DPM_SLOW_SETTING=""
_DPM_SLOW_ON=0
_DPM_SLOW_OFF=0
_DPM_SLOW_OFF_NAMES=""
DPM_XOS_CORES=""
_DPM_XOS_MISSING=""
_DPM_XOS_MISSING_COUNT=0
_DPM_XOS_HAS_INSTALL=0
_DPM_DB_VERSIONS=""    # db_version 수집 (중복 포함, 나중에 정제)

while IFS= read -r proj_block; do
  _pcode=$(echo "$proj_block" | grep -o '"projectCode"[^,}]*' | grep -o '[0-9]\+')
  _token=$(echo "$proj_block" | grep -o '"apiToken":"[^"]*"' | cut -d'"' -f4)
  _name=$(echo "$proj_block" | grep -o '"projectName":"[^"]*"' | cut -d'"' -f4)
  _plat=$(echo "$proj_block" | grep -o '"platform":"[^"]*"' | cut -d'"' -f4)
  [ -z "$_pcode" ] || [ -z "$_token" ] && continue
  info "DPM 에이전트 조회 (pcode=$_pcode, $_name)..."
  fetch_agents "$_pcode" "$_token" "DPM"
  _resp="$_AG_RESP"
  _ag_all=$(_agents_parse "$_resp"); _agents_stats "$_ag_all"; _agents_tally
  _ag=$(printf '%s' "$_ag_all" | _agents_filter)
  _cnt=$(printf '%s' "$_ag" | grep -c . || true)
  _resp_act=$(printf '%s' "$_resp" | tr '{' '\n' | grep '"oid"' | grep -v '"active":false' || true)
  # platform은 에이전트 연결 여부와 무관하게 프로젝트 목록에서 수집
  _DPM_PLATFORMS=$(printf '%s\n%s' "$_DPM_PLATFORMS" "$_plat" | grep -v '^$' | sort -u | tr '\n' ',' | sed 's/,$//')
  if [ "${_cnt:-0}" -gt 0 ] 2>/dev/null; then
    _DPM_FOUND=1
    _ver=$(_ver_pick "$_resp_act")
    ok "DPM [$_name] 에이전트" "활성 ${_cnt}대 / 버전: ${_ver:-?} / DB: ${_plat:-?}"
    [ "${_AG_INACTIVE:-0}" -gt 0 ] 2>/dev/null && info "  └ 비활성 ${_AG_INACTIVE}대 제외 (응답 전체 ${_AG_TOTAL}대)"
    _DPM_TOTAL=$(( _DPM_TOTAL + _cnt ))
    _DPM_VERSIONS=$(printf '%s\n%s' "$_DPM_VERSIONS" "$_ver" | grep -v '^$' | sort -u | tr '\n' ',' | sed 's/,$//')
    # DB 종류별 개수 누적
    if [ -n "$_plat" ]; then
      _existing=$(echo "$_DPM_DB_COUNTS" | tr ',' '\n' | grep "^${_plat}:" | cut -d':' -f2 || echo "0")
      _existing="${_existing:-0}"
      _new=$(( _existing + _cnt ))
      _DPM_DB_COUNTS=$(echo "$_DPM_DB_COUNTS" | tr ',' '\n' | grep -v "^${_plat}:" | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
      _DPM_DB_COUNTS="${_DPM_DB_COUNTS:+${_DPM_DB_COUNTS},}${_plat}:${_new}"
    fi
    # db_agentinfo: db_version / agent_slow_setting / xos_version / cpu_cores 통합 수집
    # (h1 롤업 아님, 최근 3시간 조회 후 IP별로 집계)
    _dpm_stime=$(( $(date +%s) * 1000 - 10800000 ))
    _dpm_etime=$(( $(date +%s) * 1000 ))
    _mql_dbinfo="CATEGORY db_agentinfo\nTAGLOAD\nSELECT"
    _ai=$(curl -skL ${_CURL_HTTP11} --connect-timeout 10 --max-time 30 \
      -X POST "$WHATAP_API_HOST/open/api/json/mxql/text" \
      -H "Content-Type: application/json" \
      -H "x-whatap-token: $_token" \
      -H "x-whatap-pcode: $_pcode" \
      -d "{\"stime\":${_dpm_stime},\"etime\":${_dpm_etime},\"mql\":\"${_mql_dbinfo}\",\"limit\":500}" 2>/dev/null || echo "")
    echo "$_ai" | grep -q '"db_ip"' || warn "DPM [$_name] db_agentinfo 응답 원문" "$(echo "$_ai" | head -c 200)"

    # IP별 집계: db_version, slow 설정(on/off), xos 설치(xos_version 유무) + 코어수(cpu_cores)
    _agg=$(echo "$_ai" | tr '{' '\n' | grep '"db_ip"' | awk '
      {
        ip=""; ver=""; cores=0; xos=""; slow=""; nm=""
        if (match($0, /"db_ip":"[^"]*"/))          { ip=substr($0, RSTART+9, RLENGTH-10) }
        if (match($0, /"oname":"[^"]*"/))           { nm=substr($0, RSTART+9, RLENGTH-10) }
        if (match($0, /"db_version":"[^"]*"/))      { ver=substr($0, RSTART+14, RLENGTH-15) }
        if (match($0, /"cpu_cores":[0-9]+/))        { cores=substr($0, RSTART+12, RLENGTH-12) }
        if (match($0, /"xos_version":"[^"]*"/))     { xos=substr($0, RSTART+15, RLENGTH-16) }
        if (match($0, /"agent_slow_setting":"[^"]*"/)) { slow=substr($0, RSTART+22, RLENGTH-23) }
        if (ip != "") {
          if (ver != "") verOf[ip]=ver
          if (nm != "") nameOf[ip]=nm
          if (cores+0 > coreOf[ip]) coreOf[ip]=cores+0
          if (xos != "") xosOf[ip]=1
          if (slow == "on") slowAny=1
        }
      }
      END {
        for (ip in verOf) {
          print "VER\t" verOf[ip]
          if (xosOf[ip]) { okCnt++; coreSum+=coreOf[ip] }
          else { missCnt++; missList = missList (nameOf[ip] ? nameOf[ip] : ip) "(" ip ") " }
        }
        print "SLOW\t" (slowAny ? "on" : "off")
        print "XOS_OK\t" okCnt+0
        print "XOS_MISS\t" missCnt+0
        print "CORES\t" coreSum+0
        print "MISS_LIST\t" missList
      }' || echo "")
    # DB 버전 누적 — "버전<TAB>DB종류" 쌍으로 모은다.
    #   db_agentinfo 에는 DB 종류가 없고 프로젝트 단위 속성(platform)이므로 여기서 붙인다.
    #   버전만 나열하면 "15.0.4033.1, 19.0.0.0.0" 처럼 어느 DB 것인지 알 수 없다.
    while IFS=$'\t' read -r _tag _val; do
      [ "$_tag" = "VER" ] && [ -n "$_val" ] && _DPM_DB_VERSIONS=$(printf '%s\n%s\t%s' "$_DPM_DB_VERSIONS" "$_val" "$_plat")
    done < <(echo "$_agg")
    _slow=$(echo "$_agg" | awk -F'\t' '$1=="SLOW"{print $2}')
    _proj_xos_ok=$(echo "$_agg" | awk -F'\t' '$1=="XOS_OK"{print $2}')
    _proj_xos_missing=$(echo "$_agg" | awk -F'\t' '$1=="XOS_MISS"{print $2}')
    _proj_cores=$(echo "$_agg" | awk -F'\t' '$1=="CORES"{print $2}')
    _proj_miss_list=$(echo "$_agg" | awk -F'\t' '$1=="MISS_LIST"{print $2}')

    # 프로젝트별 on/off 를 각각 세고, 미설정 프로젝트명을 모아둔다 (최종 판정은 루프 뒤에서)
    if [ "$_slow" = "on" ]; then
      _DPM_SLOW_ON=$(( _DPM_SLOW_ON + 1 ))
      ok "DPM [$_name] Slow SQL 설정" "설정"
    else
      _DPM_SLOW_OFF=$(( _DPM_SLOW_OFF + 1 ))
      _DPM_SLOW_OFF_NAMES="${_DPM_SLOW_OFF_NAMES}${_DPM_SLOW_OFF_NAMES:+, }${_name:-pcode $_pcode}"
      warn "DPM [$_name] Slow SQL 설정" "미설정"
    fi
    [ "${_proj_cores:-0}" -gt 0 ] 2>/dev/null && { DPM_XOS_CORES=$(( ${DPM_XOS_CORES:-0} + _proj_cores )); ok "DPM [$_name] XOS 코어 수(IP중복제거)" "${_proj_cores}core"; }
    if [ "${_proj_xos_missing:-0}" -gt 0 ] 2>/dev/null; then
      warn "DPM [$_name] XOS 미설치 에이전트" "${_proj_xos_missing}대: $(echo "$_proj_miss_list" | xargs)"
      _DPM_XOS_MISSING="${_DPM_XOS_MISSING}${_proj_miss_list}"
    fi
    _DPM_XOS_MISSING_COUNT=$(( ${_DPM_XOS_MISSING_COUNT:-0} + ${_proj_xos_missing:-0} ))
    [ "${_proj_xos_ok:-0}" -gt 0 ] 2>/dev/null && _DPM_XOS_HAS_INSTALL=1
  else
    if [ "${_AG_FAIL:-0}" = "1" ]; then
      # 조회 자체가 실패했다 — 0대로 세면 확인서에 '미설치' 로 박힌다. 집계하지 않고 실패로 남긴다.
      _DPM_QFAIL=$(( _DPM_QFAIL + 1 ))
      fail "DPM [$_name]" "에이전트 조회 실패 (pcode=$_pcode, HTTP ${_AG_HTTP:-연결실패}) — 0대로 집계하지 않습니다"
    else
      warn "DPM [$_name]" "에이전트 미연결 (pcode=$_pcode) / DB: ${_plat:-?} — 응답: $(echo "$_resp" | head -c 200)"
    fi
  fi
done << _DPM_EOF
$(echo "$PROJECTS" | tr '{' '\n' | grep -i '"DB"' || true)
_DPM_EOF

DPM_DB_TYPE="$_DPM_PLATFORMS"
if [ "$_DPM_FOUND" = "1" ]; then
  DPM_VERSION="$_DPM_VERSIONS"
  ok "DPM 버전(통합)" "$DPM_VERSION (총 ${_DPM_TOTAL}대)"
else
  if [ "${_DPM_QFAIL:-0}" -gt 0 ] 2>/dev/null; then
    fail "DPM" "프로젝트 ${_DPM_QFAIL}개 조회 실패 — 설치 여부를 확인하지 못했습니다 (미설치와 다릅니다)"
  else
    warn "DPM" "DPM 프로젝트 없음 또는 에이전트 미연결"
  fi
fi

# Slow SQL 설정 최종 판정 (XOS_INSTALLED 와 같은 3단계)
#   전부 on = "설정" / 일부만 on = "일부설정" / 전부 off = "미설정"
if [ "${_DPM_SLOW_ON:-0}" -gt 0 ] && [ "${_DPM_SLOW_OFF:-0}" -eq 0 ]; then
  DPM_SLOW_SETTING="설정"
  ok "DPM Slow SQL 설정(통합)" "설정 (${_DPM_SLOW_ON}개 프로젝트 전부)"
elif [ "${_DPM_SLOW_ON:-0}" -gt 0 ]; then
  DPM_SLOW_SETTING="일부설정"
  warn "DPM Slow SQL 설정(통합)" "일부설정 — 설정 ${_DPM_SLOW_ON}개 / 미설정 ${_DPM_SLOW_OFF}개: ${_DPM_SLOW_OFF_NAMES}"
elif [ "${_DPM_SLOW_OFF:-0}" -gt 0 ]; then
  DPM_SLOW_SETTING="미설정"
  warn "DPM Slow SQL 설정(통합)" "미설정 (${_DPM_SLOW_OFF}개 프로젝트 전부)"
fi
[ -n "$DPM_DB_TYPE" ] && ok "DPM DB 종류" "$DPM_DB_TYPE"

# DB 버전 목록 — 버전 뒤에 DB 종류를 괄호로: "19.0.0.0.0 (Oracle), 15.0.4033.1 (SQL Server)"
#   (같은 버전이 여러 DB 종류에 있으면 괄호에 함께 나열. SMS 의 OS 병기와 같은 방식)
DPM_DB_VERSION_LIST=$(printf '%s\n' "$_DPM_DB_VERSIONS" | grep -v '^$' | sort -u | awk -F'\t' '
  {
    lbl=tolower($2)
    if      (lbl=="oracle")     lbl="Oracle"
    else if (lbl=="postgresql") lbl="PostgreSQL"
    else if (lbl=="mysql")      lbl="MySQL"
    else if (lbl=="mssql")      lbl="SQL Server"
    else if (lbl=="tibero")     lbl="Tibero"
    else if (lbl=="cubrid")     lbl="CUBRID"
    else if (lbl=="altibase")   lbl="Altibase"
    else if (lbl=="db2")        lbl="DB2"
    else if (lbl=="sap_ase")    lbl="SAP ASE"
    else if (lbl=="sap_iq")     lbl="SAP IQ"
    else if (lbl=="mongo")      lbl="MongoDB"
    else if (lbl=="redis")      lbl="Redis"
    else if (lbl=="oracle_dma") lbl="Oracle DMA"
    else                        lbl=$2
    if ($1=="") next
    if (!(($1 SUBSEP lbl) in seen)) {
      seen[$1 SUBSEP lbl]=1
      if (!($1 in ord)) { ord[$1]=++n; vers[n]=$1 }
      dbs[$1] = dbs[$1] (dbs[$1]=="" ? "" : ", ") lbl
    }
  }
  END {
    for (i=1; i<=n; i++) {
      v=vers[i]
      out = out (out=="" ? "" : ", ") v (dbs[v]!="" ? " (" dbs[v] ")" : "")
    }
    print out
  }' || true)
[ -n "$DPM_DB_VERSION_LIST" ] && ok "DB 버전 목록" "$DPM_DB_VERSION_LIST"

# XOS 설치 여부 자동 판정 (xos_version 기반): 전부 있음=설치 / 일부=일부설치 / 없음=미설치
if [ "${_DPM_XOS_HAS_INSTALL:-0}" = "1" ] && [ "${_DPM_XOS_MISSING_COUNT:-0}" -eq 0 ]; then
  _xos_auto="설치"
elif [ "${_DPM_XOS_HAS_INSTALL:-0}" = "1" ]; then
  _xos_auto="일부설치"
else
  _xos_auto="미설치"
fi
[ "${_DPM_XOS_MISSING_COUNT:-0}" -gt 0 ] && warn "XOS 미설치 에이전트 (수기 작성 필요)" "${_DPM_XOS_MISSING_COUNT}대: $(echo "$_DPM_XOS_MISSING" | xargs)"
ok "XOS 설치 여부 (자동 판정)" "$_xos_auto"
if [ "${_has_dpm:-0}" -gt 0 ] 2>/dev/null; then
  read -r $_READ_E -p "  XOS 설치 여부 확정 (Enter=${_xos_auto}, 수정 시 설치/미설치/일부설치 입력): " _xos_input || true
  XOS_INSTALLED="${_xos_input:-$_xos_auto}"
else
  XOS_INSTALLED="$_xos_auto"
fi
ok "XOS 설치 여부 (확정)" "$XOS_INSTALLED"
if [ "${_DPM_XOS_HAS_INSTALL:-0}" = "1" ]; then
  read -r $_READ_E -p "  XOS 코어 수 확정 (Enter=자동집계 ${DPM_XOS_CORES:-0}core, 수정 시 숫자 입력): " _cores_input || true
  [ -n "$_cores_input" ] && DPM_XOS_CORES="$_cores_input"
  [ -n "$DPM_XOS_CORES" ] && ok "XOS 코어 수 (확정)" "${DPM_XOS_CORES}core"
fi

# ── CPM: 모든 CPM 프로젝트 순회 → 버전/에이전트/kubelet 집계
CPM_VERSION=""
KUBELET_VERSION=""
CONTAINER_RUNTIME=""
_CPM_KUBELET_RAW=""
_CPM_TOTAL_AGENTS=0
_CPM_TOTAL_NODE=0
_CPM_TOTAL_MASTER=0
_CPM_TOTAL_UNINSTALLED=0
_CPM_VERSIONS=""
_CPM_KUBELET_VERSIONS=""
_CPM_RUNTIMES=""
# kube_node 조회 창: 5분은 너무 좁아 콘솔에 노드 정보가 있는 클러스터도 빈 배열이 오는 사례가 있었다.
# (마스터 에이전트의 노드 태그 전송 주기가 길거나 직전 전송이 창 밖이면 놓친다) → 1시간으로 확대.
_CPM_STIME=$(( $(date +%s) * 1000 - 3600000 ))
_CPM_ETIME=$(( $(date +%s) * 1000 ))
_CPM_MQL="CATEGORY kube_node\nTIME-RANGE {recent: 1h}\nTAGLOAD {backward: true}\nSELECT"
_CPM_FOUND=0
_CPM_K8S_DISTRO=""
_CPM_OPERATOR_VERSION=""
_CPM_PROJ_JSON=""

while IFS= read -r proj_block; do
  _pcode=$(echo "$proj_block" | grep -o '"projectCode"[^,}]*' | grep -o '[0-9]\+')
  _token=$(echo "$proj_block" | grep -o '"apiToken":"[^"]*"' | cut -d'"' -f4)
  _name=$(echo "$proj_block" | grep -o '"projectName":"[^"]*"' | cut -d'"' -f4)
  [ -z "$_pcode" ] || [ -z "$_token" ] && continue

  info "CPM 에이전트 조회 (pcode=$_pcode, $_name)..."
  fetch_agents "$_pcode" "$_token" "CPM"
  _resp="$_AG_RESP"
  # 활성 에이전트만 집계 (비활성 = 과거에 붙었다 끊긴 에이전트)
  _ag_all=$(_agents_parse "$_resp"); _agents_stats "$_ag_all"; _agents_tally
  _ag=$(printf '%s' "$_ag_all" | _agents_filter)
  _cnt=$(printf '%s' "$_ag" | grep -c . || true)
  _resp_act=$(printf '%s' "$_resp" | tr '{' '\n' | grep '"oid"' | grep -v '"active":false' || true)

  if [ "${_cnt:-0}" -gt 0 ] 2>/dev/null; then
    _CPM_FOUND=1
    _ver=$(_ver_pick "$_resp_act")
    _node=$(printf '%s' "$_ag" | awk -F'\t' '$2=="node"' | grep -c . || true)
    _master=$(printf '%s' "$_ag" | awk -F'\t' '$2=="master"' | grep -c . || true)
    [ "${_AG_INACTIVE:-0}" -gt 0 ] 2>/dev/null && info "  └ 비활성 ${_AG_INACTIVE}대 제외 (응답 전체 ${_AG_TOTAL}대)"
    # 설치된 에이전트만 집계한다. 응답에는 콘솔의 UNINSTALLED 항목(노드는 있는데 에이전트 미설치)도
    # 섞여 오는데, 이건 oid 는 있지만 subtypeName 이 없어 master+node 합과 총 개수가 어긋난다.
    # (예: 콘솔 "노드 에이전트 전체 3 = ACTIVE 2 + UNINSTALLED 1" → oid 4, master1+node2)
    _installed=$(( _master + _node ))
    _uninst=$(( _cnt - _installed ))
    [ "$_uninst" -lt 0 ] && _uninst=0
    if [ "$_uninst" -gt 0 ]; then
      ok "CPM [$_name] 에이전트" "마스터 ${_master}대 노드 ${_node}대 (설치 ${_installed}대 / 미설치 ${_uninst}대 제외) / 버전: ${_ver:-?}"
    else
      ok "CPM [$_name] 에이전트" "마스터 ${_master}대 노드 ${_node}대 (총 ${_installed}대) / 버전: ${_ver:-?}"
    fi

    _CPM_TOTAL_AGENTS=$(( _CPM_TOTAL_AGENTS + _installed ))
    _CPM_TOTAL_UNINSTALLED=$(( _CPM_TOTAL_UNINSTALLED + _uninst ))
    _CPM_TOTAL_NODE=$(( _CPM_TOTAL_NODE + _node ))
    _CPM_TOTAL_MASTER=$(( _CPM_TOTAL_MASTER + _master ))
    # 버전 목록 누적 (중복 제거용)
    _CPM_VERSIONS=$(printf '%s\n%s' "$_CPM_VERSIONS" "$_ver" | grep -v '^$' | sort -u | tr '\n' ',' | sed 's/,$//')

    # kubelet / container runtime / 노드 OS (MXQL) — 노드 전체 태그를 받아 마스터 노드를 골라낸다
    _kube_resp=$(curl -skL ${_CURL_HTTP11} --connect-timeout 10 --max-time 30 \
      -X POST "$WHATAP_API_HOST/open/api/json/mxql/text" \
      -H "Content-Type: application/json" \
      -H "x-whatap-token: $_token" \
      -H "x-whatap-pcode: $_pcode" \
      -d "{\"stime\":${_CPM_STIME},\"etime\":${_CPM_ETIME},\"mql\":\"${_CPM_MQL}\",\"limit\":100}" 2>/dev/null || echo "")
    _kv=$(echo "$_kube_resp" | grep -o '"kubeletVersion":"[^"]*"' | head -1 | cut -d'"' -f4)
    _cr=$(echo "$_kube_resp" | grep -o '"containerRuntimeVersion":"[^"]*"' | head -1 | cut -d'"' -f4)

    # 노드 osImage — 보고서에는 싣지 않고 K8s 배포판 추정에만 쓴다.
    #   (어느 노드가 control-plane 인지 가리는 로직은 노드 OS 항목과 함께 제거)
    _node_os=$(echo "$_kube_resp" | grep -o '"osImage":"[^"]*"' | head -1 | cut -d'"' -f4)
    [ -n "$_kv" ] && ok "  └ Kubelet 버전" "$_kv"
    [ -n "$_cr" ] && ok "  └ 컨테이너 런타임" "$_cr"
    if [ -z "$_kv" ]; then
      if [ "$(echo "$_kube_resp" | tr -d ' \n')" = "[]" ]; then
        warn "  └ Node 정보" "kube_node 데이터 없음 — 네임스페이스 단위 프로젝트면 정상(클러스터 지표는 상위 클러스터 프로젝트에 있음). 클러스터 프로젝트인데 콘솔에는 노드 정보가 보인다면 수기 확인 필요"
      else
        warn "  └ kube_node 응답 원문" "$(echo "$_kube_resp" | head -c 200)"
      fi
    fi
    # kubelet 버전은 프로젝트별로 다를 수 있어 "버전 (프로젝트명)" 형태로 누적 (루프 후 중복제거)
    [ -n "$_kv" ] && _CPM_KUBELET_RAW=$(printf '%s\n%s (%s)' "$_CPM_KUBELET_RAW" "$_kv" "$_name")
    [ -n "$_cr" ] && _CPM_RUNTIMES=$(printf '%s\n%s' "$_CPM_RUNTIMES" "$_cr")
    # K8s 배포판 감지 (마스터 노드 osImage 기반 추정)
    _distro=""
    case "$_node_os" in
      *[Aa]mazon*|*[Aa][Ll][2-9]*) _distro="EKS" ;;
      *[Rr]ed[Hh]at*|*[Oo]pen[Ss]hift*) _distro="OpenShift" ;;
      *[Nn]aver*|*[Nn][Kk][Ss]*) _distro="NKS" ;;
      *[Gg][Kk][Ee]*|*[Gg]oogle*) _distro="GKE" ;;
      *[Aa][Kk][Ss]*|*[Aa]zure*) _distro="AKS" ;;
    esac
    [ -n "$_distro" ] && ok "  └ K8s 배포판 추정" "$_distro"
    _CPM_K8S_DISTRO=$(printf '%s\n%s' "$_CPM_K8S_DISTRO" "$_distro" | grep -v '^$' | sort -u | tr '\n' ',' | sed 's/,$//')

    # Operator 버전: 프로젝트(클러스터)마다 다를 수 있어 매 프로젝트 조회 (whatap-operator 이미지 태그)
    _cimg=$(curl -skL ${_CURL_HTTP11} --connect-timeout 10 --max-time 30 \
      -X POST "$WHATAP_API_HOST/open/api/json/mxql/text" \
      -H "Content-Type: application/json" \
      -H "x-whatap-token: $_token" \
      -H "x-whatap-pcode: $_pcode" \
      -d "{\"stime\":${_CPM_STIME},\"etime\":${_CPM_ETIME},\"mql\":\"CATEGORY container\\nTAGLOAD\\nSELECT\",\"limit\":500}" 2>/dev/null || echo "")
    _op_img=$(echo "$_cimg" | tr '{' '\n' | grep '"namespace":"whatap-monitoring"' \
      | grep -o '"image":"[^"]*whatap-operator[^"]*"' | head -1 | cut -d'"' -f4)
    _op_ver=$(echo "$_op_img" | grep -o ':[^:]*$' | tr -d ':')
    [ -n "$_op_ver" ] && ok "  └ Operator 버전" "$_op_ver"
    [ -n "$_op_ver" ] && [ -z "$_CPM_OPERATOR_VERSION" ] && _CPM_OPERATOR_VERSION="$_op_ver"

    # 프로젝트(클러스터)별 매핑 행: 런타임/kubelet/마스터 OS/K8s 종류/Operator 버전을 한 줄로 묶는다
    _CPM_PROJ_JSON="${_CPM_PROJ_JSON}${_CPM_PROJ_JSON:+,}{\"pcode\":\"$(_j "$_pcode")\",\"name\":\"$(_j "$_name")\",\"version\":\"$(_j "$_ver")\",\"agentCount\":$(( _installed )),\"agentCountUninstalled\":$(( _uninst )),\"agentCountMaster\":$(( _master )),\"agentCountNode\":$(( _node )),\"kubeletVersion\":\"$(_j "$_kv")\",\"containerRuntime\":\"$(_j "$_cr")\",\"k8sDistro\":\"$(_j "$_distro")\",\"operatorVersion\":\"$(_j "$_op_ver")\"}"
  else
    if [ "${_AG_FAIL:-0}" = "1" ]; then
      # 조회 자체가 실패했다 — 0대로 세면 확인서에 '미설치' 로 박힌다. 집계하지 않고 실패로 남긴다.
      _CPM_QFAIL=$(( _CPM_QFAIL + 1 ))
      fail "CPM [$_name]" "에이전트 조회 실패 (pcode=$_pcode, HTTP ${_AG_HTTP:-연결실패}) — 0대로 집계하지 않습니다"
    else
      warn "CPM [$_name]" "에이전트 미연결 (pcode=$_pcode) — 응답: $(echo "$_resp" | head -c 200)"
    fi
  fi
done << _CPM_EOF
$(echo "$PROJECTS" | tr '{' '\n' | grep -i '"CPM"' || true)
_CPM_EOF

if [ "$_CPM_FOUND" = "1" ]; then
  CPM_VERSION="$_CPM_VERSIONS"
  KUBELET_VERSION=$(printf '%s' "$_CPM_KUBELET_RAW" | awk 'NF && !seen[$0]++ { out = out (out?", ":"") $0 } END { print out }')
  CONTAINER_RUNTIME=$(printf '%s' "$_CPM_RUNTIMES" | awk 'NF && !s[$0]++{o=o (o?", ":"")$0} END{print o}')
  CPM_K8S_DISTRO="$_CPM_K8S_DISTRO"
  # 입력 단계에서 operator 미감지였는데 루프에서 발견되면 보정
  if [ -z "$CPM_OPERATOR_VERSION" ] && [ -n "$_CPM_OPERATOR_VERSION" ]; then
    CPM_OPERATOR_VERSION="$_CPM_OPERATOR_VERSION"
    CPM_INSTALL_METHOD="Operator"
    ok "CPM 설치 방식 (자동)" "Operator — operator 이미지 감지 (버전 ${CPM_OPERATOR_VERSION})"
  fi
  [ -n "$CPM_K8S_DISTRO" ] && ok "K8s 배포판 추정" "$CPM_K8S_DISTRO"
  read -r $_READ_E -p "  K8s 배포판 직접 입력 (자동 추정값 사용 시 Enter, 예: EKS/OpenShift/NKS/GKE/AKS): " _k8s_input || true
  [ -n "$_k8s_input" ] && CPM_K8S_DISTRO="$_k8s_input"
  [ -n "$CPM_K8S_DISTRO" ] && ok "K8s 배포판 확정" "$CPM_K8S_DISTRO"
  if [ "$_CPM_TOTAL_UNINSTALLED" -gt 0 ]; then
    ok "CPM 전체 에이전트" "마스터 ${_CPM_TOTAL_MASTER}대 노드 ${_CPM_TOTAL_NODE}대 (설치 ${_CPM_TOTAL_AGENTS}대 / 미설치 노드 ${_CPM_TOTAL_UNINSTALLED}대 제외)"
  else
    ok "CPM 전체 에이전트" "마스터 ${_CPM_TOTAL_MASTER}대 노드 ${_CPM_TOTAL_NODE}대 (총 ${_CPM_TOTAL_AGENTS}대)"
  fi
  [ -n "$CPM_INSTALL_METHOD" ] && ok "CPM 설치 방식" "$CPM_INSTALL_METHOD" || warn "CPM 설치 방식" "미확인"
  [ -n "$CPM_OPERATOR_VERSION" ] && ok "Operator 버전" "$CPM_OPERATOR_VERSION"
  ok "CPM 에이전트 버전(통합)" "$CPM_VERSION"
  [ -n "$KUBELET_VERSION" ] && ok "Kubelet 버전(통합)" "$KUBELET_VERSION" || warn "Kubelet 버전" "조회 실패"
  [ -n "$CONTAINER_RUNTIME" ] && ok "컨테이너 런타임(통합)" "$CONTAINER_RUNTIME" || warn "컨테이너 런타임" "조회 실패"
else
  if [ "${_CPM_QFAIL:-0}" -gt 0 ] 2>/dev/null; then
    fail "CPM" "프로젝트 ${_CPM_QFAIL}개 조회 실패 — 설치 여부를 확인하지 못했습니다 (미설치와 다릅니다)"
  else
    warn "CPM" "CPM 프로젝트 없음 또는 모든 프로젝트 에이전트 미연결"
  fi
fi

# ══════════════════════════════════════════
# 5. JSON 저장 & 문서 생성
# ══════════════════════════════════════════
section "JSON 저장 및 문서 생성"

# 에이전트 조회에 실패한 프로젝트가 있으면, JSON 을 저장하기 전에 한 번 더 크게 알린다.
#   (제품 섹션마다 흩어져 지나간 실패는 스크롤에 묻힌다 — 여기서 못 보면 확인서의
#    "0대 / 해당 제품 없음" 을 사실로 믿게 된다)
if [ -n "${_AGENT_QUERY_FAIL:-}" ]; then
  echo ""
  fail "에이전트 조회 실패" "$_AGENT_QUERY_FAIL"
  echo -e "  ${RED}▶ 위 프로젝트는 '0대'가 아니라 '확인 못 함' 입니다. 확인서에 그대로 쓰지 마세요.${NC}"
  echo -e "  ${RED}  수집서버/네트워크를 확인하고 스크립트를 다시 실행하는 것을 권장합니다.${NC}"
  echo ""
fi

# 지금까지 수집된 값으로 collected_data.json 생성 (조립 로직은 상단 emit_main_json()).
# 이후 디스크 스캔(6번)이 오래 걸리거나 중단돼도 설치확인서 JSON 은 이미 안전하게 저장됨.
emit_main_json

# ══════════════════════════════════════════
# 6. 디스크 용량 수집 (yardbase 스캔)
# ══════════════════════════════════════════
# disk_check/collect/collect.sh 의 수집 로직을 통합.
# yardbase 를 1회 순회하며 파일을 데이터 종류로 분류하고, project.conf 의
# 프로젝트(pcode)별 메타(productType/platform/keep*)와 합쳐 별도 JSON(disk_usage.json)으로 출력한다.
# (사내 estimate.py / web/index.html 로 디스크 용량 산정 시 입력으로 사용)
section "디스크 용량 수집 (yardbase 스캔)"

# ── yardbase 경로 자동 결정 (인자 불필요) ──
# yard.conf 의 yardbase(위 3번 섹션 파싱) 우선. 상대경로면 설치경로 기준 해석,
# 비어있으면 설치경로/yardbase 기본값. 그래도 없으면 설치경로 하위를 탐색.
_DISK_ROOT="$YARDBASE"
case "$_DISK_ROOT" in
  /*) : ;;                                                 # 절대경로 그대로
  "") _DISK_ROOT="$SERVER_INSTALL_PATH/yardbase" ;;        # yard.conf 에 yardbase 없음 → 기본값
  *)  _DISK_ROOT="$SERVER_INSTALL_PATH/${_DISK_ROOT#./}" ;; # 상대경로 → 설치경로 기준
esac
if [ ! -d "$_DISK_ROOT" ] && [ -d "$SERVER_INSTALL_PATH" ]; then
  _alt=$(find "$SERVER_INSTALL_PATH" -maxdepth 4 -type d -name yardbase 2>/dev/null | head -1 || true)
  [ -n "$_alt" ] && _DISK_ROOT="$_alt"
fi

# ── project.conf 자동 감지 (인자 불필요) ──
# 설치경로/conf/project.conf 우선 → 없으면 설치경로 하위 탐색 → yardbase 인접 탐색.
_DISK_CONF="$SERVER_INSTALL_PATH/conf/project.conf"
if [ ! -f "$_DISK_CONF" ]; then
  _c=""
  [ -d "$SERVER_INSTALL_PATH" ] && _c=$(find "$SERVER_INSTALL_PATH" -maxdepth 4 -type f -name project.conf 2>/dev/null | head -1 || true)
  [ -z "$_c" ] && [ -d "$_DISK_ROOT" ] && _c=$(find "$_DISK_ROOT/.." -maxdepth 2 -type f -name project.conf 2>/dev/null | head -1 || true)
  [ -n "$_c" ] && _DISK_CONF="$_c"
fi

# ── yardbase 가 여러 개로 갈린 사이트 대응 ──
#   YardBaseConfig.getYardBaseList() 는 conf/yardbase.conf(날짜별)·conf/projectbase.conf(프로젝트별)
#   를 읽어 base 를 여러 개 반환한다(YardBaseConfigFactory:22). 디스크를 증설한 사이트가 이걸 쓰는데,
#   기본 base 하나만 훑으면 총량이 통째로 미달로 나온다.
#   포맷이 사이트마다 달라 절대경로 토큰만 뽑고, 실제 존재하는 디렉터리만 채택한다.
_DISK_ROOTS="$_DISK_ROOT"
for _bc in "$SERVER_INSTALL_PATH/conf/yardbase.conf" "$SERVER_INSTALL_PATH/conf/projectbase.conf"; do
  [ -f "$_bc" ] || continue
  info "yardbase 분산 설정 감지: $_bc"
  while IFS= read -r _cand; do
    [ -n "$_cand" ] && [ -d "$_cand" ] || continue
    case "
$_DISK_ROOTS
" in *"
$_cand
"*) continue ;; esac                       # 이미 목록에 있음
    _DISK_ROOTS="$_DISK_ROOTS
$_cand"
    ok "추가 yardbase" "$_cand"
  done <<EOF
$(grep -v '^[[:space:]]*#' "$_bc" 2>/dev/null | grep -oE '/[^[:space:],;"'"'"']+' | sed 's#/*$##' | sort -u)
EOF
done
_DISK_ROOT_CNT=$(printf '%s
' "$_DISK_ROOTS" | grep -c .)
[ "$_DISK_ROOT_CNT" -gt 1 ] && warn "yardbase 다중" "${_DISK_ROOT_CNT}개 base 를 모두 순회합니다 — 하나만 보면 총량 미달"

if [ ! -d "$_DISK_ROOT" ]; then
  fail "디스크 수집" "yardbase 디렉터리 없음: $_DISK_ROOT — 디스크 JSON 없음, 건너뜀"
elif ! find "$_DISK_ROOT" -maxdepth 0 -printf '' >/dev/null 2>&1; then
  fail "디스크 수집" "find -printf 미지원(비 GNU find) — 디스크 JSON 없음, 건너뜀"
else
  echo ""
  warn "디스크 용량 수집 주의" "yardbase 전체 파일을 순회(find)합니다. 용량/파일수가 많으면 수 분~수십 분 소요되고 디스크 I/O 부하가 올라갈 수 있습니다."
  info "대상 경로: $_DISK_ROOT"
  read -r $_READ_E -p "  디스크 용량을 수집할까요? (Enter=미수집 / y=수집): " _disk_go || true
  if ! printf '%s' "${_disk_go:-}" | grep -qiE '^[[:space:]]*(y|예)'; then
    # 미수집(Enter 기본값)이면 빈 JSON 도 남기지 않는다 — 빈 파일이 있으면 "수집했는데 0"
    # 으로 오해된다. 이전 실행이 남긴 파일도 함께 지워 오래된 값이 섞이지 않게 한다.
    rm -f "$DISK_OUTPUT_JSON" 2>/dev/null
    warn "디스크 수집" "미수집 — 디스크 JSON 을 만들지 않음"
  else
  # 스캔 중 중단돼도 유효한 JSON 이 남도록 스켈레톤 선기록 (성공 시 전체 데이터로 교체)
  write_disk_skeleton
  info "yardbase 스캔 중: $_DISK_ROOT (전체 파일 순회 — 파일 수에 따라 수 분 소요될 수 있음)"
  if [ -f "$_DISK_CONF" ]; then ok "project.conf (자동 감지)" "$_DISK_CONF"
  else warn "project.conf" "자동 감지 실패 — 프로젝트 메타 없이 크기만 수집"; fi

  _DISK_HOST="$(hostname 2>/dev/null || echo unknown)"
  _DISK_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
  _DISK_ROOT_ABS="$(cd "$_DISK_ROOT" 2>/dev/null && pwd || echo "$_DISK_ROOT")"
  _DISK_SIZE_MODE="apparent"   # apparent size 기준 (블록 점유 아님)
  _DISK_INTERVAL=1             # 관측 수집간격(초) — realtime_interval=1000ms 기본
  _DISK_TMP="${DISK_OUTPUT_JSON}.part"
  _DISK_FIND_ERR="${DISK_OUTPUT_JSON}.err"   # find 권한오류 기록 → 과소집계 경고용
  _HAVE_CONF=0; [ -f "$_DISK_CONF" ] && _HAVE_CONF=1
  # find 시작점 배열 — 여러 base 를 한 번에 넘긴다. %P 는 '그 시작점 기준' 상대경로라
  #   base 가 여러 개여도 pcode 부터 시작하는 같은 모양의 경로가 나온다.
  _ROOT_ARGS=()
  while IFS= read -r _r; do [ -n "$_r" ] && _ROOT_ARGS+=("$_r"); done <<EOF
$_DISK_ROOTS
EOF
  # 워크스페이스 프로젝트는 pcode 가 숫자가 아니라(WsKey.dirName() = w{wsid}/{wsid}-{product}-{sysid})
  #   projects[] 에 안 잡히고 root_files 로만 계상된다. 있으면 알린다.
  _WS_SEEN=$(ls "$_DISK_ROOT" 2>/dev/null | grep -cE '^w[0-9]+$' || echo 0)
  [ "${_WS_SEEN:-0}" -gt 0 ] 2>/dev/null && warn "워크스페이스 감지" "${_WS_SEEN}개 (w*/) — 프로젝트별 산정에서 빠집니다(root_files 로만 계상)"

  # 프로젝트별 TPS 수집(profile 용량 산정용): APM 프로젝트마다 app_counter{h1} 최근 3h 합산
  _TPS_MAP="$(mktemp 2>/dev/null || echo "/tmp/whatap_tps.$$")"; : > "$_TPS_MAP"
  if [ -n "${PROJECTS:-}" ] && [ -n "${WHATAP_API_HOST:-}" ]; then
    _t_now=$(( $(date +%s) * 1000 )); _t_st=$(( _t_now - 10800000 ))
    echo "$PROJECTS" | tr '{' '\n' | grep -i '"APM"' | while IFS= read -r _pl; do
      _pc=$(echo "$_pl" | grep -o '"projectCode"[^,}]*' | grep -o '[0-9]\+')
      _tk=$(echo "$_pl" | grep -o '"apiToken":"[^"]*"' | cut -d'"' -f4)
      { [ -z "$_pc" ] || [ -z "$_tk" ]; } && continue
      _rr=$(curl -skL ${_CURL_HTTP11} --connect-timeout 10 --max-time 30 \
        -X POST "$WHATAP_API_HOST/open/api/json/mxql/text" \
        -H "Content-Type: application/json" -H "x-whatap-token: $_tk" -H "x-whatap-pcode: $_pc" \
        -d "{\"stime\":${_t_st},\"etime\":${_t_now},\"mql\":\"CATEGORY app_counter{h1}\\nTAGLOAD\\nSELECT\",\"limit\":500}" 2>/dev/null || echo "")
      _tps=$(echo "$_rr" | tr '{' '\n' | grep '"oname"' | awk '{ if (match($0,/"tps":[0-9.eE+-]+/)) s+=substr($0,RSTART+6,RLENGTH-6) } END{ if(NR>0) printf "%.2f", s }')
      [ -n "$_tps" ] && printf '%s\t%s\n' "$_pc" "$_tps" >> "$_TPS_MAP"
    done
  fi

  # project.conf → @CONF@ 접두 후 find -printf 스트림을 이어 붙여 1회 순회로 집계.
  # 스캔은 임시파일(.part)에 쓰고 성공 시에만 원자적으로 교체 → 중단돼도 스켈레톤 유지.
  if { sed 's/^/@TPS@/' "$_TPS_MAP" 2>/dev/null || true; \
       [ -f "$_DISK_CONF" ] && sed 's/^/@CONF@/' "$_DISK_CONF" 2>/dev/null || true; \
       find "${_ROOT_ARGS[@]}" -type f -printf '%s\t%P\n' 2>"$_DISK_FIND_ERR"; } \
     | _J_HOST="$_DISK_HOST" _J_ROOT="$_DISK_ROOT_ABS" _J_CUST="$CUSTOMER_NAME" _J_ROOTS="$_DISK_ROOTS" \
       LC_ALL=C awk -v now="$_DISK_NOW" \
           -v smode="$_DISK_SIZE_MODE" -v interval="$_DISK_INTERVAL" -v blk=0 \
           -v haveconf="$_HAVE_CONF" -v diskcap="$SERVER_DISK_BYTES" \
           -v logkeep1="${LOGSINK_KEEP:-}" -v logkeepm="${LOGSINK_MCUBE_KEEP:-}" '
    # 문자열 값은 -v 대신 ENVIRON 으로 받는다: awk 는 -v 값의 이스케이프 시퀀스를
    # 먼저 해석해버려(예: 고객사명 "A\nB" → 실제 개행) jesc() 가 손쓸 수 없게 되고
    # JSON 에 raw 개행이 박혀 파싱이 불가해진다. ENVIRON 은 해석하지 않는다.
    BEGIN { host=ENVIRON["_J_HOST"]; root=ENVIRON["_J_ROOT"]; cust=ENVIRON["_J_CUST"]
            # 여러 base 를 훑었으면 목록을 남긴다 — 나중에 "총량이 왜 이래" 할 때 근거가 된다
            nr=split(ENVIRON["_J_ROOTS"], rr, "\n")
            for(i=1;i<=nr;i++) if(rr[i]!="") roots = roots (roots==""?"":", ") "\"" jesc(rr[i]) "\"" }
    # 제어문자(탭/개행/CR)는 JSON 문자열에 raw 로 들어갈 수 없어 공백으로 치환
    function jesc(s){ gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); gsub(/[\t\n\r]/," ",s); return s }
    # project.conf 한 줄에서 "key: value" 추출 (value 는 , 또는 } 전까지)
    function field(line, key,   re, v){
      re = key ": *"
      if (match(line, re "[^,}]*")) { v=substr(line,RSTART,RLENGTH); sub(re,"",v);
        gsub(/^[ \t]+|[ \t]+$/,"",v); return v }
      return ""
    }
    # 프로젝트 루트(= 날짜 폴더가 아닌 영역) 판별.
    #   기본 설치는 폴더명이 20000101, 워크스페이스 pcode 만 project-inf
    #   (yard_project_inf_enabled 기본 false — 폐쇄망 현장에서는 20000101 로 찾아야 한다).
    function isperm(rel){ return rel ~ /^[0-9]+\/(project-inf|20000101)(\/|$)/ }

    # 파일 경로/이름 → "type\ttier\trtier" (순서=우선순위, 첫 매칭)
    # V4 코드 기준 분류(type\ttier\tretention_tier). 순서=우선순위.
    function classify(rel, fn){
      # 만료돼 rename 된 tombstone 폴더. 안쪽 경로 모양이 원본과 같아서 이 규칙이 맨 앞에 없으면
      #   이미 지워질 데이터가 살아있는 tagc/cube 로 잡혀 총량이 부풀고 보관정책 산정도 틀어진다.
      if (rel ~ /(^|\/)\.reclaim\//)     return "reclaim\tstatic\treclaim"
      if (rel ~ /(^|\/)logsinkm\//        || rel ~ /(^|\/)logsink1\/.*\/mcube\//) return "logsinkm\tm5\tlogsinkm"
      if (rel ~ /(^|\/)logsink1\//)        return "logsink1\traw\tlogsink1"
      # ── 프로젝트 루트(perm): 쓰기는 계속되는데 보관주기로는 절대 안 지워지는 단조 증가 영역 ──
      #   TextPermDB 가 isPerm 텍스트(METHOD·DB_URL·HTTPC_HOST·USER_AGENT_*·OS_MOUNT_POINT 등)를
      #   날짜 없는 프로젝트 루트(DBConf.getIRoot(pcode,0,0))에 append 한다 — 에이전트가 새 method 나
      #   mount point, 브라우저 UA 를 처음 보낼 때마다 계속 늘어난다.
      #   디스크클린(ProjectDiskMgr2)은 폴더명을 날짜로 파싱하다 여기서 걸러내고("DIR(..) is Not Valid!!"),
      #   deleteOidFolder() 도 0 폴더는 continue 로 건너뛴다 → '변경 없음' 이 아니라 '삭제 대상이 아님'.
      if (isperm(rel)) {
        # .hmap 은 항목 수와 무관한 고정 선할당이라 .data(실제 텍스트) 와 따로 센다 — 아래 주석 참고
        if (fn ~ /^text2\./)               return (fn ~ /\.hmap$/) ? "text_perm_idx\tstatic\tperm" : "text_perm\tstatic\tperm"
        # 만료 날짜폴더 정리 때 text 파일은 삭제가 아니라 0/longTerm/{yyyymmdd}/ 로 '이동' 된다
        #   (deleteTagForce, V3 레이아웃 한정). 파일명은 text3-{TYPE}.hmap/.data 인데 경로에 text3/ 가
        #   없어서 text3 규칙에 안 걸린다 → 따로 잡지 않으면 proj_perm 에 묻혀 원인을 못 찾는다.
        if (rel ~ /(^|\/)longTerm\// && fn ~ /^text/) return "text_moved\tstatic\tperm"
        # 비정상 타임스탬프 데이터가 루트에 생기는 경우(deleteOidFolderIn:601 이 20000101 하위의
        #   S00·_hvtxt_ 를 지우는 분기를 갖고 있다 = 생길 수 있다는 뜻). 진단용으로 따로 표시.
        if (rel ~ /(^|\/)(S[0-9]+|_hvtxt_)\//)   return "perm_stray\tstatic\tperm"
        # longTerm/{yyyymmdd}/(db3_agent_mapping 등), _filter_/{yyyymmdd}/
        #   → 날짜 폴더가 안에 있어 증가 속도를 잴 수 있다(삭제는 여전히 안 됨).
        if (rel ~ /(^|\/)(longTerm|_filter_)\//) return "perm_longterm\tstatic\tperm"
        return "proj_perm\tstatic\tperm"                                      # {oid}/config·frontmeta 등
      }
      # ── 날짜 폴더 하위(dtfolder): 전용 컷오프는 없지만 날짜 폴더가 만료되면 통째로 사라진다 ──
      # ⚠️ .hmap 은 생성 시 고정 크기를 0 으로 채워 통째로 write 한다(HashMapFile:57 — sparse 아님).
      #   항목 수와 무관하게 크기가 일정하다: SQL·SERVICE·HTTPC_URL 2.5MB, DB_URL·HTTPC_HOST·OKIND·
      #   ONAME 등 0.25MB, 나머지 0.5MB (Text3DailyDB:271, Configure:641).
      #   → text3 총량 ≈ 관측일수 × 활성 타입 수 × 고정크기. "텍스트가 많다" 로 읽으면 오해다.
      #   .data(실제 텍스트) 와 갈라 담아야 '실제 양 vs 인덱스 선할당' 을 설명할 수 있다.
      if (rel ~ /(^|\/)text3\//)           return (fn ~ /\.hmap$/) ? "text3_idx\tstatic\tdtfolder" : "text3\tstatic\tdtfolder"
      if (fn  ~ /^text2\./)                return (fn ~ /\.hmap$/) ? "text_daily_idx\tstatic\tdtfolder" : "text_daily\tstatic\tdtfolder"
      if (rel ~ /(^|\/)_?hvtxt_?\//)       return "hvtxt\tstatic\tdtfolder"       # v4 {hh}/hvtxt/, 구버전 _hvtxt_/{hh}/
      if (rel ~ /(^|\/)meta-inf(\/|$)/)    return "meta_inf\tstatic\tdtfolder"    # {pcode}/{yyyymmdd}/meta-inf/ (일별)
      if (rel ~ /(^|\/)open\//)            return "openmx\traw\topenmx"
      if (rel ~ /(^|\/)project-inf(\/|$)/) return "proj_perm\tstatic\tperm"      # 루트가 아닌 위치에 있어도 성격은 동일
      # TagCount 는 {HH}/tagc/ 뿐 아니라 샤드 폴더 S00~S{nn}/ 에도 들어간다.
      #   샤드를 빼먹으면 {m5}(400일)·{h1}(999일) 데이터가 raw(37일)로 잡혀 크게 과소 산정된다.
      if (rel ~ /(^|\/)(tagc|S[0-9]+)\/.*\{h1\}/) return "tagc_h1\th1\th1"
      if (rel ~ /(^|\/)(tagc|S[0-9]+)\/.*\{m5\}/) return "tagc_m5\tm5\tm5"
      if (rel ~ /(^|\/)(tagc|S[0-9]+)\/.*\{m1\}/) return "tagc_m1\tm1\tm5"
      # 마커 없는 stat_* 이 tagc/샤드 폴더에 있을 수 있다. 아래 tagc 폴백보다 먼저 봐야
      #   통계(5분=400일)가 tagc_raw(37일)로 잡혀 과소 산정되는 일이 없다.
      if (fn  ~ /stat_.*\{h1\}/)           return "stat_h1\th1\th1"
      if (rel ~ /(^|\/)(db3_)?stat_/)      return "stat_m5\tm5\tm5"
      if (rel ~ /(^|\/)(tagc|S[0-9]+)\//)          return "tagc_raw\traw\traw"
      if (fn  ~ /^h[0-9].*\.(cub|cos|cdb|cuv)$/ || fn ~ /-H[0-9]+\.(cub|cos|cdb|cuv)$/) return "cube_h1\th1\th1"
      if (fn  ~ /^m[0-9].*\.(cub|cos|cdb|cuv)$/ || fn ~ /-[0-9]+\.(cub|cos|cdb|cuv)$/ || rel ~ /(^|\/)cube\//) return "cube_m5\tm5\tm5"
      if (rel ~ /(^|\/)(db3_)?dbx_min_counter/) return "dbx_min_counter\tm1\traw"
      if (rel ~ /(^|\/)(db3_)?dbx_/)       return "dbx\traw\traw"
      if (rel ~ /(^|\/)db3_kube_/)         return "kube\traw\traw"
      # ⚠️ 사전이라고 perm 이 아니다. AgentDictionaryDBv3 는 AbstractTimeDB 상속 →
      #   {yyyymmdd}/{HH}/db3/ 에 시간마다 다시 쌓이고 날짜 폴더째 만료된다.
      if (rel ~ /(^|\/)db3_(agent|container)_dic/) return "agent_dic\traw\traw"
      if (rel ~ /(^|\/)db3_agent_mapping/) return "agent_mapping\traw\traw"   # perm 루트 밖에 있을 때
      if (rel ~ /(^|\/)(db3_)?sm_/)        return "sm\traw\traw"
      if (rel ~ /(^|\/)(db3_)?counter\./)  return "counter\traw\traw"
      if (rel ~ /(^|\/)(db3_)?profile/ || rel ~ /(^|\/)db3_prof_mt/ || rel ~ /(^|\/)db3_step_split/) return "profile\traw\tprofile"
      if (rel ~ /(^|\/)(db3_)?(rum_|pageload_)*hit(map|view)/) return "hitmap\traw\traw"
      if (rel ~ /(^|\/)(db3_)?event\./)    return "event\traw\traw"
      if (rel ~ /(^|\/)(db3_)?err_snap/)   return "err_snap\traw\traw"
      if (rel ~ /(^|\/)(db3_)?act\./)      return "act\traw\traw"
      if (rel ~ /(^|\/)(db3_)?(rt_user|readtime_user)/) return "rt_user\traw\traw"
      if (rel ~ /(^|\/)(db3_)?journal/)    return "journal\traw\traw"
      if (rel ~ /(^|\/)keyval_(hour|day)\//) return "keyval\traw\traw"
      if (rel ~ /(^|\/)shard\.factor$/)   return "proj_perm\tstatic\tperm"   # 샤드 개수(4byte), 삭제 안 됨
      # {yyyymmdd}/{oid}/ 의 ISAM 파일셋 — 위 이름 규칙에 안 걸린 나머지. 전용 컷오프가 없어 keep(raw).
      if (fn  ~ /\.(dat|dat2|tim|seq|cust|cache)$/) return "oid_isam\traw\traw"
      return "_unclassified\traw\traw"
    }
    # ---- 프로젝트별 관측 TPS ----
    /^@TPS@/ { pc=substr($1,6); if(pc ~ /^[0-9]+$/) obs_tps[pc]=$2; next }
    # ---- project.conf 라인 ----
    /^@CONF@/ {
      line = substr($0, 7)
      if (match(line, /^[0-9]+:/)) {
        pc = substr(line, 1, RLENGTH-1)
        cfg_name[pc]     = field(line, "project_name")
        cfg_ptype[pc]    = field(line, "productType")
        cfg_platform[pc] = field(line, "platform")
        cfg_keep[pc]     = field(line, "keep")
        cfg_profile[pc]  = field(line, "keep_profile")
        cfg_m5[pc]       = field(line, "keep_tag_m5")
        cfg_h1[pc]       = field(line, "keep_tag_h1")
        cfg_openmx[pc]   = field(line, "keep_openmx")
        conf_seen[pc]=1
      }
      next
    }
    # ---- find 스트림: size<TAB>relpath ----
    {
      size=$1; rel=$2
      for(i=3;i<=NF;i++) rel=rel"\t"$i        # 경로에 탭 있을 경우 방어
      if (blk) size=size*512
      n=split(rel, seg, "/")
      fn=seg[n]
      pc = seg[1]
      if (pc=="logsink1" || pc=="logsinkm") pc=seg[2]
      if (pc !~ /^[0-9]+$/) pc="_root"        # .lock 등 최상위
      # 날짜 파티션(YYYYMMDD) 추출 — 관측일수(period_days) 계산용.
      #   20000101 은 perm 루트의 고정 이름이라 '관측한 하루' 가 아니다. 세면 관측일수가 부풀고
      #   그만큼 일일 증가량이 작게 나온다.
      dt=""
      for(i=1;i<=n;i++){
        d=seg[i]
        # V4 이전 큐브는 날짜 폴더의 형제인 {yyyymmdd}cube/ 에 있다(MCubeFile:35, HCubeFile:38).
        #   그대로 두면 날짜로 안 잡혀 관측일수가 0 이 되고(=일일 증가량 0) 큐브가 산정에서 사라진다.
        #   디스크클린도 "cube" 를 떼고 파싱한다(ProjectDiskMgr2:526).
        sub(/cube$/,"",d)
        if (length(d)==8 && d ~ /^[0-9]+$/ && d!="20000101") { dt=d; break }
      }

      split(classify(rel, fn), c, "\t")
      type=c[1]; tier=c[2]; rtier=c[3]

      k = pc SUBSEP type
      bytes[k]+=size; files[k]++
      tiers[k]=tier; rtiers[k]=rtier
      pc_seen[pc]=1; type_seen[pc SUBSEP type]=1
      if (dt!="") { dk=pc SUBSEP type SUBSEP dt; if(!(dk in dseen)){dseen[dk]=1; ndays[k]++} }
      total+=size
      if (pc=="_root") { root_b+=size; root_f++ }
    }
    END {
      # 삭제(conf 미등록) 프로젝트 사전 집계 — haveconf 일 때만 제외
      excl_n=0; excl_b=0
      if (haveconf) {
        for (pc in pc_seen) {
          if (pc=="_root" || (pc in conf_seen)) continue
          excl_n++
          for (tk in type_seen){ split(tk,a,SUBSEP); if(a[1]==pc) excl_b+=bytes[pc SUBSEP a[2]] }
        }
      }
      # ── 총량/미분류를 "projects[] 에 실제로 나가는 것"만으로 재계산 ──
      #   예전엔 grand_total 은 _root 포함·삭제프로젝트 제외, projects[] 는 둘 다 제외,
      #   unclassified 는 둘 다 포함이라 세 값의 기준이 제각각이었다(합이 안 맞음).
      #   이제 셋 다 같은 집합을 센다 → grand_total_bytes == sum(projects[].total_bytes).
      #   제외된 _root 는 아래 root_files 로 따로 표기해 조용히 사라지지 않게 한다.
      inc_b=0; un_b=0; un_f=0
      for (pc in pc_seen) {
        if (pc=="_root") continue
        if (haveconf && !(pc in conf_seen)) continue
        for (tk in type_seen) {
          split(tk, a, SUBSEP); if (a[1]!=pc) continue
          k = pc SUBSEP a[2]
          inc_b += bytes[k]
          if (a[2]=="_unclassified") { un_b += bytes[k]; un_f += files[k] }
        }
      }
      printf "{\n"
      printf "  \"schema_version\": 2,\n"
      printf "  \"collected_at\": \"%s\",\n", now
      if (cust != "") printf "  \"customer\": \"%s\",\n", jesc(cust)
      printf "  \"host\": \"%s\",\n", jesc(host)
      printf "  \"root\": \"%s\",\n", jesc(root)
      if (roots != "") printf "  \"roots\": [%s],\n", roots
      printf "  \"size_mode\": \"%s\",\n", smode
      printf "  \"observed\": { \"interval_sec\": %s },\n", interval
      if (diskcap+0 > 0) printf "  \"disk_total_bytes\": %d,\n", diskcap+0
      # 로그 보관일 — 값이 있을 때만 내보낸다. 없으면 웹앱이 실측(bytes/일일증가량)으로 역산한다.
      lk=""
      if (logkeep1 ~ /^[0-9]+$/) lk = "\"logsink1\": " logkeep1+0
      if (logkeepm ~ /^[0-9]+$/) lk = lk (lk==""?"":", ") "\"logsinkm\": " logkeepm+0
      if (lk != "") printf "  \"log_keep\": { %s },\n", lk
      printf "  \"grand_total_bytes\": %d,\n", inc_b+0
      printf "  \"scanned_total_bytes\": %d,\n", total+0
      printf "  \"unclassified\": { \"bytes\": %d, \"file_count\": %d },\n", un_b+0, un_f+0
      printf "  \"excluded_deleted_projects\": { \"count\": %d, \"bytes\": %d },\n", excl_n+0, excl_b+0
      printf "  \"root_files\": { \"bytes\": %d, \"file_count\": %d },\n", root_b+0, root_f+0
      printf "  \"projects\": [\n"
      np=0
      for (pc in pc_seen) {
        if (pc=="_root") continue
        if (haveconf && !(pc in conf_seen)) continue   # 삭제(해지)된 프로젝트 제외
        np++; if(np>1) printf ",\n"
        printf "    {\n"
        printf "      \"pcode\": \"%s\",\n", jesc(pc)
        printf "      \"project_name\": \"%s\",\n", jesc(cfg_name[pc])
        printf "      \"product_type\": \"%s\",\n", jesc(cfg_ptype[pc])
        printf "      \"platform\": \"%s\",\n", jesc(cfg_platform[pc])
        printf "      \"observed_tps\": %s,\n", (pc in obs_tps ? obs_tps[pc] : "null")
        printf "      \"keep\": { \"raw\": %s, \"profile\": %s, \"m5\": %s, \"h1\": %s, \"openmx\": %s },\n",
               (cfg_keep[pc]==""?"null":cfg_keep[pc]), (cfg_profile[pc]==""?"null":cfg_profile[pc]),
               (cfg_m5[pc]==""?"null":cfg_m5[pc]), (cfg_h1[pc]==""?"null":cfg_h1[pc]),
               (cfg_openmx[pc]==""?"null":cfg_openmx[pc])
        # 프로젝트 소계
        psum=0
        for (tk in type_seen){ split(tk,a,SUBSEP); if(a[1]==pc) psum+=bytes[pc SUBSEP a[2]] }
        printf "      \"total_bytes\": %d,\n", psum+0
        printf "      \"data_types\": [\n"
        nt=0
        for (tk in type_seen){
          split(tk,a,SUBSEP); if(a[1]!=pc) continue
          type=a[2]; k=pc SUBSEP type
          # 날짜 폴더가 하나도 없는 영역(perm text2, {oid}/config …)은 스냅샷 한 장으로
          #   증가율을 낼 수 없다 → period_days 0, daily 0. 반대로 longTerm/_filter_ 처럼
          #   안에 날짜 폴더가 있으면 삭제가 안 되더라도 증가 속도는 잴 수 있다.
          nd=ndays[k]+0
          daily = (nd>0) ? bytes[k]/nd : 0
          nt++; if(nt>1) printf ",\n"
          printf "        { \"name\": \"%s\", \"tier\": \"%s\", \"retention_tier\": \"%s\", \"bytes\": %d, \"file_count\": %d, \"period_days\": %d, \"daily_bytes\": %.1f }",
                 type, tiers[k], rtiers[k], bytes[k]+0, files[k]+0, nd, daily
        }
        printf "\n      ]\n    }"
      }
      printf "\n  ]\n}\n"
    }
  '  > "$_DISK_TMP" 2>/dev/null && [ -s "$_DISK_TMP" ]; then
    mv -f "$_DISK_TMP" "$DISK_OUTPUT_JSON" 2>/dev/null || cp -f "$_DISK_TMP" "$DISK_OUTPUT_JSON" 2>/dev/null
    rm -f "$_DISK_TMP" 2>/dev/null; _DISK_TMP=""
    _DISK_TOTAL=$(grep -o '"grand_total_bytes": *[0-9]*' "$DISK_OUTPUT_JSON" 2>/dev/null | grep -o '[0-9]*' | head -1)
    ok "디스크 수집" "$DISK_OUTPUT_JSON (총 ${_DISK_TOTAL:-0} bytes)"
    # 권한 부족으로 스킵된 경로가 있으면 총량이 과소 집계된다 → 성공으로 넘기지 않고 경고
    _denied=$(grep -ci 'permission denied\|허가 거부' "$_DISK_FIND_ERR" 2>/dev/null)
    if [ "${_denied:-0}" -gt 0 ] 2>/dev/null; then
      warn "디스크 수집 신뢰도" "권한 부족으로 ${_denied}개 경로를 읽지 못해 총량이 과소 집계되었습니다 — root 또는 ${SERVER_RUN_USER:-기동계정} 으로 재실행 권장"
    fi
  else
    rm -f "$_DISK_TMP" 2>/dev/null; _DISK_TMP=""
    fail "디스크 수집" "스캔 실패 — 스켈레톤 JSON 유지: $DISK_OUTPUT_JSON"
  fi
  rm -f "$_DISK_FIND_ERR" 2>/dev/null || true
  rm -f "$_TPS_MAP" 2>/dev/null || true
  fi   # 디스크 수집 진행/취소 분기 종료
fi

echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}  수집 완료${NC}"
echo -e "${GREEN}   - 설치확인서: $OUTPUT_JSON${NC}"
[ -f "$DISK_OUTPUT_JSON" ] && echo -e "${GREEN}   - 디스크 용량: $DISK_OUTPUT_JSON${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
