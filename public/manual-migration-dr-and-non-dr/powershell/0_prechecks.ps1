<#
.SYNOPSIS
    Bitbucket Server pre-migration readiness check for GitHub migrations.

.DESCRIPTION
    Reads a CSV file of Bitbucket Server repositories and checks each one
    for open pull requests. Produces a timestamped output CSV reporting
    which repos are ready to migrate.

    Required CSV columns : project-key, repo
    Optional CSV columns : project-name, is-archived

    Required environment variables:
        BBS_BASE_URL   - Base URL of the Bitbucket Server instance
                         e.g. https://bitbucket.example.com

    Authentication (one of the following):
        BBS_PAT        - Personal Access Token 
        (or)
        BBS_AUTH_TYPE  - Set to "Basic", combined with:
        BBS_USERNAME   - Bitbucket username
        BBS_PASSWORD   - Bitbucket password

.PARAMETER CsvPath
    Path to the input CSV file. Defaults to repos.csv in the current directory.

.PARAMETER OutputPath
    Path for the output CSV report.
    Defaults to bbs_pr_validation_output-<timestamp>.csv

.EXAMPLE
    $env:BBS_PAT      = "your-token" 
    (or)
    $env:BBS_USERNAME   - Bitbucket username
    $env:BBS_PASSWORD   - Bitbucket password
    $env:BBS_BASE_URL = "https://bitbucket.example.com"
    .\0_prechecks.ps1

.EXAMPLE
    .\0_prechecks.ps1 -CsvPath "C:\migrations\repos.csv" -OutputPath "C:\migrations\results.csv"
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$CsvPath = "repos.csv",

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

#region ── Environment validation ────────────────────────────────────────────

if (-not $env:BBS_BASE_URL) {
    Write-Host "[ERROR] BBS_BASE_URL environment variable is not set." -ForegroundColor Red
    Write-Host "        Set it by running: `$env:BBS_BASE_URL = 'https://bitbucket.example.com'" -ForegroundColor Yellow
    exit 1
}
$BASE_URL = $env:BBS_BASE_URL.TrimEnd('/')

#endregion

#region ── CSV validation ─────────────────────────────────────────────────────

if (-not (Test-Path -LiteralPath $CsvPath)) {
    Write-Host "[ERROR] CSV file not found: $CsvPath" -ForegroundColor Red
    Write-Host "        Usage: .\0_prechecks.ps1 -CsvPath 'path\to\repos.csv'" -ForegroundColor Yellow
    exit 1
}

if ((Get-Item -LiteralPath $CsvPath).Length -eq 0) {
    Write-Host "[ERROR] CSV file is empty: $CsvPath" -ForegroundColor Red
    exit 1
}

$rawCsv    = (Get-Content -LiteralPath $CsvPath -Raw) -replace '"', ''
$csvLines  = $rawCsv -split "`r?`n" | Where-Object { $_ -ne '' }
$headerColumns = $csvLines[0] -split ','

if ($headerColumns -notcontains 'project-key' -or $headerColumns -notcontains 'repo') {
    Write-Host "[ERROR] CSV is missing required columns. Expected: project-key, repo" -ForegroundColor Red
    Write-Host "        Found header: $($csvLines[0])" -ForegroundColor Yellow
    exit 1
}

$repoList = @(Import-Csv -LiteralPath $CsvPath)

if ($repoList.Count -eq 0) {
    Write-Host "[ERROR] CSV contains no data rows." -ForegroundColor Red
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
if ($script:DisableSslVerify) {
    $script:RestArgs['SkipCertificateCheck'] = $true
    Write-Host "[WARNING] TLS certificate verification is DISABLED (BBS_DISABLE_SSL_VERIFY set). Proceeding without cert validation." -ForegroundColor Yellow
}

function Invoke-BbsApi {
    param([string]$Url)
    try {
        return Invoke-RestMethod -Uri $Url -Headers (Get-AuthHeader) -Method Get -ErrorAction Stop @script:RestArgs
    }
    catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        $msg = if ($status) { "HTTP $status" } else { $_.Exception.Message }
        throw "API call failed ($msg): $Url"
    }
}

Write-Host "`nValidating credentials against $BASE_URL ..."
try {
    $null = Invoke-BbsApi "$BASE_URL/rest/api/1.0/projects?limit=1"
    Write-Host "v Authentication successful." -ForegroundColor Green
}
catch {
    if (-not $script:DisableSslVerify -and ("$_" -match 'SSL|certificate|trust|SEC_ERROR|self-signed|CERT_')) {
        Write-Host "x TLS/SSL certificate validation failed for $BASE_URL." -ForegroundColor Red
        Write-Host "  Detail: $_" -ForegroundColor Red
        Write-Host "  If this host uses a self-signed or internal CA certificate intentionally, re-run with BBS_DISABLE_SSL_VERIFY=Y." -ForegroundColor Yellow
        exit 1
    }
    Write-Host "x Authentication failed. Verify BBS_BASE_URL and credentials." -ForegroundColor Red
    Write-Host "  Detail: $_" -ForegroundColor Red
    exit 1
}

function Get-BbsInstallPath {
    if ($env:BITBUCKET_HOME -and (Test-Path -LiteralPath $env:BITBUCKET_HOME -PathType Container)) {
        Write-Host "[OK] Bitbucket Server home found via BITBUCKET_HOME: $($env:BITBUCKET_HOME)" -ForegroundColor Green
        return
    }
    $detected = $null
    try {
        $onWindows = ($IsWindows -eq $true) -or ($env:OS -eq 'Windows_NT')
        if ($onWindows) {
            $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'bitbucket' -and $_.CommandLine -match 'home' }
            foreach ($pr in $procs) {
                if ($pr.CommandLine -match 'bitbucket[._]home=([^\s";]+)') { $detected = $Matches[1]; break }
            }
        } else {
            $line = (& ps -ef 2>$null | Select-String -Pattern 'bitbucket' | Select-String -Pattern 'home' | Select-Object -First 1)
            if ($line) {
                if ("$line" -match 'bitbucket[._]home=([^\s]+)') { $detected = $Matches[1] }
                elseif ("$line" -match '(/[^\s]+/bitbucket[^\s]*)') { $detected = $Matches[1] }
            }
        }
    } catch { }
    if ($detected) {
        $env:BITBUCKET_HOME = $detected
        Write-Host "[OK] Bitbucket Server home auto-detected from running process: $detected" -ForegroundColor Green
        return
    }
    foreach ($p in @('/var/atlassian/application-data/bitbucket','/opt/atlassian/bitbucket','C:\Atlassian\ApplicationData\Bitbucket','C:\Program Files\Atlassian\Bitbucket')) {
        if (Test-Path -LiteralPath $p -PathType Container) {
            $env:BITBUCKET_HOME = $p
            Write-Host "[OK] Bitbucket Server found at default location: $p" -ForegroundColor Green
            return
        }
    }
    $launcher = Get-Command start-bitbucket.sh, start-bitbucket.bat, bitbucket -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($launcher) {
        $bbsHome = Split-Path -Parent (Split-Path -Parent $launcher.Source)
        if (-not $bbsHome) { $bbsHome = Split-Path -Parent $launcher.Source }
        $env:BITBUCKET_HOME = $bbsHome
        Write-Host "[OK] Bitbucket Server launcher found on PATH: $($launcher.Source) (home: $bbsHome)" -ForegroundColor Green
        return
    }
    Write-Host "[WARNING] Bitbucket Server install not found locally (checked BITBUCKET_HOME, running process, default dirs, PATH). Continuing (remote/SSH migration does not require a local install)." -ForegroundColor Yellow
}
Get-BbsInstallPath

#endregion

#region ── Functions ──────────────────────────────────────────────────────────

function Get-OpenPrCount {
    param(
        [string]$ProjectKey,
        [string]$RepoSlug
    )
    $start = 0
    $total = 0
    do {
        $resp   = Invoke-BbsApi "$BASE_URL/rest/api/1.0/projects/$ProjectKey/repos/$RepoSlug/pull-requests?state=OPEN&limit=100&start=$start"
        $total += $resp.values.Count
        $isLast = $resp.isLastPage
        if (-not $isLast) {
            if ($null -ne $resp.nextPageStart) { $start = [int]$resp.nextPageStart }
            else { break }
        }
    } while (-not $isLast)
    return $total
}

function ConvertTo-SafeBool {
    param([string]$Value)
    switch ($Value.Trim().ToLower()) {
        'true'  { return $true  }
        '1'     { return $true  }
        'yes'   { return $true  }
        default { return $false }
    }
}

$script:LargeFileReport = $null
function Invoke-LargeFileScan {
    if ($env:RUN_LARGE_FILE_SCAN -match '^(?i:n|no|0|false)$') { Write-Host "[INFO] Large-file scan disabled (RUN_LARGE_FILE_SCAN)." -ForegroundColor Cyan; return }
    $thresholdMb = if ($env:LARGE_FILE_THRESHOLD_MB) { [int]$env:LARGE_FILE_THRESHOLD_MB } else { 400 }
    $thresholdBytes = [int64]$thresholdMb * 1024 * 1024
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host "[WARNING] git not found - skipping large-file (>=${thresholdMb}MB) scan." -ForegroundColor Yellow
        return
    }
    $script:LargeFileReport = "large_files_report-$timestamp.csv"
    "project_key,repo_slug,file_path,size_bytes,size_mb" | Set-Content -LiteralPath $script:LargeFileReport
    $authHeader = (Get-AuthHeader).Authorization
    $tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("bbs-lfs-" + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
    $flagged = 0; $scanned = 0
    foreach ($entry in $repoList) {
        $projKey  = $entry.'project-key'
        $repoSlug = $entry.repo
        if ([string]::IsNullOrEmpty($projKey) -or [string]::IsNullOrEmpty($repoSlug)) { continue }
        $scanned++
        $mir = Join-Path $tmpRoot "${projKey}_${repoSlug}.git"
        $gitArgs = @('-c', "http.extraHeader=Authorization: $authHeader")
        if ($script:DisableSslVerify) { $gitArgs += @('-c', 'http.sslVerify=false') }
        & git @gitArgs clone --mirror --quiet "$BASE_URL/scm/$projKey/$repoSlug.git" $mir 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Host "[WARNING] Could not clone $projKey/$repoSlug for large-file scan (skipping)." -ForegroundColor Yellow; continue }
        $objects = & git -C $mir rev-list --objects --all 2>$null
        if ($objects) {
            $batch = $objects | & git -C $mir cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' 2>$null
            foreach ($b in $batch) {
                $f = $b -split '\s+', 4
                if ($f.Count -lt 4) { continue }
                if ($f[0] -ne 'blob') { continue }
                $size = [int64]$f[2]
                if ($size -lt $thresholdBytes) { continue }
                $mb = [int]($size / 1MB)
                $path = $f[3]
                "$projKey,$repoSlug,`"$path`",$size,$mb" | Add-Content -LiteralPath $script:LargeFileReport
                Write-Host "[WARNING] Large file in $projKey/${repoSlug}: $path ($mb MB)" -ForegroundColor Yellow
                $flagged++
            }
        }
        Remove-Item -Recurse -Force -LiteralPath $mir -ErrorAction SilentlyContinue
    }
    Remove-Item -Recurse -Force -LiteralPath $tmpRoot -ErrorAction SilentlyContinue
    if ($flagged -gt 0) {
        Write-Host "[WARNING] Large-file scan: $flagged file(s) >= ${thresholdMb}MB across $scanned repo(s). Use Git LFS for these before migrating. Report: $script:LargeFileReport" -ForegroundColor Yellow
    } else {
        Write-Host "[OK] Large-file scan: no files >= ${thresholdMb}MB found across $scanned repo(s)." -ForegroundColor Green
    }
}

#endregion

#region ── Main ───────────────────────────────────────────────────────────────

Write-Host "`n Bitbucket Server Pre-Migration Readiness Check"
Write-Host "================================================"
Write-Host "`nReading input from file : '$CsvPath'"
Write-Host "Repos loaded            : $($repoList.Count)"

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$OutputCsv = if ($OutputPath) { $OutputPath } else { "bbs_pr_validation_output-$timestamp.csv" }

$csvHeader = "project_key,project_name,repo_name,is_archived,open_pr_count,warnings,ready_to_migrate"
Set-Content -LiteralPath $OutputCsv -Value $csvHeader -Encoding UTF8

$readyRepos     = New-Object System.Collections.Generic.List[string]
$prCheckFailed  = $false
$totalOpenPrs   = 0
$processedCount = 0

Write-Host "`nScanning repositories for open pull requests...`n"

foreach ($entry in $repoList) {
    $projectKey  = $entry.'project-key'
    $projectName = if ($entry.'project-name') { $entry.'project-name' } else { $entry.'project-key' }
    $repoSlug    = $entry.repo
    $isArchived  = ConvertTo-SafeBool -Value "$($entry.'is-archived')"

    $processedCount++
    $progress = "[$processedCount/$($repoList.Count)]"

    try {
        $openPrs      = Get-OpenPrCount -ProjectKey $projectKey -RepoSlug $repoSlug
        $totalOpenPrs += $openPrs
        $warnings     = if ($openPrs -gt 0) { "OPEN_PRS" } else { "" }
        $ready        = ($warnings -eq "")

        if ($ready) {
            Write-Host "[OK]      $progress $projectKey/$repoSlug  --  Open PRs: $openPrs" -ForegroundColor Green
            $readyRepos.Add("$projectKey/$repoSlug")
        }
        else {
            Write-Host "[WARNING] $progress $projectKey/$repoSlug  --  Open PRs: $openPrs" -ForegroundColor Yellow
        }

        $csvRow = "$projectKey,$projectName,$repoSlug,$isArchived,$openPrs,$warnings,$ready"
        Add-Content -LiteralPath $OutputCsv -Value $csvRow -Encoding UTF8
    }
    catch {
        $prCheckFailed = $true
        Write-Host "[ERROR]   $progress $projectKey/$repoSlug  --  $_" -ForegroundColor Red

        $csvRow = "$projectKey,$projectName,$repoSlug,$isArchived,ERROR,API_FAILURE,false"
        Add-Content -LiteralPath $OutputCsv -Value $csvRow -Encoding UTF8
    }
}

Invoke-LargeFileScan

#endregion

#region ── Summary ────────────────────────────────────────────────────────────

$hasActiveItems = $totalOpenPrs -gt 0
$hasFailures    = $prCheckFailed

if ($hasFailures -and -not $hasActiveItems) {
    $finalMessage = "Validation checks could not be completed due to API failures. Please review errors before proceeding."
    $finalColor   = "Red"
}
elseif ($hasFailures -and $hasActiveItems) {
    $finalMessage = "Open pull requests detected, but some validation checks failed. Review warnings and errors before proceeding."
    $finalColor   = "Yellow"
}
elseif (-not $hasFailures -and $hasActiveItems) {
    $finalMessage = "Open pull requests found. Continue with migration if you have reviewed and are comfortable proceeding."
    $finalColor   = "Yellow"
}
else {
    $finalMessage = "No open pull requests detected. You can proceed with migration."
    $finalColor   = "Green"
}

Write-Host "`nPre-Migration Validation Summary"
Write-Host "================================"
Write-Host "[SUMMARY] Total repos    : $processedCount"
Write-Host "[SUMMARY] Repos ready    : $($readyRepos.Count)"
Write-Host "[SUMMARY] Total open PRs : $totalOpenPrs"
Write-Host "[SUMMARY] Output CSV     : $OutputCsv"
Write-Host "`n$finalMessage`n" -ForegroundColor $finalColor

if ($hasFailures -and -not $hasActiveItems) { exit 1 }

#endregion
