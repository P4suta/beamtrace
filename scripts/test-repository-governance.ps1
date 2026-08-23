# SPDX-License-Identifier: Apache-2.0 OR MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

$requiredFiles = @(
    '.gitattributes',
    'LICENSE',
    '.github/CODEOWNERS',
    '.github/ISSUE_TEMPLATE/bug.yml',
    '.github/ISSUE_TEMPLATE/feature.yml',
    '.github/ISSUE_TEMPLATE/config.yml',
    '.github/pull_request_template.md',
    '.github/dependabot.yml',
    '.github/workflows/security.yml',
    '.github/rulesets/main.json',
    '.github/rulesets/release-tags.json',
    'docs/github-governance.md',
    'GOVERNANCE.md',
    'SUPPORT.md',
    'scripts/audit-github.ps1',
    'scripts/configure-github.ps1'
)

foreach ($relativePath in $requiredFiles) {
    $path = Join-Path $repoRoot $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Repository governance file is missing: $relativePath"
    }
}

$license = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'LICENSE')
foreach ($marker in @('Apache License 2.0', 'MIT License', 'LICENSES/Apache-2.0.txt', 'LICENSES/MIT.txt')) {
    if (-not $license.Contains($marker)) {
        throw "Root license notice is missing: $marker"
    }
}

$attributes = Get-Content -Raw -LiteralPath (Join-Path $repoRoot '.gitattributes')
foreach ($marker in @('* text=auto eol=lf', '*.cmd text eol=crlf', '*.beamtrace binary', '*.zip binary')) {
    if (-not $attributes.Contains($marker)) {
        throw "Git attributes are missing: $marker"
    }
}

$codeowners = Get-Content -Raw -LiteralPath (Join-Path $repoRoot '.github/CODEOWNERS')
foreach ($marker in @('* @P4suta', '/.github/ @P4suta', '/SECURITY.md @P4suta')) {
    if (-not $codeowners.Contains($marker)) {
        throw "CODEOWNERS is missing: $marker"
    }
}

$ci = Get-Content -Raw -LiteralPath (Join-Path $repoRoot '.github/workflows/ci.yml')
foreach ($marker in @(
    'name: TDD Gate',
    'if: ${{ always() }}',
    'needs: [compatibility, distribution, language-fixtures, browser-e2e, oci, repository-governance]',
    './scripts/test-repository-governance.ps1'
)) {
    if (-not $ci.Contains($marker)) {
        throw "CI governance gate is missing: $marker"
    }
}

$securityWorkflow = Get-Content -Raw -LiteralPath (Join-Path $repoRoot '.github/workflows/security.yml')
foreach ($marker in @(
    'actions/dependency-review-action@',
    'github/codeql-action/init@',
    'github/codeql-action/analyze@',
    'ossf/scorecard-action@',
    'github/codeql-action/upload-sarif@'
)) {
    if (-not $securityWorkflow.Contains($marker)) {
        throw "Security workflow is missing: $marker"
    }
}

$release = Get-Content -Raw -LiteralPath (Join-Path $repoRoot '.github/workflows/release.yml')
if (-not $release.Contains('environment: release')) {
    throw 'The publishing job is not protected by the release environment.'
}

$dependabot = Get-Content -Raw -LiteralPath (Join-Path $repoRoot '.github/dependabot.yml')
foreach ($marker in @('package-ecosystem: "github-actions"', 'package-ecosystem: "npm"', 'interval: "weekly"')) {
    if (-not $dependabot.Contains($marker)) {
        throw "Dependabot policy is missing: $marker"
    }
}

$mainRuleset = Get-Content -Raw -LiteralPath (Join-Path $repoRoot '.github/rulesets/main.json') | ConvertFrom-Json
if ($mainRuleset.name -ne 'Protect main') { throw 'The main ruleset has an unexpected name.' }
if ($mainRuleset.enforcement -ne 'active') { throw 'The main ruleset is not active.' }
$mainRuleTypes = @($mainRuleset.rules | ForEach-Object { $_.type })
foreach ($ruleType in @('deletion', 'non_fast_forward', 'required_linear_history', 'required_signatures', 'pull_request', 'required_status_checks')) {
    if ($mainRuleTypes -notcontains $ruleType) {
        throw "The main ruleset is missing rule: $ruleType"
    }
}
$statusRule = $mainRuleset.rules | Where-Object { $_.type -eq 'required_status_checks' } | Select-Object -First 1
if (@($statusRule.parameters.required_status_checks.context) -notcontains 'TDD Gate') {
    throw 'The main ruleset does not require TDD Gate.'
}

$tagRuleset = Get-Content -Raw -LiteralPath (Join-Path $repoRoot '.github/rulesets/release-tags.json') | ConvertFrom-Json
if ($tagRuleset.name -ne 'Protect release tags') { throw 'The tag ruleset has an unexpected name.' }
if (@($tagRuleset.conditions.ref_name.include) -notcontains 'refs/tags/v*') {
    throw 'The tag ruleset does not target release tags.'
}

$workflowFiles = Get-ChildItem -LiteralPath (Join-Path $repoRoot '.github/workflows') -Filter '*.yml' -File
foreach ($workflowFile in $workflowFiles) {
    $source = Get-Content -Raw -LiteralPath $workflowFile.FullName
    $uses = [regex]::Matches($source, '(?m)^\s*- uses:\s*([^\s#]+)')
    foreach ($match in $uses) {
        $action = $match.Groups[1].Value
        if ($action -notmatch '@[0-9a-f]{40}$') {
            throw "Action is not pinned to a full commit SHA in $($workflowFile.Name): $action"
        }
    }
}

Write-Host 'Repository governance acceptance passed.'
exit 0
