#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Platform contract schema files' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:policySchemaPath = Join-Path $script:repoRoot 'contracts/platform-policy.schema.json'
        $script:enrollmentSchemaPath = Join-Path $script:repoRoot 'contracts/repo-enrollment.schema.json'
        $script:programReportSchemaPath = Join-Path $script:repoRoot 'contracts/program-report.schema.json'
        $script:incidentEnvelopeSchemaPath = Join-Path $script:repoRoot 'contracts/incident-envelope.schema.json'

        foreach ($path in @($script:policySchemaPath, $script:enrollmentSchemaPath, $script:programReportSchemaPath, $script:incidentEnvelopeSchemaPath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Missing contract schema file: $path"
            }
        }

        $script:policySchema = Get-Content -LiteralPath $script:policySchemaPath -Raw | ConvertFrom-Json -Depth 100
        $script:enrollmentSchema = Get-Content -LiteralPath $script:enrollmentSchemaPath -Raw | ConvertFrom-Json -Depth 100
        $script:programReportSchema = Get-Content -LiteralPath $script:programReportSchemaPath -Raw | ConvertFrom-Json -Depth 100
        $script:incidentEnvelopeSchema = Get-Content -LiteralPath $script:incidentEnvelopeSchemaPath -Raw | ConvertFrom-Json -Depth 100
    }

    It 'defines required top-level policy contract keys' {
        @($script:policySchema.properties.platform_policy.required) | Should -Contain 'schema_version'
        @($script:policySchema.properties.platform_policy.required) | Should -Contain 'autonomy'
        @($script:policySchema.properties.platform_policy.required) | Should -Contain 'slo'
        @($script:policySchema.properties.platform_policy.required) | Should -Contain 'error_budget'
        @($script:policySchema.properties.platform_policy.required) | Should -Contain 'freeze_policy'
        @($script:policySchema.properties.platform_policy.required) | Should -Contain 'rollback_policy'
        @($script:policySchema.properties.platform_policy.required) | Should -Contain 'stable_window_policy'
        @($script:policySchema.properties.platform_policy.required) | Should -Contain 'break_glass_policy'
        @($script:policySchema.properties.platform_policy.required) | Should -Contain 'dependency_gates'
    }

    It 'defines required enrollment contract keys' {
        @($script:enrollmentSchema.required) | Should -Contain 'repo_id'
        @($script:enrollmentSchema.required) | Should -Contain 'release_workflow'
        @($script:enrollmentSchema.required) | Should -Contain 'channels_supported'
        @($script:enrollmentSchema.required) | Should -Contain 'required_assets'
        @($script:enrollmentSchema.required) | Should -Contain 'required_attestations'
        @($script:enrollmentSchema.required) | Should -Contain 'dependency_graph'
        @($script:enrollmentSchema.required) | Should -Contain 'incident_targets'
        @($script:enrollmentSchema.required) | Should -Contain 'runtime_lineage_requirements'
    }

    It 'defines required program report and incident envelope keys' {
        @($script:programReportSchema.required) | Should -Contain 'phase_results'
        @($script:programReportSchema.required) | Should -Contain 'reason_code'
        @($script:incidentEnvelopeSchema.required) | Should -Contain 'issue_title'
        @($script:incidentEnvelopeSchema.required) | Should -Contain 'reason_code'
    }
}
