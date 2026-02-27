#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Release program workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/release-program.yml'
        $script:actionPath = Join-Path $script:repoRoot '.github/actions/run-control-plane/action.yml'
        $script:runtimePath = Join-Path $script:repoRoot 'scripts/Invoke-ReleaseProgram.ps1'

        foreach ($path in @($script:workflowPath, $script:actionPath, $script:runtimePath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Missing release program contract file: $path"
            }
        }

        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
        $script:actionContent = Get-Content -LiteralPath $script:actionPath -Raw
        $script:runtimeContent = Get-Content -LiteralPath $script:runtimePath -Raw
    }

    It 'is reusable and dispatchable with deterministic mode inputs' {
        $script:workflowContent | Should -Match 'workflow_dispatch:'
        $script:workflowContent | Should -Match 'workflow_call:'
        $script:workflowContent | Should -Match 'mode:'
        $script:workflowContent | Should -Match 'dry_run:'
        $script:workflowContent | Should -Match 'enrollment_path:'
        $script:workflowContent | Should -Match 'release-program-report'
    }

    It 'uses composite action runtime and uploads program report artifact' {
        $script:workflowContent | Should -Match 'uses:\s*\./\.github/actions/run-control-plane'
        $script:workflowContent | Should -Match 'actions/upload-artifact@v4'
        $script:actionContent | Should -Match 'Invoke-ReleaseProgram\.ps1'
        $script:actionContent | Should -Match 'program_report_path='
    }

    It 'imports shared reason-code taxonomy in runtime report output' {
        $script:runtimeContent | Should -Match 'reasonCodeTaxonomy'
        $script:runtimeContent | Should -Match 'release_dispatch_watch_timeout'
        $script:runtimeContent | Should -Match 'control_plane_watch_timeout'
        $script:runtimeContent | Should -Match 'host_validation_profile_missing'
        $script:runtimeContent | Should -Match 'host_validation_profile_invalid'
        $script:runtimeContent | Should -Match 'rollback_orchestration_failed'
        $script:runtimeContent | Should -Match 'Resolve-SurfaceHostValidationProfile'
        $script:runtimeContent | Should -Match 'host_validation_profile_preflight'
        $script:runtimeContent | Should -Match 'Resolve-ReasonCode'
        $script:runtimeContent | Should -Match 'Write-ProgramReport'
    }
}
