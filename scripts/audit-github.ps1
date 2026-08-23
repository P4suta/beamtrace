# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string] $Repository
)

$ErrorActionPreference = 'Stop'
$apiVersion = '2026-03-10'
$failures = [System.Collections.Generic.List[string]]::new()

if ($null -eq (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) is required.'
}

function Get-GitHubApi {
    param([Parameter(Mandatory)] [string] $Endpoint)

    $output = @(& gh api --method GET --header 'Accept: application/vnd.github+json' --header "X-GitHub-Api-Version: $apiVersion" $Endpoint 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub API GET $Endpoint failed: $($output -join [Environment]::NewLine)"
    }
    $text = $output -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json
}

function Assert-Policy {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { $failures.Add($Message) }
}

$repo = Get-GitHubApi -Endpoint "repos/$Repository"
Assert-Policy ($repo.visibility -eq 'public') 'Repository visibility is not public.'
Assert-Policy ($repo.description -eq 'Causal tracing and runtime diagnostics for Gleam, Elixir, and Erlang on the BEAM.') 'Repository description drifted.'
Assert-Policy ($repo.has_issues -and $repo.has_discussions -and -not $repo.has_projects -and -not $repo.has_wiki) 'Repository feature settings drifted.'
Assert-Policy ($repo.allow_squash_merge -and -not $repo.allow_merge_commit -and -not $repo.allow_rebase_merge) 'Merge strategy drifted.'
Assert-Policy ($repo.allow_auto_merge -and $repo.delete_branch_on_merge -and $repo.allow_update_branch) 'Pull request automation settings drifted.'
Assert-Policy $repo.web_commit_signoff_required 'Web commit signoff is disabled.'

$requiredTopics = @('beam', 'causal-tracing', 'debugging', 'distributed-tracing', 'elixir', 'erlang', 'gleam', 'observability', 'otp', 'tdd')
foreach ($topic in $requiredTopics) {
    Assert-Policy (@($repo.topics) -contains $topic) "Repository topic is missing: $topic"
}

if ($null -ne $repo.security_and_analysis) {
    Assert-Policy ($repo.security_and_analysis.secret_scanning.status -eq 'enabled') 'Secret scanning is disabled.'
    Assert-Policy ($repo.security_and_analysis.secret_scanning_push_protection.status -eq 'enabled') 'Secret scanning push protection is disabled.'
}

$actions = Get-GitHubApi -Endpoint "repos/$Repository/actions/permissions"
Assert-Policy ($actions.enabled -and $actions.allowed_actions -eq 'selected') 'GitHub Actions allow-list mode is disabled.'
Assert-Policy $actions.sha_pinning_required 'GitHub Actions SHA pinning is disabled.'
$selectedActions = Get-GitHubApi -Endpoint "repos/$Repository/actions/permissions/selected-actions"
Assert-Policy ($selectedActions.github_owned_allowed -and -not $selectedActions.verified_allowed) 'Selected Action publisher policy drifted.'
foreach ($pattern in @('erlef/setup-beam@*', 'ossf/scorecard-action@*')) {
    Assert-Policy (@($selectedActions.patterns_allowed) -contains $pattern) "Allowed Action pattern is missing: $pattern"
}
$workflowPermissions = Get-GitHubApi -Endpoint "repos/$Repository/actions/permissions/workflow"
Assert-Policy ($workflowPermissions.default_workflow_permissions -eq 'read') 'Workflow token default is not read-only.'
Assert-Policy (-not $workflowPermissions.can_approve_pull_request_reviews) 'Workflows may approve pull requests.'

$rulesets = @(Get-GitHubApi -Endpoint "repos/$Repository/rulesets")
foreach ($rulesetName in @('Protect main', 'Protect release tags')) {
    $summary = $rulesets | Where-Object { $_.name -eq $rulesetName -and $_.source_type -eq 'Repository' } | Select-Object -First 1
    Assert-Policy ($null -ne $summary) "Ruleset is missing: $rulesetName"
    if ($null -eq $summary) { continue }
    $ruleset = Get-GitHubApi -Endpoint "repos/$Repository/rulesets/$($summary.id)"
    Assert-Policy ($ruleset.enforcement -eq 'active') "Ruleset is not active: $rulesetName"
    $ruleTypes = @($ruleset.rules | ForEach-Object { $_.type })
    if ($rulesetName -eq 'Protect main') {
        foreach ($type in @('deletion', 'non_fast_forward', 'required_linear_history', 'required_signatures', 'pull_request', 'required_status_checks')) {
            Assert-Policy ($ruleTypes -contains $type) "Protect main is missing rule: $type"
        }
        $statusRule = $ruleset.rules | Where-Object { $_.type -eq 'required_status_checks' } | Select-Object -First 1
        Assert-Policy (@($statusRule.parameters.required_status_checks.context) -contains 'TDD Gate') 'Protect main does not require TDD Gate.'
    } else {
        foreach ($type in @('deletion', 'non_fast_forward')) {
            Assert-Policy ($ruleTypes -contains $type) "Protect release tags is missing rule: $type"
        }
    }
}

$environment = Get-GitHubApi -Endpoint "repos/$Repository/environments/release"
Assert-Policy $environment.deployment_branch_policy.custom_branch_policies 'Release environment does not use a custom tag policy.'
$deploymentPolicies = Get-GitHubApi -Endpoint "repos/$Repository/environments/release/deployment-branch-policies"
$hasReleaseTagPolicy = @($deploymentPolicies.branch_policies) | Where-Object { $_.name -eq 'v*' -and $_.type -eq 'tag' }
Assert-Policy ($null -ne $hasReleaseTagPolicy) 'Release environment is not restricted to v* tags.'

$labels = @(Get-GitHubApi -Endpoint "repos/$Repository/labels?per_page=100")
foreach ($label in @('type: bug', 'type: feature', 'type: security', 'type: dependencies', 'area: core', 'area: runtime', 'area: agent', 'area: web', 'area: tui', 'area: ci', 'priority: critical', 'status: blocked')) {
    Assert-Policy (@($labels.name) -contains $label) "Repository label is missing: $label"
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    throw "GitHub repository policy audit failed with $($failures.Count) finding(s)."
}

Write-Host "GitHub repository policy audit passed for $Repository."
exit 0
