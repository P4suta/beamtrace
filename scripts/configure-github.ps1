# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string] $Repository,
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string] $ReleasePleaseAppClientId
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$apiVersion = '2026-03-10'

if ($null -eq (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) is required.'
}

function Invoke-GitHubApi {
    param(
        [Parameter(Mandatory)] [string] $Method,
        [Parameter(Mandatory)] [string] $Endpoint,
        [object] $Body
    )

    $arguments = @(
        'api',
        '--method', $Method,
        '--header', 'Accept: application/vnd.github+json',
        '--header', "X-GitHub-Api-Version: $apiVersion",
        $Endpoint
    )
    if ($PSBoundParameters.ContainsKey('Body')) {
        $arguments += @('--input', '-')
        $json = $Body | ConvertTo-Json -Depth 30 -Compress
        $output = @($json | & gh @arguments 2>&1)
    } else {
        $output = @(& gh @arguments 2>&1)
    }
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub API $Method $Endpoint failed: $($output -join [Environment]::NewLine)"
    }
    $text = $output -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json
}

function Set-Ruleset {
    param([Parameter(Mandatory)] [string] $Path)

    $desired = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    $allRulesets = @(Invoke-GitHubApi -Method GET -Endpoint "repos/$Repository/rulesets")
    $existing = $allRulesets | Where-Object { $_.name -eq $desired.name -and $_.source_type -eq 'Repository' } | Select-Object -First 1
    if ($null -eq $existing) {
        Invoke-GitHubApi -Method POST -Endpoint "repos/$Repository/rulesets" -Body $desired | Out-Null
        Write-Host "Created ruleset: $($desired.name)"
    } else {
        Invoke-GitHubApi -Method PUT -Endpoint "repos/$Repository/rulesets/$($existing.id)" -Body $desired | Out-Null
        Write-Host "Updated ruleset: $($desired.name)"
    }
}

if (-not $PSCmdlet.ShouldProcess($Repository, 'Apply repository governance policy')) {
    return
}

$repositorySettings = [ordered]@{
    description = 'Causal tracing and runtime diagnostics for Gleam, Elixir, and Erlang on the BEAM.'
    has_issues = $true
    has_projects = $false
    has_wiki = $false
    has_discussions = $true
    allow_squash_merge = $true
    allow_merge_commit = $false
    allow_rebase_merge = $false
    allow_auto_merge = $true
    delete_branch_on_merge = $true
    allow_update_branch = $true
    use_squash_pr_title_as_default = $true
    squash_merge_commit_title = 'PR_TITLE'
    squash_merge_commit_message = 'PR_BODY'
    web_commit_signoff_required = $true
    security_and_analysis = [ordered]@{
        secret_scanning = @{ status = 'enabled' }
        secret_scanning_push_protection = @{ status = 'enabled' }
    }
}
Invoke-GitHubApi -Method PATCH -Endpoint "repos/$Repository" -Body $repositorySettings | Out-Null

$topics = @(
    'beam', 'causal-tracing', 'debugging', 'distributed-tracing', 'elixir',
    'erlang', 'gleam', 'observability', 'otp', 'tdd'
)
Invoke-GitHubApi -Method PUT -Endpoint "repos/$Repository/topics" -Body @{ names = $topics } | Out-Null

Invoke-GitHubApi -Method PUT -Endpoint "repos/$Repository/actions/permissions" -Body @{
    enabled = $true
    allowed_actions = 'selected'
    sha_pinning_required = $true
} | Out-Null
Invoke-GitHubApi -Method PUT -Endpoint "repos/$Repository/actions/permissions/selected-actions" -Body @{
    github_owned_allowed = $true
    verified_allowed = $false
    patterns_allowed = @('erlef/setup-beam@*', 'googleapis/release-please-action@*', 'ossf/scorecard-action@*')
} | Out-Null
Invoke-GitHubApi -Method PUT -Endpoint "repos/$Repository/actions/permissions/workflow" -Body @{
    default_workflow_permissions = 'read'
    can_approve_pull_request_reviews = $false
} | Out-Null

Invoke-GitHubApi -Method PUT -Endpoint "repos/$Repository/vulnerability-alerts" | Out-Null
Invoke-GitHubApi -Method PUT -Endpoint "repos/$Repository/automated-security-fixes" | Out-Null
Invoke-GitHubApi -Method PUT -Endpoint "repos/$Repository/private-vulnerability-reporting" | Out-Null

$releaseEnvironment = [ordered]@{
    wait_timer = 0
    deployment_branch_policy = [ordered]@{
        protected_branches = $false
        custom_branch_policies = $true
    }
}
Invoke-GitHubApi -Method PUT -Endpoint "repos/$Repository/environments/release" -Body $releaseEnvironment | Out-Null
$deploymentPolicies = Invoke-GitHubApi -Method GET -Endpoint "repos/$Repository/environments/release/deployment-branch-policies"
$releaseTagPolicy = @($deploymentPolicies.branch_policies) | Where-Object { $_.name -eq 'v*' -and $_.type -eq 'tag' } | Select-Object -First 1
if ($null -eq $releaseTagPolicy) {
    Invoke-GitHubApi -Method POST -Endpoint "repos/$Repository/environments/release/deployment-branch-policies" -Body @{
        name = 'v*'
        type = 'tag'
    } | Out-Null
}

$automationEnvironment = [ordered]@{
    wait_timer = 0
    deployment_branch_policy = [ordered]@{
        protected_branches = $false
        custom_branch_policies = $true
    }
}
Invoke-GitHubApi -Method PUT -Endpoint "repos/$Repository/environments/release-automation" -Body $automationEnvironment | Out-Null
$automationPolicies = Invoke-GitHubApi -Method GET -Endpoint "repos/$Repository/environments/release-automation/deployment-branch-policies"
$mainBranchPolicy = @($automationPolicies.branch_policies) | Where-Object { $_.name -eq 'main' -and $_.type -eq 'branch' } | Select-Object -First 1
if ($null -eq $mainBranchPolicy) {
    Invoke-GitHubApi -Method POST -Endpoint "repos/$Repository/environments/release-automation/deployment-branch-policies" -Body @{
        name = 'main'
        type = 'branch'
    } | Out-Null
}

if (-not [string]::IsNullOrWhiteSpace($ReleasePleaseAppClientId)) {
    $variables = Invoke-GitHubApi -Method GET -Endpoint "repos/$Repository/environments/release-automation/variables?per_page=100"
    $existingVariable = @($variables.variables) | Where-Object { $_.name -eq 'RELEASE_PLEASE_APP_CLIENT_ID' } | Select-Object -First 1
    if ($null -eq $existingVariable) {
        Invoke-GitHubApi -Method POST -Endpoint "repos/$Repository/environments/release-automation/variables" -Body @{
            name = 'RELEASE_PLEASE_APP_CLIENT_ID'
            value = $ReleasePleaseAppClientId
        } | Out-Null
    }
    else {
        Invoke-GitHubApi -Method PATCH -Endpoint "repos/$Repository/environments/release-automation/variables/RELEASE_PLEASE_APP_CLIENT_ID" -Body @{
            name = 'RELEASE_PLEASE_APP_CLIENT_ID'
            value = $ReleasePleaseAppClientId
        } | Out-Null
    }
}

$labels = @(
    @{ name = 'type: bug'; color = 'd73a4a'; description = 'Something is not working' },
    @{ name = 'type: feature'; color = 'a2eeef'; description = 'New or improved behavior' },
    @{ name = 'type: security'; color = 'b60205'; description = 'Security-sensitive maintenance' },
    @{ name = 'type: docs'; color = '0075ca'; description = 'Documentation change' },
    @{ name = 'type: dependencies'; color = '0366d6'; description = 'Dependency update' },
    @{ name = 'area: core'; color = '5319e7'; description = 'Core schema, query, causal, or diff logic' },
    @{ name = 'area: runtime'; color = '5319e7'; description = 'CLI, hub, relay, storage, or API runtime' },
    @{ name = 'area: agent'; color = '5319e7'; description = 'Injected Erlang agent or trace lifecycle' },
    @{ name = 'area: web'; color = '5319e7'; description = 'Browser workspace or JavaScript boundary' },
    @{ name = 'area: tui'; color = '5319e7'; description = 'Terminal client' },
    @{ name = 'area: ci'; color = '5319e7'; description = 'Automation, packaging, or repository policy' },
    @{ name = 'priority: critical'; color = 'b60205'; description = 'Immediate security or data-loss risk' },
    @{ name = 'priority: high'; color = 'd93f0b'; description = 'High-impact defect or blocker' },
    @{ name = 'priority: normal'; color = 'fbca04'; description = 'Normal project priority' },
    @{ name = 'priority: low'; color = 'c5def5'; description = 'Useful but not time-sensitive' },
    @{ name = 'status: blocked'; color = '000000'; description = 'Waiting on an external decision or dependency' },
    @{ name = 'status: needs-reproduction'; color = 'e4e669'; description = 'Needs a minimal sanitized reproduction' },
    @{ name = 'autorelease: pending'; color = 'ededed'; description = 'Release Please pull request awaiting merge' },
    @{ name = 'autorelease: tagged'; color = 'ededed'; description = 'Release Please pull request has created its tag' },
    @{ name = 'help wanted'; color = '008672'; description = 'Maintainer welcomes a focused contribution' },
    @{ name = 'good first issue'; color = '7057ff'; description = 'Scoped for a first contribution' }
)
$existingLabels = @(Invoke-GitHubApi -Method GET -Endpoint "repos/$Repository/labels?per_page=100")
foreach ($label in $labels) {
    $existingLabel = $existingLabels | Where-Object { $_.name -eq $label.name } | Select-Object -First 1
    if ($null -eq $existingLabel) {
        Invoke-GitHubApi -Method POST -Endpoint "repos/$Repository/labels" -Body $label | Out-Null
    } else {
        $encodedName = [uri]::EscapeDataString($label.name)
        Invoke-GitHubApi -Method PATCH -Endpoint "repos/$Repository/labels/$encodedName" -Body @{
            new_name = $label.name
            color = $label.color
            description = $label.description
        } | Out-Null
    }
}

Set-Ruleset -Path (Join-Path $repoRoot '.github/rulesets/main.json')
Set-Ruleset -Path (Join-Path $repoRoot '.github/rulesets/release-tags.json')

Write-Host "GitHub repository policy applied to $Repository."
