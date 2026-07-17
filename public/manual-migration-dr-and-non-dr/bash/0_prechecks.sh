#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./0_pr_pipeline_check.sh [-c repos.csv] [-o output.csv] [-p "KEY1,KEY2"]
#
# CSV minimum columns if provided: project-key,repo
# Env: BBS_BASE_URL + (BBS_PAT or BBS_USERNAME+BBS_PASSWORD with BBS_AUTH_TYPE=Basic)

CSV_PATH="repos.csv"
OUTPUT_PATH=""
PROJECT_KEYS_CSV=""

sed -i 's/"//g' $CSV_PATH

while getopts ":c:o:p:" opt; do
  case "$opt" in
    c) CSV_PATH="$OPTARG" ;;
    o) OUTPUT_PATH="$OPTARG" ;;
    p) PROJECT_KEYS_CSV="$OPTARG" ;;
    *) echo "Usage: $0 [-c repos.csv] [-o output.csv] [-p KEY1,KEY2]" >&2; exit 1 ;;
  esac
done

if [[ -z "${BBS_BASE_URL:-}" ]]; then
  echo "[ERROR] BBS_BASE_URL env var is required." >&2
  exit 1
fi
BASE_URL="${BBS_BASE_URL%/}"

LOG_FILE="bbs-prechecks-$(date +'%Y%m%d-%H%M%S').log"

C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_BLUE='\033[0;34m'; C_RED='\033[0;31m'; C_NC='\033[0m'
log_info()    { echo -e "${C_BLUE}[INFO]${C_NC} $1"      | tee -a "$LOG_FILE"; }
log_success() { echo -e "${C_GREEN}[OK]${C_NC} $1"       | tee -a "$LOG_FILE"; }
log_warning() { echo -e "${C_YELLOW}[WARNING]${C_NC} $1" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "${C_RED}[ERROR]${C_NC} $1"      | tee -a "$LOG_FILE" >&2; }

detect_bbs_install() {
  local p launcher bbsHome line detected
  if [[ -n "${BITBUCKET_HOME:-}" && -d "${BITBUCKET_HOME}" ]]; then
    export BITBUCKET_HOME
    log_success "Bitbucket Server home found via BITBUCKET_HOME: ${BITBUCKET_HOME}"
    return 0
  fi
  line="$(ps -ef 2>/dev/null | grep -i '[b]itbucket' | grep -i 'home' | head -n1 || true)"
  if [[ -n "$line" ]]; then
    detected="$(printf '%s\n' "$line" | grep -oE 'bitbucket[._]home=[^[:space:]]+' | head -n1 | sed -E 's/^.*home=//' || true)"
    [[ -z "$detected" ]] && detected="$(printf '%s\n' "$line" | grep -oE '/[^[:space:]]+/bitbucket[^[:space:]]*' | head -n1 || true)"
    if [[ -n "$detected" ]]; then
      export BITBUCKET_HOME="$detected"
      log_success "Bitbucket Server home auto-detected from running process: ${detected}"
      return 0
    fi
  fi
  for p in /var/atlassian/application-data/bitbucket /opt/atlassian/bitbucket; do
    if [[ -d "$p" ]]; then
      export BITBUCKET_HOME="$p"
      log_success "Bitbucket Server found at default location: ${p}"
      return 0
    fi
  done
  launcher="$(command -v start-bitbucket.sh 2>/dev/null || command -v bitbucket 2>/dev/null || true)"
  if [[ -n "$launcher" ]]; then
    bbsHome="$(cd "$(dirname "$launcher")/.." 2>/dev/null && pwd || dirname "$launcher")"
    export BITBUCKET_HOME="$bbsHome"
    log_success "Bitbucket Server launcher found on PATH: ${launcher} (home: ${bbsHome})"
    return 0
  fi
  log_warning "Bitbucket Server install not found locally (checked BITBUCKET_HOME, running process, default dirs, PATH). Continuing — remote/SSH migration does not require a local install."
  return 0
}
detect_bbs_install || true

auth_header() {
  if [[ -n "${BBS_PAT:-}" ]]; then
    echo "Authorization: Bearer ${BBS_PAT}"
  elif [[ "${BBS_AUTH_TYPE:-}" == "Basic" && -n "${BBS_USERNAME:-}" && -n "${BBS_PASSWORD:-}" ]]; then
    b64="$(printf '%s:%s' "$BBS_USERNAME" "$BBS_PASSWORD" | base64)"
    echo "Authorization: Basic ${b64}"
  else
    echo "[ERROR] Provide BBS_PAT or BBS_AUTH_TYPE=Basic with BBS_USERNAME/BBS_PASSWORD." >&2
    exit 1
  fi
}

DISABLE_SSL_VERIFY=false
case "${BBS_DISABLE_SSL_VERIFY:-}" in
  [Yy]|[Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]|1) DISABLE_SSL_VERIFY=true ;;
esac
CURL_OPTS=(-sS)
$DISABLE_SSL_VERIFY && CURL_OPTS+=(--insecure)

curl_json() {
  curl "${CURL_OPTS[@]}" -H "$(auth_header)" "$1"
}

check_tls() {
  if $DISABLE_SSL_VERIFY; then
    log_warning "TLS certificate verification is DISABLED (BBS_DISABLE_SSL_VERIFY set). Proceeding without cert validation."
    return 0
  fi
  local probe rc
  probe="$(curl -sS -o /dev/null "${BASE_URL}/rest/api/1.0/projects?limit=1" 2>&1)"; rc=$?
  case "$rc" in
    35|51|58|59|60|66|77|83|91)
      log_error "TLS/SSL certificate validation failed for ${BASE_URL} (curl exit ${rc}): ${probe}"
      log_error "If this host uses a self-signed or internal CA certificate intentionally, re-run with BBS_DISABLE_SSL_VERIFY=Y."
      exit 1
      ;;
  esac
  return 0
}
check_tls

# Preflight auth test
preflight_status="$(curl "${CURL_OPTS[@]}" -o /dev/null -w '%{http_code}' -H "$(auth_header)" "${BASE_URL}/rest/api/1.0/projects?limit=1")"
if [[ "$preflight_status" -lt 200 || "$preflight_status" -ge 300 ]]; then
  case "$preflight_status" in
    401|403) log_error "Bitbucket auth failed (HTTP $preflight_status). Verify BBS_PAT / credentials and permissions." ;;
    404)     log_error "Bitbucket endpoint not found (HTTP 404). Verify BBS_BASE_URL: ${BASE_URL}" ;;
    000)     log_error "Network/DNS/TLS issue reaching Bitbucket (HTTP 000). Verify connectivity to ${BASE_URL}." ;;
    *)       log_error "Bitbucket preflight failed (HTTP $preflight_status) for ${BASE_URL}." ;;
  esac
  exit 1
fi

timestamp="$(date +'%Y%m%d-%H%M%S')"
OUTPUT_CSV="${OUTPUT_PATH:-bbs_pr_validation_output-${timestamp}.csv}"

IFS=',' read -r -a PROJECT_KEYS <<< "${PROJECT_KEYS_CSV:-}"

discover_projects() {
  local start=0 vals isLast nextStart
  local results=()
  while :; do
    resp="$(curl_json "${BASE_URL}/rest/api/1.0/projects?limit=100&start=${start}")"
    vals="$(echo "$resp" | jq -r '.values[]?.key')"
    [[ -n "$vals" ]] && results+=($(echo "$vals"))
    isLast="$(echo "$resp" | jq -r '.isLastPage')"
    nextStart="$(echo "$resp" | jq -r '.nextPageStart // empty')"
    [[ "$isLast" == "true" ]] && break
    [[ -z "$nextStart" ]] && break
    start="$nextStart"
  done
  printf "%s\n" "${results[@]}"
}

discover_repos_for_project() {
  local projectKey="$1"
  local start=0
  while :; do
    resp="$(curl_json "${BASE_URL}/rest/api/1.0/projects/${projectKey}/repos?limit=100&start=${start}")"
    echo "$resp" | jq -r '.values[]? | @base64' | while read -r row; do
      _jq() { echo "$row" | base64 --decode | jq -r "$1"; }
      printf "%s,%s,%s\n" "$(_jq '.project.name')" "$(_jq '.slug')" "$(_jq '.archived')"
    done
    isLast="$(echo "$resp" | jq -r '.isLastPage')"
    nextStart="$(echo "$resp" | jq -r '.nextPageStart // empty')"
    [[ "$isLast" == "true" ]] && break
    [[ -z "$nextStart" ]] && break
    start="$nextStart"
  done
}

get_open_pr_count() {
  local projectKey="$1" repoSlug="$2"
  local start=0 total=0
  while :; do
    resp="$(curl_json "${BASE_URL}/rest/api/1.0/projects/${projectKey}/repos/${repoSlug}/pull-requests?state=OPEN&limit=100&start=${start}")" || { echo "ERROR"; return; }
    cnt="$(echo "$resp" | jq '.values | length' 2>/dev/null || true)"
    [[ "$cnt" =~ ^[0-9]+$ ]] || { echo "ERROR"; return; }
    total=$(( total + cnt ))
    isLast="$(echo "$resp" | jq -r '.isLastPage')"
    nextStart="$(echo "$resp" | jq -r '.nextPageStart // empty')"
    [[ "$isLast" == "true" ]] && break
    [[ -z "$nextStart" ]] && break
    start="$nextStart"
  done
  echo "$total"
}

LARGE_FILE_REPORT="large_files_report-${timestamp}.csv"
scan_large_files() {
  case "${RUN_LARGE_FILE_SCAN:-Y}" in
    [Nn]|[Nn][Oo]|0|[Ff][Aa][Ll][Ss][Ee]) log_info "Large-file scan disabled (RUN_LARGE_FILE_SCAN)."; return 0 ;;
  esac
  local threshold_mb="${LARGE_FILE_THRESHOLD_MB:-400}"
  local threshold_bytes=$(( threshold_mb * 1024 * 1024 ))
  if ! command -v git >/dev/null 2>&1; then
    log_warning "git not found - skipping large-file (>=${threshold_mb}MB) scan."
    return 0
  fi
  echo "project_key,repo_slug,file_path,size_bytes,size_mb" > "$LARGE_FILE_REPORT"
  local git_ssl=(); $DISABLE_SSL_VERIFY && git_ssl=(-c http.sslVerify=false)
  local hdr; hdr="$(auth_header)"
  local tmpdir; tmpdir="$(mktemp -d)"
  local flagged=0 scanned=0
  local projKey projName repoSlug _rest
  while IFS=',' read -r projKey projName repoSlug _rest; do
    [[ -z "${projKey:-}" || -z "${repoSlug:-}" ]] && continue
    scanned=$(( scanned + 1 ))
    local mir="${tmpdir}/${projKey}_${repoSlug}.git"
    if ! git "${git_ssl[@]}" -c http.extraHeader="$hdr" clone --mirror --quiet \
         "${BASE_URL}/scm/${projKey}/${repoSlug}.git" "$mir" 2>/dev/null; then
      log_warning "Could not clone ${projKey}/${repoSlug} for large-file scan (skipping)."
      continue
    fi
    local bsize bpath mb
    while IFS=$'\t' read -r bsize bpath; do
      [[ -z "${bsize:-}" ]] && continue
      mb=$(( bsize / 1024 / 1024 ))
      printf '%s,%s,"%s",%s,%s\n' "$projKey" "$repoSlug" "$bpath" "$bsize" "$mb" >> "$LARGE_FILE_REPORT"
      log_warning "Large file in ${projKey}/${repoSlug}: ${bpath} (${mb} MB)"
      flagged=$(( flagged + 1 ))
    done < <(
      git -C "$mir" rev-list --objects --all 2>/dev/null \
        | git -C "$mir" cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' 2>/dev/null \
        | awk -v t="$threshold_bytes" '$1=="blob" && ($3+0)>=t { size=$3; $1="";$2="";$3=""; sub(/^ +/,""); print size"\t"$0 }'
    )
    rm -rf "$mir"
  done < "$rows_tmp"
  rm -rf "$tmpdir"
  if (( flagged > 0 )); then
    log_warning "Large-file scan: ${flagged} file(s) >= ${threshold_mb}MB across ${scanned} repo(s). Use Git LFS for these before migrating. Report: ${LARGE_FILE_REPORT}"
  else
    log_success "Large-file scan: no files >= ${threshold_mb}MB found across ${scanned} repo(s)."
  fi
  return 0
}

echo ""
echo " Bitbucket Pipeline Readiness Check (Open PRs only) "
echo "===================================================="

# Load or discover input rows
rows_tmp="$(mktemp)"
if [[ -f "$CSV_PATH" ]] && [[ -s "$CSV_PATH" ]]; then
  header="$(head -n1 "$CSV_PATH")"
  if echo "$header" | grep -q "project-key" && echo "$header" | grep -q ",repo"; then
    tail -n +2 "$CSV_PATH" > "$rows_tmp"
  else
    echo "[ERROR] CSV missing minimum columns: project-key,repo"
    echo "[INFO] Falling back to auto-discovery."
  fi
fi

if [[ ! -s "$rows_tmp" ]]; then
  echo "[INFO] Auto-discovering projects & repos..."
  projects=($(discover_projects))
  for pk in "${projects[@]}"; do
    if [[ "${#PROJECT_KEYS[@]}" -gt 0 ]]; then
      match=false
      for filter in "${PROJECT_KEYS[@]}"; do [[ "$pk" == "$filter" ]] && match=true; done
      [[ "$match" == "false" ]] && continue
    fi
    discover_repos_for_project "$pk" | while IFS=',' read -r pname rslug archived; do
      printf "%s,%s,%s,%s\n" "$pk" "$pname" "$rslug" "$archived" >> "$rows_tmp"
    done
  done
fi

# Process
ready_tmp="$(mktemp)"
results_tmp="$(mktemp)"
echo "project_key,project_name,repo_slug,is_archived,open_pr_count,warnings,ready_to_migrate" > "$results_tmp"

total_open_prs=0
pr_check_failed=false
while IFS=',' read -r projKey projName repoSlug isArchived; do
  openPrs="$(get_open_pr_count "$projKey" "$repoSlug")"
  if [[ "$openPrs" == "ERROR" || ! "$openPrs" =~ ^[0-9]+$ ]]; then
    pr_check_failed=true
    echo "[ERROR] ${projKey}/${repoSlug}: failed to query open PRs (API error)"
    printf "%s,%s,%s,%s,%s,%s,%s\n" \
      "$projKey" "$projName" "$repoSlug" "${isArchived:-false}" "ERROR" "API_FAILURE" "false" >> "$results_tmp"
    continue
  fi
  total_open_prs=$(( total_open_prs + openPrs ))
  warns=""
  if (( openPrs > 0 )); then
    warns="OPEN_PRS"
    echo "[WARNING] ${projKey}/${repoSlug} PRs(Open): ${openPrs}"
  else
    echo "[OK] ${projKey}/${repoSlug} PRs(Open): ${openPrs}"
    echo "${projKey}/${repoSlug}" >> "$ready_tmp"
  fi
  ready=false; [[ -z "$warns" ]] && ready=true
  printf "%s,%s,%s,%s,%s,%s,%s\n" \
    "$projKey" "$projName" "$repoSlug" "${isArchived:-false}" "$openPrs" "$warns" "$ready" >> "$results_tmp"
done < "$rows_tmp"

mv "$results_tmp" "$OUTPUT_CSV"
echo "[INFO] Wrote precheck CSV: $OUTPUT_CSV"

if [[ -s "$ready_tmp" ]]; then
  echo ""
  echo "[READY] Repos ready to migrate (no open PRs)✅:"
  sed 's/^/ - /' "$ready_tmp"
else
  echo ""
  echo "[READY] No repos are currently without open PRs."
fi

total_repos="$(($(wc -l < "$rows_tmp")))"

echo ""
echo "[SUMMARY] Total repos: $total_repos"
echo "Open PRs total: $total_open_prs"
echo "======================Completed============================="

scan_large_files

hasActiveItems=false
(( total_open_prs > 0 )) && hasActiveItems=true

if [[ "$pr_check_failed" == true && "$hasActiveItems" == false ]]; then
  echo -e "\n\033[31mValidation checks could not be completed due to API failures. Please review errors before proceeding.\033[0m\n"
  exit 1
elif [[ "$pr_check_failed" == true && "$hasActiveItems" == true ]]; then
  echo -e "\n\033[33mOpen pull requests detected, but some validation checks failed. Review warnings and errors before proceeding.\033[0m\n"
elif [[ "$pr_check_failed" == false && "$hasActiveItems" == true ]]; then
  echo -e "\n\033[33mOpen pull requests found. Continue with migration if you have reviewed and are comfortable proceeding.\033[0m\n"
else
  echo -e "\n\033[32mNo open pull requests detected. You can proceed with migration.\033[0m\n"
fi