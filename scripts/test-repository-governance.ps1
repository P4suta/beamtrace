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
    'package.json',
    'package-lock.json',
    'SUPPORT.md',
    'scripts/audit-github.ps1',
    'scripts/configure-github.ps1',
    'tests/property/page_loader.test.mjs'
)

foreach ($relativePath in $requiredFiles) {
    $path = Join-Path $repoRoot $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Repository governance file is missing: $relativePath"
    }
}

$securityPolicy = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'SECURITY.md')
foreach ($marker in @(
    'https://github.com/P4suta/beamtrace/security/advisories/new',
    'within 7 days',
    'within 90 days'
)) {
    if (-not $securityPolicy.Contains($marker)) {
        throw "The security policy is missing a private reporting or disclosure commitment: $marker"
    }
}

$rootPackage = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'package.json') | ConvertFrom-Json
$fastCheckVersion = $rootPackage.devDependencies.'fast-check'
if ($fastCheckVersion -notmatch '^\d+\.\d+\.\d+$') {
    throw 'fast-check must be an exact dependency for reproducible property tests.'
}
if ($rootPackage.scripts.'test:property' -ne 'node --test tests/property/*.test.mjs') {
    throw 'The root package does not expose the property-test suite.'
}
$rootLock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'package-lock.json') | ConvertFrom-Json -AsHashtable
$lockedRoot = $rootLock['packages']['']
$lockedFastCheck = $rootLock['packages']['node_modules/fast-check']
if ($lockedRoot['devDependencies']['fast-check'] -ne $fastCheckVersion -or $lockedFastCheck['version'] -ne $fastCheckVersion) {
    throw 'The npm lockfile does not preserve the exact fast-check version.'
}
if ($lockedFastCheck['integrity'] -notmatch '^sha512-[A-Za-z0-9+/]+={0,2}$') {
    throw 'The npm lockfile does not preserve fast-check integrity metadata.'
}
$propertyTest = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'tests/property/page_loader.test.mjs')
foreach ($marker in @('from "fast-check"', 'fc.assert', 'fc.property')) {
    if (-not $propertyTest.Contains($marker)) {
        throw "The URL boundary property test is missing: $marker"
    }
}
$webAcceptance = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'scripts/test-web-e2e.ps1')
if (-not $webAcceptance.Contains('npm run test:property')) {
    throw 'The Chromium acceptance gate does not run property tests.'
}

$requiredLockfiles = @(
    'fixtures/gleam/manifest.toml',
    'packages/beamtrace_core/manifest.toml',
    'packages/beamtrace_runtime/manifest.toml',
    'packages/beamtrace_tui/manifest.toml',
    'packages/beamtrace_web/manifest.toml'
)

foreach ($relativePath in $requiredLockfiles) {
    & git -C $repoRoot ls-files --error-unmatch -- $relativePath 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Reproducible-build lockfile is not tracked: $relativePath"
    }
}

$tuiConfig = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'packages/beamtrace_tui/gleam.toml')
if ($tuiConfig -notmatch 'etui\s*=\s*\{[\s\S]*?ref\s*=\s*"[0-9a-f]{40}"[\s\S]*?\}') {
    throw 'The unreleased etui fix must be pinned to a full commit SHA.'
}
$expectedEtuiRepo = 'https://github.com/P4suta/etui.git'
$expectedEtuiCommit = '99886c6a280281c6a4b80d0d354e979eb60590e5'
if (-not $tuiConfig.Contains("git = `"$expectedEtuiRepo`"") -or -not $tuiConfig.Contains("ref = `"$expectedEtuiCommit`"")) {
    throw 'The TUI dependency does not pin the reviewed OTP 27 etui fork commit.'
}
$tuiLock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'packages/beamtrace_tui/manifest.toml')
if ($tuiLock -notmatch 'name\s*=\s*"etui"[\s\S]*?source\s*=\s*"git"[\s\S]*?commit\s*=\s*"[0-9a-f]{40}"') {
    throw 'The TUI lockfile does not preserve the pinned etui git commit.'
}
foreach ($lockPath in @('packages/beamtrace_tui/manifest.toml', 'packages/beamtrace_runtime/manifest.toml')) {
    $lock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot $lockPath)
    if (-not $lock.Contains("repo = `"$expectedEtuiRepo`"") -or -not $lock.Contains("commit = `"$expectedEtuiCommit`"")) {
        throw "The lockfile does not preserve the reviewed etui source: $lockPath"
    }
}

$webConfig = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'packages/beamtrace_web/gleam.toml')
if ($webConfig -notmatch 'lustre\s*=\s*\{[\s\S]*?ref\s*=\s*"[0-9a-f]{40}"[\s\S]*?\}') {
    throw 'The patched Lustre dependency must be pinned to a full commit SHA.'
}
$expectedLustreRepo = 'https://github.com/P4suta/lustre.git'
$expectedLustreCommit = '2d0b444a52bab6da8637c7f3a5f6c26399eb200f'
if (-not $webConfig.Contains("git = `"$expectedLustreRepo`"") -or -not $webConfig.Contains("ref = `"$expectedLustreCommit`"")) {
    throw 'The web dependency does not pin the reviewed single-pass Lustre commit.'
}
$webLock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'packages/beamtrace_web/manifest.toml')
if ($webLock -notmatch 'name\s*=\s*"lustre"[\s\S]*?source\s*=\s*"git"[\s\S]*?commit\s*=\s*"[0-9a-f]{40}"') {
    throw 'The web lockfile does not preserve the pinned Lustre git commit.'
}
if (-not $webLock.Contains("repo = `"$expectedLustreRepo`"") -or -not $webLock.Contains("commit = `"$expectedLustreCommit`"")) {
    throw 'The web lockfile does not preserve the reviewed Lustre source.'
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
if (@($mainRuleset.bypass_actors).Count -ne 0) {
    throw 'The main ruleset must not rely on an administrator bypass.'
}
$mainRuleTypes = @($mainRuleset.rules | ForEach-Object { $_.type })
foreach ($ruleType in @('deletion', 'non_fast_forward', 'required_linear_history', 'required_signatures', 'pull_request', 'required_status_checks')) {
    if ($mainRuleTypes -notcontains $ruleType) {
        throw "The main ruleset is missing rule: $ruleType"
    }
}
$pullRequestRule = $mainRuleset.rules | Where-Object { $_.type -eq 'pull_request' } | Select-Object -First 1
if (@($pullRequestRule.parameters.allowed_merge_methods).Count -ne 1 -or @($pullRequestRule.parameters.allowed_merge_methods) -notcontains 'squash') {
    throw 'The main ruleset must allow only squash merges.'
}
if ($pullRequestRule.parameters.required_approving_review_count -ne 0) {
    throw 'The solo-maintainer policy must not require an impossible independent approval.'
}
if ($pullRequestRule.parameters.require_code_owner_review) {
    throw 'The solo-maintainer policy must not require the pull request author to approve their own change.'
}
if ($pullRequestRule.parameters.require_last_push_approval) {
    throw 'The solo-maintainer policy must not require a second maintainer after the last push.'
}
if (-not $pullRequestRule.parameters.required_review_thread_resolution) {
    throw 'The main ruleset must require every review thread to be resolved.'
}
$statusRule = $mainRuleset.rules | Where-Object { $_.type -eq 'required_status_checks' } | Select-Object -First 1
foreach ($requiredCheck in @('TDD Gate', 'Dependency review', 'CodeQL / JavaScript')) {
    if (@($statusRule.parameters.required_status_checks.context) -notcontains $requiredCheck) {
        throw "The main ruleset does not require security and TDD check: $requiredCheck"
    }
}
if (-not $statusRule.parameters.strict_required_status_checks_policy) {
    throw 'The main ruleset must test the current base before merge.'
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
