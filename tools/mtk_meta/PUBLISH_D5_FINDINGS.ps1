param(
  [Parameter(Mandatory=$true)]
  [string]$CampaignRoot,

  [string]$ResearchRepoRoot = "",

  [ValidatePattern('^[A-Za-z0-9._/-]+$')]
  [string]$EvidenceBranch = "evidence/auto",

  [switch]$OpenPullRequest
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Step([string]$Text) { Write-Host "`n=== $Text ===" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host $Text -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host $Text -ForegroundColor Yellow }

function Invoke-Git {
  param(
    [Parameter(Mandatory=$true)][string]$WorkingDirectory,
    [Parameter(Mandatory=$true)][string[]]$Arguments,
    [switch]$AllowFailure
  )
  $output = & git -C $WorkingDirectory @Arguments 2>&1
  $code = $LASTEXITCODE
  if ($code -ne 0 -and !$AllowFailure) {
    throw "git $($Arguments -join ' ') failed ($code):`n$($output -join "`n")"
  }
  return [pscustomobject]@{ ExitCode=$code; Output=@($output) }
}

function Resolve-Python {
  $py = Get-Command py -ErrorAction SilentlyContinue
  if ($py) { return @{ File = $py.Source; Prefix = @("-3") } }
  $python = Get-Command python -ErrorAction SilentlyContinue
  if ($python) { return @{ File = $python.Source; Prefix = @() } }
  throw "Python 3 was not found."
}

$ResolvedCampaignRoot = (Resolve-Path $CampaignRoot).Path
if (!$ResearchRepoRoot) { $ResearchRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path }
$ResolvedRepoRoot = (Resolve-Path $ResearchRepoRoot).Path
$SanitizedRoot = Join-Path $ResolvedCampaignRoot "sanitized"
$PublicationManifestPath = Join-Path $SanitizedRoot "publication_manifest.json"
$Analyzer = Join-Path $ResolvedRepoRoot "tools\mtk_meta\meta_investigator.py"

if (!(Test-Path (Join-Path $ResolvedRepoRoot ".git"))) {
  throw "ResearchRepoRoot is not a Git clone: $ResolvedRepoRoot"
}
if (!(Test-Path $PublicationManifestPath)) {
  throw "Missing sanitized publication manifest: $PublicationManifestPath"
}
if (!(Test-Path $Analyzer)) { throw "Missing analyzer: $Analyzer" }

$Publication = Get-Content $PublicationManifestPath -Raw | ConvertFrom-Json
if (!$Publication.redaction_verified) { throw "Publication manifest says redaction verification failed." }
if ($Publication.raw_logs_included) { throw "Publication manifest unexpectedly includes raw logs." }
if ($Publication.write_allowed) { throw "Publication manifest unexpectedly permits writes." }
$CampaignId = [string]$Publication.campaign_id
if (!$CampaignId) { throw "Publication manifest has no campaign_id." }

$AllowedFiles = @(
  "campaign_findings.json",
  "campaign_findings.md",
  "sanitized_excerpts.log",
  "publication_manifest.json"
)
foreach ($name in $AllowedFiles) {
  if (!(Test-Path (Join-Path $SanitizedRoot $name))) { throw "Missing sanitized file: $name" }
}

$Python = Resolve-Python
$pythonExe = $Python.File
$verifyArgs = @($Python.Prefix) + @($Analyzer, "verify", "--output", $SanitizedRoot)
& $pythonExe @verifyArgs
if ($LASTEXITCODE -ne 0) { throw "Sanitized publication verification failed." }

Write-Step "PREPARE EVIDENCE WORKTREE"
Invoke-Git -WorkingDirectory $ResolvedRepoRoot -Arguments @("fetch", "origin", "--prune") | Out-Null
$RemoteProbe = Invoke-Git -WorkingDirectory $ResolvedRepoRoot -Arguments @("show-ref", "--verify", "--quiet", "refs/remotes/origin/$EvidenceBranch") -AllowFailure
$BaseRef = if ($RemoteProbe.ExitCode -eq 0) { "origin/$EvidenceBranch" } else { "origin/main" }
$SafeCampaignId = ($CampaignId -replace '[^A-Za-z0-9._-]', '_')
$Worktree = Join-Path $env:TEMP "ttg-meta-evidence-$SafeCampaignId"
if (Test-Path $Worktree) { Remove-Item -Recurse -Force $Worktree }

try {
  Invoke-Git -WorkingDirectory $ResolvedRepoRoot -Arguments @("worktree", "add", "--detach", $Worktree, $BaseRef) | Out-Null
  Invoke-Git -WorkingDirectory $Worktree -Arguments @("config", "user.name", "TTG META Lab") | Out-Null
  Invoke-Git -WorkingDirectory $Worktree -Arguments @("config", "user.email", "meta-lab@thetechguyds.com") | Out-Null

  $Destination = Join-Path $Worktree "evidence\campaigns\$CampaignId"
  New-Item -ItemType Directory -Force $Destination | Out-Null
  foreach ($name in $AllowedFiles) {
    Copy-Item (Join-Path $SanitizedRoot $name) (Join-Path $Destination $name) -Force
  }

  $EvidenceRoot = Join-Path $Worktree "evidence"
  New-Item -ItemType Directory -Force $EvidenceRoot | Out-Null
  $Latest = [ordered]@{
    schema_version = "ttg.mtk-meta.evidence-latest.v1"
    campaign_id = $CampaignId
    evidence_path = "evidence/campaigns/$CampaignId"
    findings = "evidence/campaigns/$CampaignId/campaign_findings.json"
    verdict = (Get-Content (Join-Path $Destination "campaign_findings.json") -Raw | ConvertFrom-Json).verdict
    published_at = (Get-Date).ToUniversalTime().ToString("o")
    branch = $EvidenceBranch
    research_mode = "read_only"
    write_allowed = $false
  }
  $Latest | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $EvidenceRoot "latest.json") -Encoding UTF8

  $IndexPath = Join-Path $EvidenceRoot "index.json"
  $Entries = @()
  if (Test-Path $IndexPath) {
    try { $Entries = @((Get-Content $IndexPath -Raw | ConvertFrom-Json).campaigns) } catch { $Entries = @() }
  }
  $Entries = @($Entries | Where-Object { $_.campaign_id -ne $CampaignId })
  $Entries += [pscustomobject]@{
    campaign_id = $CampaignId
    evidence_path = "evidence/campaigns/$CampaignId"
    verdict = $Latest.verdict
    published_at = $Latest.published_at
  }
  $Entries = @($Entries | Sort-Object published_at -Descending | Select-Object -First 50)
  [ordered]@{
    schema_version = "ttg.mtk-meta.evidence-index.v1"
    updated_at = (Get-Date).ToUniversalTime().ToString("o")
    branch = $EvidenceBranch
    campaigns = $Entries
  } | ConvertTo-Json -Depth 8 | Set-Content $IndexPath -Encoding UTF8

  $ReadmePath = Join-Path $EvidenceRoot "README.md"
  if (!(Test-Path $ReadmePath)) {
    @"
# Automated sanitized META evidence

This branch receives sanitized, read-only campaign findings from
`RUN_D5_META_FIVE_RUN_CAMPAIGN.ps1 -Publish`.

Raw device logs, vendor binaries, downloaded databases, and unique identifiers are never committed.
Use `latest.json` to locate the newest campaign.
"@ | Set-Content $ReadmePath -Encoding UTF8
  }

  Invoke-Git -WorkingDirectory $Worktree -Arguments @("add", "evidence") | Out-Null
  $Diff = Invoke-Git -WorkingDirectory $Worktree -Arguments @("diff", "--cached", "--quiet") -AllowFailure
  if ($Diff.ExitCode -eq 0) {
    Write-Warn "No new sanitized evidence to commit."
    exit 0
  }
  Invoke-Git -WorkingDirectory $Worktree -Arguments @("commit", "-m", "evidence: $CampaignId") | Out-Null

  Write-Step "PUSH SANITIZED EVIDENCE"
  $Push = Invoke-Git -WorkingDirectory $Worktree -Arguments @("push", "origin", "HEAD:refs/heads/$EvidenceBranch") -AllowFailure
  if ($Push.ExitCode -ne 0) {
    Write-Warn "Evidence branch moved; retrying once with rebase."
    Invoke-Git -WorkingDirectory $Worktree -Arguments @("fetch", "origin", $EvidenceBranch) | Out-Null
    Invoke-Git -WorkingDirectory $Worktree -Arguments @("rebase", "origin/$EvidenceBranch") | Out-Null
    Invoke-Git -WorkingDirectory $Worktree -Arguments @("push", "origin", "HEAD:refs/heads/$EvidenceBranch") | Out-Null
  }

  $Commit = (Invoke-Git -WorkingDirectory $Worktree -Arguments @("rev-parse", "HEAD")).Output[0]
  Write-Ok "Evidence branch: $EvidenceBranch"
  Write-Ok "Evidence commit: $Commit"
  Write-Ok "Campaign path: evidence/campaigns/$CampaignId"

  if ($OpenPullRequest) {
    $Gh = Get-Command gh -ErrorAction SilentlyContinue
    if (!$Gh) {
      Write-Warn "GitHub CLI not found; evidence was pushed but no PR was opened."
    } else {
      $RemoteUrl = (Invoke-Git -WorkingDirectory $Worktree -Arguments @("remote", "get-url", "origin")).Output[0]
      $RepoSlug = $RemoteUrl -replace '^https://github.com/','' -replace '^git@github.com:','' -replace '\.git$',''
      $ghExe = $Gh.Source
      $Existing = & $ghExe pr list --repo $RepoSlug --head $EvidenceBranch --base main --state open --json number --jq '.[0].number' 2>$null
      if (!$Existing) {
        & $ghExe pr create --repo $RepoSlug --head $EvidenceBranch --base main --title "evidence: automated META campaigns" --body "Sanitized read-only META campaign evidence. Raw identifiers and vendor files are excluded."
        if ($LASTEXITCODE -ne 0) { Write-Warn "Evidence pushed, but PR creation failed." }
      } else {
        Write-Ok "Existing evidence PR: #$Existing"
      }
    }
  }
} finally {
  if (Test-Path $Worktree) {
    Invoke-Git -WorkingDirectory $ResolvedRepoRoot -Arguments @("worktree", "remove", "--force", $Worktree) -AllowFailure | Out-Null
  }
}
