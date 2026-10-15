#Requires -Version 5.1
<#
.SYNOPSIS
    Create the GitHub repository, push main, and lock it down so that every
    change must arrive as an approved Pull Request with green required checks.

.DESCRIPTION
    Idempotent helper. It performs:
      1. create the repository (from governance/repository-settings.json)
      2. add the git remote and push main + tags
      3. protect `main` (from governance/branch-protection.json):
         - PR required, >=1 approving review, code-owner review required
         - stale reviews dismissed, last-push approval required
         - required status checks (CI jobs) must be green and up to date
         - no force push, no deletion, squash-merge only, linear history
      4. create the first release tag (optional, -Release)

    Requires a token with the `repo` scope. It is never written to disk:
    pass -Token or set $env:GH_TOKEN / $env:GITHUB_TOKEN.

    NOTE: run this AFTER an initial `git init && git add -A && git commit`.

.EXAMPLE
    $env:GH_TOKEN = 'ghp_xxx'          # or -Token (Read-Host -AsSecureString below)
    pwsh -File tools/create-github-repo.ps1 -Owner cadywang

.EXAMPLE
    # Dry run: print the exact API calls without touching GitHub
    pwsh -File tools/create-github-repo.ps1 -Owner cadywang -DryRun
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Owner,
  [string]$Repo = 'serial-debug-bridge',
  [string]$Token = '',
  [string]$BaseBranch = 'main',
  [switch]$Private,
  [switch]$DryRun,
  [switch]$Release
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$api = 'https://api.github.com'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
  if (-not $Token) {
    $Token = if ($env:GH_TOKEN) { $env:GH_TOKEN } elseif ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { '' }
  }
  if (-not $Token -and -not $DryRun) {
    $sec = Read-Host -Prompt 'GitHub token (repo scope)' -AsSecureString
    $Token = [Runtime.InteropServices.Marshal]::PtrToStringUni(
      [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($sec))
  }

  $headers = @{
    'Authorization' = "Bearer $Token"
    'Accept'        = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'    = 'serial-debug-bridge-bootstrap'
  }

  function Invoke-Gh([string]$Method, [string]$Uri, $Body, [string]$OkNote) {
    if ($DryRun) {
      Write-Host "[dry-run] $Method $Uri"
      if ($null -ne $Body) { Write-Host ($Body | ConvertTo-Json -Depth 8) }
      return $null
    }
    try {
      if ($null -ne $Body) {
        $json = $Body | ConvertTo-Json -Depth 10
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers `
                 -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($json))
      }
      return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
    } catch {
      $detail = ''
      try { $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream()); $detail = $sr.ReadToEnd() } catch {}
      Write-Host "FAILED: $Method $Uri`n$detail"
      if ($Method -eq 'POST' -and $Uri -match '/users?/repos$') {
        Write-Host ''
        Write-Host '  This token may not be allowed to create repositories.'
        Write-Host '  GitHub App user tokens (ghu_..., e.g. the VS Code sign-in) carry only'
        Write-Host '  repository read/write rights, while creating a repository additionally'
        Write-Host '  needs the application itself to hold administration:write.'
        Write-Host '  Pushing and branch protection DO work with such a token, so:'
        Write-Host '    1) create the repository once at https://github.com/new and leave it'
        Write-Host '       EMPTY (no README, no .gitignore, no licence);'
        Write-Host '    2) re-run this script, it will detect the existing repository.'
        Write-Host '  Or use a token that can create:  $env:GH_TOKEN = ''ghp_...'''
        Write-Host ''
      }
      throw
    }
  }

  # ---- 0. sanity: local git repo with at least one commit ----
  $git = (Get-Command git -ErrorAction SilentlyContinue)
  if (-not $git) { throw 'git not found on PATH' }
  & git rev-parse --is-inside-work-tree *> $null
  if ($LASTEXITCODE -ne 0) { throw "not a git work tree: $root" }
  & git rev-parse HEAD *> $null
  if ($LASTEXITCODE -ne 0) { throw 'no commit yet; run: git add -A && git commit' }

  $settings = Get-Content -Raw "$root\governance\repository-settings.json" | ConvertFrom-Json
  $protection = Get-Content -Raw "$root\governance\branch-protection.json" | ConvertFrom-Json

  # ---- 1. create repository ----
  Write-Host "==> repository"
  $existing = $null
  if (-not $DryRun) {
    try { $existing = Invoke-Gh 'GET' "$api/repos/$Owner/$Repo" $null } catch { $existing = $null }
  }
  if ($existing) {
    Write-Host "    exists: $($existing.full_name) (visibility=$($existing.private))"
    Invoke-Gh 'PATCH' "$api/repos/$Owner/$Repo" @{
      description              = $settings.description
      has_issues               = [bool]$settings.has_issues
      has_projects             = [bool]$settings.has_projects
      has_wiki                 = [bool]$settings.has_wiki
      has_discussions          = [bool]$settings.has_discussions
      allow_squash_merge       = [bool]$settings.allow_squash_merge
      allow_merge_commit       = [bool]$settings.allow_merge_commit
      allow_rebase_merge       = [bool]$settings.allow_rebase_merge
      allow_auto_merge         = [bool]$settings.allow_auto_merge
      delete_branch_on_merge   = [bool]$settings.delete_branch_on_merge
      squash_merge_commit_message = $settings.squash_merge_commit_message
      squash_merge_commit_title  = $settings.squash_merge_commit_title
      merge_commit_title         = $settings.merge_commit_title
    } 'patch' | Out-Null
  } else {
    $body = @{
      name                     = $Repo
      description              = $settings.description
      homepage                 = $settings.homepage
      private                  = [bool]($Private -or $settings.private)
      has_issues               = [bool]$settings.has_issues
      has_projects             = [bool]$settings.has_projects
      has_wiki                 = [bool]$settings.has_wiki
      auto_init                = $false
      squash_merge_commit_message = $settings.squash_merge_commit_message
      squash_merge_commit_title  = $settings.squash_merge_commit_title
      merge_commit_title         = $settings.merge_commit_title
      allow_squash_merge       = [bool]$settings.allow_squash_merge
      allow_merge_commit       = [bool]$settings.allow_merge_commit
      allow_rebase_merge       = [bool]$settings.allow_rebase_merge
      delete_branch_on_merge   = [bool]$settings.delete_branch_on_merge
    }
    Invoke-Gh 'POST' "$api/users/$Owner/repos" $body 'create' | Out-Null
    Write-Host "    created $Owner/$Repo"
  }

  # topics (separate endpoint, preview header not required anymore)
  if ($settings.topics) {
    if (-not $DryRun) {
      $t = @{ names = @($settings.topics) } | ConvertTo-Json
      Invoke-WebRequest -Method Put -Uri "$api/repos/$Owner/$Repo/topics" -Headers $headers `
        -ContentType 'application/vnd.github.mercy-preview+json' -Body ([Text.Encoding]::UTF8.GetBytes($t)) `
        -UseBasicParsing | Out-Null
      Write-Host "    topics set"
    } else { Write-Host "[dry-run] PUT topics" }
  }

  # ---- 2. push ----
  Write-Host "==> push"
  $remoteUrl = "https://github.com/$Owner/$Repo.git"
  $has = (& git remote get-url origin 2>$null)
  if ($LASTEXITCODE -ne 0) { & git remote add origin $remoteUrl } else { & git remote set-url origin $remoteUrl }
  & git branch -M $BaseBranch
  if (-not $DryRun) {
    & git -c "http.extraheader=AUTHORIZATION: basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($Owner):$Token")))" `
        push --quiet -u origin $BaseBranch
    if ($LASTEXITCODE -ne 0) { throw 'git push failed' }
    & git -c "http.extraheader=AUTHORIZATION: basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($Owner):$Token")))" `
        push --quiet --tags
    Write-Host "    pushed $BaseBranch (+tags)"
  } else { Write-Host "[dry-run] push origin $BaseBranch --tags" }

  # ---- 3. branch protection ----
  Write-Host "==> protect $BaseBranch (PR + approval + required checks)"
  $payload = @{
    required_status_checks = @{
      strict   = [bool]$protection.required_status_checks.strict
      contexts = @($protection.required_status_checks.contexts)
    }
    enforce_admins                  = [bool]$protection.enforce_admins
    required_pull_request_reviews   = @{
      dismiss_stale_reviews          = [bool]$protection.required_pull_request_reviews.dismiss_stale_reviews
      require_code_owner_reviews     = [bool]$protection.required_pull_request_reviews.require_code_owner_reviews
      required_approving_review_count = [int]$protection.required_pull_request_reviews.required_approving_review_count
      require_last_push_approval     = [bool]$protection.required_pull_request_reviews.require_last_push_approval
    }
    restrictions             = $null
    required_linear_history  = [bool]$protection.required_linear_history
    allow_force_pushes       = [bool]$protection.allow_force_pushes
    allow_deletions          = [bool]$protection.allow_deletions
    block_creations          = [bool]$protection.block_creations
    required_conversation_resolution = [bool]$protection.required_conversation_resolution
    lock_branch              = [bool]$protection.lock_branch
    allow_fork_syncing       = [bool]$protection.allow_fork_syncing
  }
  Invoke-Gh 'PUT' "$api/repos/$Owner/$Repo/branches/$BaseBranch/protection" $payload 'protection' | Out-Null

  # ---- 4. optional release ----
  if ($Release) {
    $ver = (& git describe --tags --abbrev=0 2>$null)
    if ($LASTEXITCODE -eq 0 -and $ver) {
      Write-Host "==> release $ver"
      Invoke-Gh 'POST' "$api/repos/$Owner/$Repo/releases" @{
        tag_name = $ver; name = $ver; generate_release_notes = $true; draft = $false; prerelease = $false
      } 'release' | Out-Null
    } else { Write-Host '    no tag found, skipping release' }
  }

  Write-Host ''
  Write-Host "Done. https://github.com/$Owner/$Repo"
  Write-Host "  - direct pushes to $BaseBranch are blocked for everyone (incl. admins)"
  Write-Host "  - a PR needs >=1 approving review (+ code owner) and green required checks"
}
finally { Pop-Location }
