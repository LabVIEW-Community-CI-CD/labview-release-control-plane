#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Enrollment contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:surfaceEnrollmentPath = Join-Path $script:repoRoot 'enrollments/labview-cdev-surface-fork.json'
        $script:cliEnrollmentPath = Join-Path $script:repoRoot 'enrollments/labview-cdev-cli.json'
        $script:policyPath = Join-Path $script:repoRoot 'policies/platform-policy.json'

        foreach ($path in @($script:surfaceEnrollmentPath, $script:cliEnrollmentPath, $script:policyPath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Missing enrollment contract file: $path"
            }
        }

        $script:surfaceEnrollment = Get-Content -LiteralPath $script:surfaceEnrollmentPath -Raw | ConvertFrom-Json -Depth 100
        $script:cliEnrollment = Get-Content -LiteralPath $script:cliEnrollmentPath -Raw | ConvertFrom-Json -Depth 100
        $script:platformPolicy = Get-Content -LiteralPath $script:policyPath -Raw | ConvertFrom-Json -Depth 100
    }

    It 'enrolls surface and cdev-cli repos as initial wave set' {
        [string]$script:surfaceEnrollment.repo_id | Should -Be 'LabVIEW-Community-CI-CD/labview-cdev-surface-fork'
        [string]$script:cliEnrollment.repo_id | Should -Be 'LabVIEW-Community-CI-CD/labview-cdev-cli'
    }

    It 'tracks cdev-cli runtime lineage requirement for enrolled repos' {
        [string]$script:surfaceEnrollment.runtime_lineage_requirements.runtime_image_repository | Should -Be 'ghcr.io/labview-community-ci-cd/labview-cdev-cli-runtime'
        [bool]$script:surfaceEnrollment.runtime_lineage_requirements.runtime_image_digest_required | Should -BeTrue
        [bool]$script:surfaceEnrollment.runtime_lineage_requirements.source_commit_required | Should -BeTrue
    }

    It 'defines autonomy and stable-window governance defaults' {
        [string]$script:platformPolicy.platform_policy.autonomy | Should -Be 'autonomous_with_guardrails'
        @($script:platformPolicy.platform_policy.stable_window_policy.allowed_utc_weekdays) | Should -Contain 'Monday'
        [bool]$script:platformPolicy.platform_policy.break_glass_policy.audit_required | Should -BeTrue
    }
}
