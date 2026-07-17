#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# Bitbucket ↔ GitHub Migration Validation (CLI)
# - Validates branch sets, commit counts, and latest SHAs between Bitbucket S/DC and GitHub
# - Writes: validation-log-<date>.txt, validation-summary.csv, validation-summary.md
#
# CSV columns required: project-key, repo, url, github_org, github_repo (others ignored)
#
# Env:
#   BBS_BASE_URL   : e.g., http://bitbucket.example.com:7990 (or pass -b)
#   Auth: BBS_PAT OR (BBS_AUTH_TYPE=Basic with BBS_USERNAME + BBS_PASSWORD)
#   gh auth status (GH_TOKEN/GH_PAT or interactive)
#
# Usage:
#   ./2_validation.sh [-c repos.csv] [-b http://host:7990]
# ------------------------------------------------------------------------------

set -euo pipefail

CSV_PATH="./repos.csv"
BBS_BASE_URL="${BBS_BASE_URL:-}"

while getopts ":c:b:" opt; do
  case "$opt" in
    c) CSV_PATH="$OPTARG" ;;
    b) BBS_BASE_URL="$OPTARG" ;;
    *) echo "Usage: $0 [-c repos.csv] [-b BBS_BASE_URL]" >&2; exit 1 ;;
  esac
done

COMMIT_CHECK="${COMMIT_CHECK:-true}"
FAIL_ON_VALIDATION_FAILURES="${FAIL_ON_VALIDATION_FAILURES:-false}"

LOG_FILE="validation-log-$(date +'%Y%m%d').txt"

C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_BLUE='\033[0;34m'; C_RED='\033[0;31m'; C_NC='\033[0m'
log_info()    { echo -e "${C_BLUE}[INFO]${C_NC} $1"      | tee -a "$LOG_FILE"; }
log_success() { echo -e "${C_GREEN}[OK]${C_NC} $1"       | tee -a "$LOG_FILE"; }
log_warning() { echo -e "${C_YELLOW}[WARNING]${C_NC} $1" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "${C_RED}[ERROR]${C_NC} $1"      | tee -a "$LOG_FILE" >&2; }

ensure_tooling() {
  if ! command -v gh >/dev/null 2>&1; then
    log_error "GitHub CLI (gh) is not installed. See https://cli.github.com/"
    exit 1
  fi
  log_info "gh version: $(gh --version | head -n 1)"
}

ensure_auth() {
  if [[ -n "${GH_PAT:-}" && -z "${GH_TOKEN:-}" ]]; then
    export GH_TOKEN="$GH_PAT"
  fi
  if ! gh auth status >/dev/null 2>&1; then
    log_error "GitHub CLI not authenticated. Run: gh auth login (or set GH_TOKEN/GH_PAT)."
    exit 1
  fi
}

ensure_tooling
ensure_auth

if [[ -z "$BBS_BASE_URL" ]]; then
  log_error "BBS_BASE_URL is required (pass -b or export BBS_BASE_URL)."
  exit 1
fi
BASE_URL="${BBS_BASE_URL%/}"

# ---- Bitbucket auth header ----------------------------------------------------
auth_header() {
  if [[ -n "${BBS_PAT:-}" ]]; then
    printf "Authorization: Bearer %s" "$BBS_PAT"
  elif [[ "${BBS_AUTH_TYPE:-}" == "Basic" && -n "${BBS_USERNAME:-}" && -n "${BBS_PASSWORD:-}" ]]; then
    local b64; b64="$(printf '%s:%s' "$BBS_USERNAME" "$BBS_PASSWORD" | base64)"
    printf "Authorization: Basic %s" "$b64"
  else
    echo "[ERROR] Provide Bitbucket credentials via BBS_PAT (preferred) or set BBS_AUTH_TYPE=Basic with BBS_USERNAME/BBS_PASSWORD." >&2
    exit 1
  fi
}

DISABLE_SSL_VERIFY=false
case "${BBS_DISABLE_SSL_VERIFY:-}" in
  [Yy]|[Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]|1) DISABLE_SSL_VERIFY=true ;;
esac
CURL_OPTS=(-sS)
$DISABLE_SSL_VERIFY && CURL_OPTS+=(--insecure)

curl_json() { curl "${CURL_OPTS[@]}" -H "$(auth_header)" "$1"; }

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

# ---- Bitbucket helpers --------------------------------------------------------
get_bbs_branches() {
  local projectKey="$1" repoSlug="$2" start=0
  local branches=()
  while :; do
    local resp; resp="$(curl_json "${BASE_URL}/rest/api/1.0/projects/${projectKey}/repos/${repoSlug}/branches?limit=500&start=${start}")"
    mapfile -t chunk < <(echo "$resp" | jq -r '.values[]?.displayId')
    branches+=("${chunk[@]}")
    local isLast; isLast="$(echo "$resp" | jq -r '.isLastPage')"
    local nextStart; nextStart="$(echo "$resp" | jq -r '.nextPageStart // empty')"
    [[ "$isLast" == "true" ]] && break
    [[ -z "$nextStart" ]] && break
    start="$nextStart"
  done
  printf "%s\n" "${branches[@]}" | sort -u
}

urlencode_py() {
  python3 - "$1" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1]))
PY
}

get_bbs_commits_info() {
  local projectKey="$1" repoSlug="$2" branch="$3"
  local total=0 latest="" start=0 limit=1000
  local encBranch; encBranch="$(urlencode_py "$branch")"
  while :; do
    local resp; resp="$(curl_json "${BASE_URL}/rest/api/1.0/projects/${projectKey}/repos/${repoSlug}/commits?until=${encBranch}&limit=${limit}&start=${start}")"
    local cnt; cnt="$(echo "$resp" | jq '.values | length')"
    if [[ -z "$latest" && "$cnt" -gt 0 ]]; then
      latest="$(echo "$resp" | jq -r '.values[0].id')"
    fi
    total=$(( total + cnt ))
    local isLast; isLast="$(echo "$resp" | jq -r '.isLastPage')"
    local nextStart; nextStart="$(echo "$resp" | jq -r '.nextPageStart // empty')"
    [[ "$isLast" == "true" ]] && break
    [[ -z "$nextStart" ]] && break
    start="$nextStart"
  done
  echo "${total},${latest}"
}

# ---- GitHub helpers -----------------------------------------------------------
gh_repo_exists() { gh api -X GET "/repos/$1/$2" >/dev/null 2>&1; }

get_gh_branches() {
  gh api "/repos/$1/$2/branches" --paginate | jq -r '.[].name' | sort -u
}

get_gh_commits_info() {
  local org="$1" repo="$2" branch="$3"
  local total=0 latest="" page=1 per=100
  local encBranch; encBranch="$(urlencode_py "$branch")"
  while :; do
    local chunk; chunk="$(gh api "/repos/${org}/${repo}/commits?sha=${encBranch}&page=${page}&per_page=${per}" | jq -c '.')"
    local count; count="$(echo "$chunk" | jq 'length')"
    if [[ "$page" -eq 1 && "$count" -gt 0 ]]; then
      latest="$(echo "$chunk" | jq -r '.[0].sha')"
    fi
    total=$(( total + count ))
    [[ "$count" -lt "$per" ]] && break
    page=$((page+1))
  done
  echo "${total},${latest}"
}

status_marker() { # $1: ok|true|false
  [[ "$1" == "true" ]] && echo "✅ Matching" || echo "❌ Not Matching"
}

# ---- Banners ------------------------------------------------------------------
echo "=================================================="
echo " Bitbucket ↔ GitHub Migration Validation (CLI) "
echo "=================================================="
echo "Using CSV: ${CSV_PATH}"
echo "Using Bitbucket Base URL: ${BASE_URL}"

# ---- CSV checks ---------------------------------------------------------------
[[ -f "$CSV_PATH" ]] || { echo "[ERROR] CSV file not found: $CSV_PATH" | tee -a "$LOG_FILE"; exit 1; }
[[ -s "$CSV_PATH" ]] || { echo "[ERROR] CSV has no rows: $CSV_PATH" | tee -a "$LOG_FILE"; exit 1; }

# Validate header
header="$(head -n1 "$CSV_PATH")"
for col in project-key repo github_org github_repo; do
  echo "$header" | grep -q "$col" || { echo "Missing required column: ${col}" >&2; exit 1; }
done

summary_csv="validation-summary.csv"
echo "github_org,github_repo,bbs_project_key,bbs_repo,branch_count_bbs,branch_count_gh,branch_count_match,commits_match_all,shas_match_all,gh_notes" > "$summary_csv"

echo "==> Starting validation..."

# Process rows
tail -n +2 "$CSV_PATH" | while IFS=',' read -r bbsProjectKey bbsProjectName bbsRepoSlug bbsUrl _lc _rb _ab isArchived prCount ghOrg ghRepo _vis; do
  echo "============================================================" | tee -a "$LOG_FILE"
  header_line="ℹ️  [$(date -u +%Y-%m-%dT%H:%M:%SZ)] Validating: ${bbsProjectKey}/${bbsRepoSlug} -> ${ghOrg}/${ghRepo}"
  echo "$header_line" | tee -a "$LOG_FILE"
  echo "============================================================" | tee -a "$LOG_FILE"

  # Optional snapshot (ignore failures)
  gh repo view "${ghOrg}/${ghRepo}" --json createdAt,diskUsage,defaultBranchRef,isPrivate >/dev/null 2>&1 || true

  ghExists="yes"
  if ! gh_repo_exists "$ghOrg" "$ghRepo"; then
    msg="[$(date)] GitHub repo not found or inaccessible: ${ghOrg}/${ghRepo}. Treating GH side as empty."
    echo "$msg" | tee -a "$LOG_FILE"
    ghExists="no"
  fi

  mapfile -t bbsBranches < <(get_bbs_branches "$bbsProjectKey" "$bbsRepoSlug")
  mapfile -t ghBranches < <( [[ "$ghExists" == "yes" ]] && get_gh_branches "$ghOrg" "$ghRepo" || true )

  bbsBranchCount="${#bbsBranches[@]}"
  ghBranchCount="${#ghBranches[@]}"
  branchCountOk="false"; [[ "$bbsBranchCount" -eq "$ghBranchCount" ]] && branchCountOk="true"
  if [[ "$branchCountOk" == "true" ]]; then
    echo "✅ Branch Count MATCHED | BBS=${bbsBranchCount} GitHub=${ghBranchCount}" | tee -a "$LOG_FILE"
  else
    echo "❌ Branch Count MISMATCH | BBS=${bbsBranchCount} GitHub=${ghBranchCount}" | tee -a "$LOG_FILE"
  fi

  missingInGH=$(comm -23 <(printf "%s\n" "${bbsBranches[@]}" | sort) <(printf "%s\n" "${ghBranches[@]}" | sort || true) || true)
  missingInBBS=$(comm -13 <(printf "%s\n" "${bbsBranches[@]}" | sort) <(printf "%s\n" "${ghBranches[@]}" | sort || true) || true)
  if [[ -n "$missingInGH" ]]; then
    echo "❌ Branches missing in GitHub: $(echo "$missingInGH" | tr '\n' ' ' | sed 's/ *$//')" | tee -a "$LOG_FILE"
  else
    echo "✅ No branches missing in GitHub" | tee -a "$LOG_FILE"
  fi
  if [[ -n "$missingInBBS" ]]; then
    echo "❌ Extra branches in GitHub (not in Bitbucket): $(echo "$missingInBBS" | tr '\n' ' ' | sed 's/ *$//')" | tee -a "$LOG_FILE"
  else
    echo "✅ No extra branches found" | tee -a "$LOG_FILE"
  fi

  commitsMatchAll="false"
  shasMatchAll="false"
  if [[ "${COMMIT_CHECK}" != "true" ]]; then
    commitsMatchAll="true"
    shasMatchAll="true"
    echo "ℹ️ COMMIT_CHECK=false - skipping per-branch commit/SHA comparison" | tee -a "$LOG_FILE"
  elif [[ "$ghExists" == "yes" ]]; then
    ghDefault="$(gh api "/repos/${ghOrg}/${ghRepo}" --jq '.default_branch' 2>/dev/null || true)"
    bbsDefault="$(curl_json "${BASE_URL}/rest/api/1.0/projects/${bbsProjectKey}/repos/${bbsRepoSlug}/branches/default" 2>/dev/null | jq -r '.displayId // empty' 2>/dev/null || true)"

    declare -A ghSet=() bbsSet=()
    for b in "${ghBranches[@]}"; do ghSet["$b"]=1; done
    for b in "${bbsBranches[@]}"; do bbsSet["$b"]=1; done

    validation_branch=""
    if [[ -n "$ghDefault" && ( -n "${ghSet[$ghDefault]:-}" || -n "${bbsSet[$ghDefault]:-}" ) ]]; then
      validation_branch="$ghDefault"
    elif [[ -n "$bbsDefault" && ( -n "${ghSet[$bbsDefault]:-}" || -n "${bbsSet[$bbsDefault]:-}" ) ]]; then
      validation_branch="$bbsDefault"
    fi

    branches_to_check=()
    [[ -n "$validation_branch" ]] && branches_to_check+=("$validation_branch")
    for b in "${ghBranches[@]}"; do
      (( ${#branches_to_check[@]} >= 10 )) && break
      [[ "$b" == "$validation_branch" ]] && continue
      branches_to_check+=("$b")
    done
    if (( bbsBranchCount > 10 || ghBranchCount > 10 )); then
      echo "ℹ️ Commit validation running only for first ${#branches_to_check[@]} branches (default branch first, max 10)" | tee -a "$LOG_FILE"
    elif (( ${#branches_to_check[@]} > 0 )); then
      echo "ℹ️ Commit validation covering ${#branches_to_check[@]} branch(es) (default branch first, max 10)" | tee -a "$LOG_FILE"
    else
      echo "ℹ️ Could not determine any branch for commit/SHA check" | tee -a "$LOG_FILE"
    fi

    if (( ${#branches_to_check[@]} > 0 )); then
      commitsMatchAll="true"
      shasMatchAll="true"
      for br in "${branches_to_check[@]}"; do
        [[ -z "$br" ]] && continue
        if [[ -z "${ghSet[$br]:-}" ]]; then
          echo "Branch '$br': missing in GitHub branches list ❌ Not Matching" | tee -a "$LOG_FILE"
          commitsMatchAll="false"; shasMatchAll="false"; continue
        fi
        if [[ -z "${bbsSet[$br]:-}" ]]; then
          echo "Branch '$br': missing in Bitbucket branches list ❌ Not Matching" | tee -a "$LOG_FILE"
          commitsMatchAll="false"; shasMatchAll="false"; continue
        fi
        ghInfo="$(get_gh_commits_info "$ghOrg" "$ghRepo" "$br")"
        bbsInfo="$(get_bbs_commits_info "$bbsProjectKey" "$bbsRepoSlug" "$br")"
        ghCount="${ghInfo%%,*}"; ghSha="${ghInfo#*,}"
        bbsCount="${bbsInfo%%,*}"; bbsSha="${bbsInfo#*,}"

        countOk="false"; [[ "$ghCount" == "$bbsCount" ]] && countOk="true"
        shaOk="false"; [[ "$ghSha" == "$bbsSha" ]] && shaOk="true"
        [[ "$countOk" == "false" ]] && commitsMatchAll="false"
        [[ "$shaOk" == "false" ]] && shasMatchAll="false"

        echo "Branch '$br': BBS Commits=${bbsCount} | GitHub Commits=${ghCount} | $(status_marker "$countOk")" | tee -a "$LOG_FILE"
        echo "Branch '$br': BBS SHA=${bbsSha} | GitHub SHA=${ghSha} | $(status_marker "$shaOk")" | tee -a "$LOG_FILE"
      done
    fi
  fi

  gh_notes=""
  if [[ "$ghExists" == "no" ]]; then
    gh_notes="repo not found or no access"
  elif [[ "$ghBranchCount" -eq 0 && "$bbsBranchCount" -gt 0 ]]; then
    gh_notes="no branches on GH"
  fi

  echo "✅ Validation completed for: ${ghOrg}/${ghRepo}" | tee -a "$LOG_FILE"

  echo "${ghOrg},${ghRepo},${bbsProjectKey},${bbsRepoSlug},${bbsBranchCount},${ghBranchCount},${branchCountOk},${commitsMatchAll},${shasMatchAll},${gh_notes}" >> "$summary_csv"
done

echo "[$(date)] All validations from CSV completed" | tee -a "$LOG_FILE"

# Markdown table
md="validation_summary_$(date +%Y%m%d).md"
{
  echo "| GitHub Repo | BBS Repo | Branch Count (BBS/GH) | Branch Count Match | All Commit Counts Match | All Latest SHAs Match | Notes |"
  echo "|---|---|---:|---|---|---|---|"
  # Read rows directly from the CSV file (no pipe → no subshell surprises)
  while IFS=',' read -r ghOrg ghRepo bbsKey bbsRepo bcB ghC bcOk ccOk shaOk notes; do
    # Skip empty lines
    [[ -z "$ghOrg" && -z "$ghRepo" ]] && continue
    printf "| %s/%s | %s/%s | %s/%s | %s | %s | %s | %s |\n" \
      "$ghOrg" "$ghRepo" \
      "$bbsKey" "$bbsRepo" \
      "$bcB" "$ghC" \
      "$( [[ "$bcOk" == "true" ]] && echo "✅" || echo "❌" )" \
      "$( [[ "$ccOk" == "true" ]] && echo "✅" || echo "❌" )" \
      "$( [[ "$shaOk" == "true" ]] && echo "✅" || echo "❌" )" \
      "${notes}"
  done < <(tail -n +2 "$summary_csv")
} > "$md"
echo "=======================Summary==========================="
cat ${md}
echo "======================Completed==========================="

total_validated=$(awk -F',' 'NR>1{c++} END{print c+0}' "$summary_csv")
passed=$(awk -F',' 'NR>1 && $7=="true" && $8=="true" && $9=="true"{c++} END{print c+0}' "$summary_csv")
failed=$(( total_validated - passed ))

if (( total_validated == 0 )); then
  echo "::notice::No repositories were validated."
elif (( failed == 0 )); then
  echo "::notice::All ${total_validated} repositories validated successfully (branches, commits and SHAs match)"
elif (( passed == 0 )); then
  echo "::error::All ${total_validated} repositories have validation discrepancies"
  awk -F',' 'NR>1 && !($7=="true" && $8=="true" && $9=="true"){printf "::error::Validation discrepancy: %s/%s (%s)\n",$1,$2,$10}' "$summary_csv"
else
  echo "::warning::Validation completed with discrepancies: ${passed} matched, ${failed} with issues (of ${total_validated})"
  awk -F',' 'NR>1 && !($7=="true" && $8=="true" && $9=="true"){printf "::warning::Validation discrepancy: %s/%s (%s)\n",$1,$2,$10}' "$summary_csv"
fi

if [[ "$FAIL_ON_VALIDATION_FAILURES" == "true" && "$failed" -gt 0 ]]; then
  echo "::error::FAIL_ON_VALIDATION_FAILURES=true and ${failed} repository(ies) failed validation."
  exit 1
fi
exit 0
