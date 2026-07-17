<#
.SYNOPSIS
    Post-migration validation script for Bitbucket Server to GitHub migrations.

.DESCRIPTION
    Reads the same repos.csv used for pre-checks and migration, then validates
    each repository by comparing:
      - Branch count between Bitbucket Server and GitHub
      - Latest commit SHA on the default branch


    Required CSV columns : project-key, repo, github_org, github_repo

    Required environment variables:
        $env:BBS_BASE_URL   = "https://bitbucket.example.com"

    Authentication (one of the following):
        $env:BBS_PAT        = "your-token"
        $env:BBS_AUTH_TYPE  = "Basic"
        $env:BBS_USERNAME   = "your-username"
        $env:BBS_PASSWORD   = "your-password"

.PARAMETER CsvPath
    Path to the input CSV file. Defaults to repos.csv in the current directory.

.PARAMETER OutputPath
    Path for the output validation CSV report.
    Defaults to validation-summary-<timestamp>.csv

.EXAMPLE
    $env:BBS_BASE_URL = "https://bitbucket.example.com"
    $env:BBS_PAT      = "your-token"
    .\2_validation.ps1

.EXAMPLE
    .\2_validation.ps1 -CsvPath "C:\migrations\repos.csv"
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$CsvPath = "repos.csv",

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"
$SCRIPT_DIR = (Get-Location).Path
$COMMIT_CHECK = if ($env:COMMIT_CHECK) { $env:COMMIT_CHECK } else { 'true' }
$FAIL_ON_VALIDATION_FAILURES = if ($env:FAIL_ON_VALIDATION_FAILURES) { $env:FAIL_ON_VALIDATION_FAILURES } else { 'false' }

#region ── CSV validation ─────────────────────────────────────────────────────

if (-not (Test-Path -LiteralPath $CsvPath)) {
    Write-Host "[ERROR] CSV file not found: $CsvPath" -ForegroundColor Red
    Write-Host "        Usage: .\2_validation.ps1 -CsvPath 'path\to\repos.csv'" -ForegroundColor Yellow
    exit 1
}

if ((Get-Item -LiteralPath $CsvPath).Length -eq 0) {
    Write-Host "[ERROR] CSV file is empty: $CsvPath" -ForegroundColor Red
    exit 1
}

$rawCsv        = (Get-Content -LiteralPath $CsvPath -Raw) -replace '"', ''
$csvLines      = $rawCsv -split "`r?`n" | Where-Object { $_ -ne '' }
$headerColumns = $csvLines[0] -split ','

$requiredColumns = @('project-key', 'repo', 'github_org', 'github_repo')
$missingColumns  = $requiredColumns | Where-Object { $headerColumns -notcontains $_ }

if ($missingColumns.Count -gt 0) {
    Write-Host "[ERROR] CSV is missing required columns: $($missingColumns -join ', ')" -ForegroundColor Red
    Write-Host "        Found header: $($csvLines[0])" -ForegroundColor Yellow
    exit 1
}

$repoList = @(Import-Csv -LiteralPath $CsvPath)

if ($repoList.Count -eq 0) {
    Write-Host "[ERROR] CSV contains no data rows." -ForegroundColor Red
    exit 1
}

#endregion

#region ── Environment validation ────────────────────────────────────────────

if (-not $env:BBS_BASE_URL) {
    Write-Host "[ERROR] BBS_BASE_URL environment variable is not set." -ForegroundColor Red
    Write-Host "        Set it by running: `$env:BBS_BASE_URL = 'https://bitbucket.example.com'" -ForegroundColor Yellow
    exit 1
}
$BASE_URL = $env:BBS_BASE_URL.TrimEnd('/')

#endregion

#region ── GitHub CLI validation ─────────────────────────────────────────────

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] GitHub CLI (gh) is not installed. See https://cli.github.com/" -ForegroundColor Red
    exit 1
}
if ($env:GH_PAT -and -not $env:GH_TOKEN) { $env:GH_TOKEN = $env:GH_PAT }

& gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] GitHub CLI not authenticated." -ForegroundColor Red
    Write-Host "        Run: gh auth login  or set the GH_TOKEN environment variable." -ForegroundColor Yellow
    exit 1
}

#endregion

#region ── Auth ───────────────────────────────────────────────────────────────

function Get-AuthHeader {
    if ($env:BBS_PAT) {
        return @{ Authorization = "Bearer $($env:BBS_PAT)" }
    }
    elseif (($env:BBS_AUTH_TYPE -eq 'Basic') -and $env:BBS_USERNAME -and $env:BBS_PASSWORD) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes("$($env:BBS_USERNAME):$($env:BBS_PASSWORD)")
        $b64   = [Convert]::ToBase64String($bytes)
        return @{ Authorization = "Basic $b64" }
    }
    else {
        Write-Host "[ERROR] No valid credentials found." -ForegroundColor Red
        Write-Host "        Provide BBS_PAT, or set BBS_AUTH_TYPE=Basic with BBS_USERNAME and BBS_PASSWORD." -ForegroundColor Yellow
        exit 1
    }
}

$script:DisableSslVerify = ($env:BBS_DISABLE_SSL_VERIFY -match '^(?i:y|yes|true|1)$')
$script:RestArgs = @{}
if ($script:DisableSslVerify) { $script:RestArgs['SkipCertificateCheck'] = $true }

function Invoke-BbsApi {
    param([string]$Url)
    try {
        return Invoke-RestMethod -Uri $Url -Headers (Get-AuthHeader) -Method Get -ErrorAction Stop @script:RestArgs
    }
    catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        $msg = if ($status) { "HTTP $status" } else { $_.Exception.Message }
        throw "BBS API call failed ($msg): $Url"
    }
}

if ($script:DisableSslVerify) {
    Write-Host "[WARNING] TLS certificate verification is DISABLED (BBS_DISABLE_SSL_VERIFY set). Proceeding without cert validation." -ForegroundColor Yellow
} else {
    try {
        $null = Invoke-RestMethod -Uri "$BASE_URL/rest/api/1.0/projects?limit=1" -Headers (Get-AuthHeader) -Method Get -ErrorAction Stop
    } catch {
        if ("$_" -match 'SSL|certificate|trust|SEC_ERROR|self-signed|CERT_') {
            Write-Host "[ERROR] TLS/SSL certificate validation failed for $BASE_URL." -ForegroundColor Red
            Write-Host "        Detail: $_" -ForegroundColor Red
            Write-Host "        If this host uses a self-signed or internal CA certificate intentionally, re-run with BBS_DISABLE_SSL_VERIFY=Y." -ForegroundColor Yellow
            exit 1
        }
    }
}

#endregion

#region ── Functions ──────────────────────────────────────────────────────────

function Get-BbsBranchCount {
    param([string]$ProjectKey, [string]$RepoSlug)
    $start = 0
    $total = 0
    do {
        $resp   = Invoke-BbsApi "$BASE_URL/rest/api/1.0/projects/$ProjectKey/repos/$RepoSlug/branches?limit=500&start=$start"
        $total += $resp.values.Count
        $isLast = $resp.isLastPage
        if (-not $isLast) {
            if ($null -ne $resp.nextPageStart) { $start = [int]$resp.nextPageStart }
            else { break }
        }
    } while (-not $isLast)
    return $total
}

function Get-BbsDefaultBranch {
    param([string]$ProjectKey, [string]$RepoSlug)
    try {
        $resp = Invoke-BbsApi "$BASE_URL/rest/api/1.0/projects/$ProjectKey/repos/$RepoSlug/branches/default"
        return $resp.displayId
    }
    catch {
        return $null
    }
}

function Get-BbsLatestSha {
    param([string]$ProjectKey, [string]$RepoSlug, [string]$Branch)
    try {
        $encoded = [System.Uri]::EscapeDataString($Branch)
        $resp    = Invoke-BbsApi "$BASE_URL/rest/api/1.0/projects/$ProjectKey/repos/$RepoSlug/commits?until=$encoded&limit=1"
        if ($resp.values -and $resp.values.Count -gt 0) {
            return [string]$resp.values[0].id
        }
        return $null
    }
    catch {
        return $null
    }
}

function Get-GhBranchCount {
    param([string]$Org, [string]$Repo)
    try {
        $total = 0
        $page  = 1
        do {
            $batch = & gh api "/repos/$Org/$Repo/branches?per_page=100&page=$page" | Out-String | ConvertFrom-Json
            $count  = @($batch).Count
            $total += $count
            $page++
        } while ($count -eq 100)
        return $total
    }
    catch {
        return -1
    }
}

function Get-GhBranches {
    param([string]$Org, [string]$Repo)
    try {
        $names = New-Object System.Collections.Generic.List[string]
        $page  = 1
        do {
            $batch = & gh api "/repos/$Org/$Repo/branches?per_page=100&page=$page" | Out-String | ConvertFrom-Json
            $count = @($batch).Count
            foreach ($b in @($batch)) { if ($b.name) { $names.Add([string]$b.name) } }
            $page++
        } while ($count -eq 100)
        return $names
    }
    catch {
        return @()
    }
}

function Get-GhDefaultBranch {
    param([string]$Org, [string]$Repo)
    try {
        # Use gh repo view with specific field to avoid parsing large repo JSON
        $result = & gh repo view "$Org/$Repo" --json defaultBranchRef --template '{{.defaultBranchRef.name}}'
        return ([string]$result).Trim()
    }
    catch {
        return $null
    }
}

function Get-GhLatestSha {
    param([string]$Org, [string]$Repo, [string]$Branch)
    try {
        $encoded = [System.Uri]::EscapeDataString($Branch)
        # Use --template to extract just the SHA string, avoiding JSON parsing entirely
        $result  = & gh api "/repos/$Org/$Repo/commits?sha=$encoded&per_page=1" --template '{{range .}}{{.sha}}{{end}}'
        return ([string]$result).Trim()
    }
    catch {
        return $null
    }
}

function Get-BbsCommitCount {
    param([string]$ProjectKey, [string]$RepoSlug, [string]$Branch)
    try {
        $encoded = [System.Uri]::EscapeDataString($Branch)
        $total = 0; $start = 0; $limit = 1000
        do {
            $resp = Invoke-BbsApi "$BASE_URL/rest/api/1.0/projects/$ProjectKey/repos/$RepoSlug/commits?until=$encoded&limit=$limit&start=$start"
            $total += @($resp.values).Count
            $isLast = $resp.isLastPage
            if (-not $isLast) {
                if ($null -ne $resp.nextPageStart) { $start = [int]$resp.nextPageStart } else { break }
            }
        } while (-not $isLast)
        return $total
    }
    catch {
        return -1
    }
}

function Get-GhCommitCount {
    param([string]$Org, [string]$Repo, [string]$Branch)
    try {
        $encoded = [System.Uri]::EscapeDataString($Branch)
        $total = 0; $page = 1; $per = 100
        do {
            $count = [int](& gh api "/repos/$Org/$Repo/commits?sha=$encoded&per_page=$per&page=$page" --template '{{len .}}')
            $total += $count
            $page++
        } while ($count -eq $per)
        return $total
    }
    catch {
        return -1
    }
}

#endregion

#region ── Main ───────────────────────────────────────────────────────────────

$timestamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
$OutputCsv    = if ($OutputPath) { $OutputPath } else { Join-Path $SCRIPT_DIR "validation-summary-$timestamp.csv" }
$LogFile      = Join-Path $SCRIPT_DIR "validation-log-$timestamp.txt"

Write-Host "`n Bitbucket Server to GitHub Post-Migration Validation"
Write-Host "======================================================"
Write-Host "`nReading input from file : '$CsvPath'"
Write-Host "Repos loaded            : $($repoList.Count)"
Write-Host "Output CSV              : $OutputCsv"
Write-Host "Log file                : $LogFile"
Write-Host "`nStarting validation...`n"

# Write CSV header
"github_org,github_repo,bbs_project_key,bbs_repo,branch_count_bbs,branch_count_gh,branch_count_match,default_branch_bbs,default_branch_gh,sha_bbs,sha_gh,sha_match,notes" |
    Set-Content -LiteralPath $OutputCsv -Encoding UTF8

$processedCount  = 0
$matchCount      = 0
$mismatchCount   = 0
$errorCount      = 0

foreach ($entry in $repoList) {
    $projectKey  = $entry.'project-key'
    $repoSlug    = $entry.repo
    $githubOrg   = $entry.github_org
    $githubRepo  = $entry.github_repo

    $processedCount++
    $progress = "[$processedCount/$($repoList.Count)]"

    if (-not $projectKey -or -not $repoSlug -or -not $githubOrg -or -not $githubRepo) {
        Write-Host "[WARNING] $progress Skipping row with missing required fields." -ForegroundColor Yellow
        continue
    }

    Write-Host "============================================================"
    Write-Host "ℹ️  [$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))] Validating: $projectKey/$repoSlug -> $githubOrg/$githubRepo"
    Write-Host "============================================================"
    Add-Content -LiteralPath $LogFile -Value "[$([datetime]::Now)] $progress Validating: $projectKey/$repoSlug -> $githubOrg/$githubRepo"

    $notes          = ""
    $branchCountBbs = 0
    $branchCountGh  = 0
    $branchCountMatch = "false"
    $defaultBranchBbs = ""
    $defaultBranchGh  = ""
    $shaBbs         = ""
    $shaGh          = ""
    $shaMatch       = "false"

    try {
        # ── BBS branch count ─────────────────────────────────────────────────
        $branchCountBbs   = Get-BbsBranchCount -ProjectKey $projectKey -RepoSlug $repoSlug

        # ── GitHub branch count ───────────────────────────────────────────────
        $branchCountGh    = Get-GhBranchCount -Org $githubOrg -Repo $githubRepo

        if ($branchCountGh -eq -1) {
            $notes = "GitHub repo not found or not accessible"
            $errorCount++
            Write-Host "[ERROR]   $progress $projectKey/$repoSlug -> $githubOrg/$githubRepo - $notes" -ForegroundColor Red
            Add-Content -LiteralPath $LogFile -Value "[$([datetime]::Now)] [ERROR] $notes"
        }
        else {
            $branchCountMatch = if ($branchCountBbs -eq $branchCountGh) { "true" } else { "false" }
            if ($branchCountMatch -eq "true") {
                Write-Host "✅ Branch Count MATCHED | BBS=$branchCountBbs GitHub=$branchCountGh" -ForegroundColor Green
            } else {
                Write-Host "❌ Branch Count MISMATCH | BBS=$branchCountBbs GitHub=$branchCountGh" -ForegroundColor Yellow
            }

            if ($COMMIT_CHECK -ne 'true') {
                $shaMatch = "true"
                Write-Host "ℹ️ COMMIT_CHECK=false - skipping per-branch commit/SHA comparison"
                Add-Content -LiteralPath $LogFile -Value "[$([datetime]::Now)] COMMIT_CHECK=false - skipping per-branch commit/SHA comparison"
            }
            else {
                # ── Default branch SHA - BBS ──────────────────────────────────────
                $defaultBranchBbs = Get-BbsDefaultBranch -ProjectKey $projectKey -RepoSlug $repoSlug
                if ($defaultBranchBbs) {
                    $shaBbs = Get-BbsLatestSha -ProjectKey $projectKey -RepoSlug $repoSlug -Branch $defaultBranchBbs
                }

                # ── Default branch SHA - GitHub ───────────────────────────────────
                $defaultBranchGh = Get-GhDefaultBranch -Org $githubOrg -Repo $githubRepo
                if ($defaultBranchGh) {
                    $shaGh = Get-GhLatestSha -Org $githubOrg -Repo $githubRepo -Branch $defaultBranchGh
                }

                $shaMatch = if ($shaBbs -and $shaGh -and $shaBbs -eq $shaGh) { "true" } else { "false" }

                $validationBranch = if ($defaultBranchGh) { $defaultBranchGh } elseif ($defaultBranchBbs) { $defaultBranchBbs } else { "" }
                $ghBranchNames = @(Get-GhBranches -Org $githubOrg -Repo $githubRepo)
                $sampled = New-Object System.Collections.Generic.List[string]
                if ($validationBranch) { $sampled.Add($validationBranch) }
                foreach ($b in $ghBranchNames) {
                    if ($sampled.Count -ge 10) { break }
                    if ($b -eq $validationBranch) { continue }
                    $sampled.Add($b)
                }
                if ($branchCountBbs -gt 10 -or $branchCountGh -gt 10) {
                    Write-Host "ℹ️ Commit validation running only for first $($sampled.Count) branches (default branch first, max 10)"
                } else {
                    Write-Host "ℹ️ Commit validation covering $($sampled.Count) branch(es) (default branch first, max 10)"
                }
                foreach ($b in $sampled) {
                    $cBbs = Get-BbsCommitCount -ProjectKey $projectKey -RepoSlug $repoSlug -Branch $b
                    $cGh  = Get-GhCommitCount  -Org $githubOrg -Repo $githubRepo -Branch $b
                    $countOk = [bool]($cBbs -ge 0 -and $cGh -ge 0 -and $cBbs -eq $cGh)
                    if (-not $countOk) { $shaMatch = "false" }
                    $countMark = if ($countOk) { "✅ Matching" } else { "❌ Not Matching" }
                    Write-Host "Branch '$b': BBS Commits=$cBbs | GitHub Commits=$cGh | $countMark"
                    Add-Content -LiteralPath $LogFile -Value "[$([datetime]::Now)] Branch '$b': BBS Commits=$cBbs GH Commits=$cGh Match=$countOk"

                    $sBbs = Get-BbsLatestSha -ProjectKey $projectKey -RepoSlug $repoSlug -Branch $b
                    $sGh  = Get-GhLatestSha  -Org $githubOrg -Repo $githubRepo -Branch $b
                    $ok = [bool]($sBbs -and $sGh -and $sBbs -eq $sGh)
                    if (-not $ok) { $shaMatch = "false" }
                    $shaMark = if ($ok) { "✅ Matching" } else { "❌ Not Matching" }
                    Write-Host "Branch '$b': BBS SHA=$sBbs | GitHub SHA=$sGh | $shaMark"
                    Add-Content -LiteralPath $LogFile -Value "[$([datetime]::Now)] Branch '$b': BBS SHA=$sBbs GH SHA=$sGh Match=$ok"
                }
            }

            $overallMatch = $branchCountMatch -eq "true" -and $shaMatch -eq "true"

            if ($overallMatch) {
                $matchCount++
                Write-Host "[OK]      $progress $projectKey/$repoSlug -> $githubOrg/$githubRepo  --  Branches: $branchCountBbs/$branchCountGh  SHA: match" -ForegroundColor Green
            }
            else {
                $mismatchCount++
                $detail = ""
                if ($branchCountMatch -eq "false") { $detail += "branch count BBS=$branchCountBbs GH=$branchCountGh  " }
                if ($shaMatch -eq "false")          { $detail += "SHA BBS=$shaBbs GH=$shaGh" }
                Write-Host "[MISMATCH] $progress $projectKey/$repoSlug -> $githubOrg/$githubRepo  --  $detail" -ForegroundColor Yellow
            }

            Write-Host "✅ Validation completed for: $githubOrg/$githubRepo"
            Add-Content -LiteralPath $LogFile -Value "[$([datetime]::Now)] Branches BBS=$branchCountBbs GH=$branchCountGh Match=$branchCountMatch"
            Add-Content -LiteralPath $LogFile -Value "[$([datetime]::Now)] Default branch BBS=$defaultBranchBbs GH=$defaultBranchGh"
            Add-Content -LiteralPath $LogFile -Value "[$([datetime]::Now)] SHA BBS=$shaBbs GH=$shaGh Match=$shaMatch"
        }
    }
    catch {
        $notes = $_.Exception.Message
        $errorCount++
        Write-Host "[ERROR]   $progress $projectKey/$repoSlug -> $githubOrg/$githubRepo  --  $_" -ForegroundColor Red
        Add-Content -LiteralPath $LogFile -Value "[$([datetime]::Now)] [ERROR] $_"
    }

    # Write row immediately so partial results are never lost
    "$githubOrg,$githubRepo,$projectKey,$repoSlug,$branchCountBbs,$branchCountGh,$branchCountMatch,$defaultBranchBbs,$defaultBranchGh,$shaBbs,$shaGh,$shaMatch,$notes" |
        Add-Content -LiteralPath $OutputCsv -Encoding UTF8
}

#endregion

#region ── Summary ────────────────────────────────────────────────────────────

$totalRepos = $repoList.Count

if ($errorCount -gt 0 -and $matchCount -eq 0) {
    $finalMessage = "Validation could not be completed for all repos. Review errors before signing off."
    $finalColor   = "Red"
}
elseif ($mismatchCount -gt 0 -or $errorCount -gt 0) {
    $finalMessage = "Mismatches or errors detected. Review the CSV and log before signing off on migration."
    $finalColor   = "Yellow"
}
else {
    $finalMessage = "All repositories validated successfully. Migration looks good."
    $finalColor   = "Green"
}

Write-Host "`nPost-Migration Validation Summary"
Write-Host "================================="
Write-Host "[SUMMARY] Total repos   : $totalRepos"
Write-Host "[SUMMARY] Matched       : $matchCount"
Write-Host "[SUMMARY] Mismatched    : $mismatchCount"
Write-Host "[SUMMARY] Errors        : $errorCount"
Write-Host "[SUMMARY] Output CSV    : $OutputCsv"
Write-Host "[SUMMARY] Log file      : $LogFile"
Write-Host "`n$finalMessage`n" -ForegroundColor $finalColor

$failedValidation = $mismatchCount + $errorCount
if ($totalRepos -eq 0) {
    Write-Host "::notice::No repositories were validated."
}
elseif ($failedValidation -eq 0) {
    Write-Host "::notice::All $totalRepos repositories validated successfully (branch count and SHA match)"
}
elseif ($matchCount -eq 0) {
    Write-Host "::error::All $totalRepos repositories have validation discrepancies"
}
else {
    Write-Host "::warning::Validation completed with discrepancies: $matchCount matched, $failedValidation with issues (of $totalRepos)"
}

if ($FAIL_ON_VALIDATION_FAILURES -eq 'true' -and $failedValidation -gt 0) {
    Write-Host "::error::FAIL_ON_VALIDATION_FAILURES=true and $failedValidation repository(ies) failed validation."
    exit 1
}

#endregion