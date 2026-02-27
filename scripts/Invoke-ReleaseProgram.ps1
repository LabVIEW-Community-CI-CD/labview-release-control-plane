#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('Validate', 'CanaryCycle', 'PromotePrerelease', 'PromoteStable', 'FullCycle', 'Freeze', 'Unfreeze', 'Drill')]
    [string]$Mode = 'Validate',

    [Parameter()]
    [bool]$DryRun = $true,

    [Parameter()]
    [string]$PolicyPath = 'policies/platform-policy.json',

    [Parameter(Mandatory = $true)]
    [string]$EnrollmentPath,

    [Parameter()]
    [ValidateRange(5, 360)]
    [int]$WatchTimeoutMinutes = 180,

    [Parameter()]
    [ValidateRange(5, 60)]
    [int]$PollSeconds = 15,

    [Parameter()]
    [bool]$HostValidateInstaller = $false,

    [Parameter()]
    [string]$SurfaceRepoRoot = 'D:\dev\labview-cdev-surface',

    [Parameter()]
    [string]$HostWorkspaceRoot = 'C:\dev',

    [Parameter()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$reasonCodeTaxonomy = @(
    'ok',
    'program_validate_ok',
    'platform_policy_missing',
    'platform_policy_invalid',
    'enrollment_missing',
    'enrollment_invalid',
    'gh_cli_missing',
    'control_plane_dispatch_failed',
    'control_plane_run_not_found',
    'control_plane_watch_timeout',
    'control_plane_run_failed',
    'control_plane_report_missing',
    'dependency_gate_failed',
    'release_dispatch_watch_timeout',
    'release_verification_failed',
    'rollback_orchestration_failed',
    'stable_window_closed',
    'stable_override_invalid',
    'host_validation_skipped',
    'nsis_host_validation_failed',
    'program_runtime_error'
)

function Convert-BoolToLowerString {
    param([Parameter(Mandatory = $true)][bool]$Value)
    if ($Value) {
        return 'true'
    }
    return 'false'
}

function Write-ProgramReport {
    param(
        [Parameter(Mandatory = $true)][object]$Report,
        [Parameter()][string]$Path = ''
    )

    $json = $Report | ConvertTo-Json -Depth 30
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $resolved = [System.IO.Path]::GetFullPath($Path)
        $parent = Split-Path -Parent $resolved
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            New-Item -Path $parent -ItemType Directory -Force | Out-Null
        }
        Set-Content -LiteralPath $resolved -Value $json -Encoding utf8
        Write-Host "Program report written: $resolved"
    }

    Write-Output $json
}

function Add-PhaseResult {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Target,
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][ValidateSet('pass', 'fail', 'warn', 'skipped')]$Status,
        [Parameter(Mandatory = $true)][string]$ReasonCode,
        [Parameter()][string]$Message = ''
    )

    $Target.Add([ordered]@{
            phase = $Phase
            status = $Status
            reason_code = $ReasonCode
            message = $Message
        }) | Out-Null
}

function Invoke-GhText {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & gh @Arguments 2>&1
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    if ($exitCode -ne 0) {
        $joined = [string]::Join([Environment]::NewLine, @($output | ForEach-Object { [string]$_ }))
        throw "gh_command_failed: command=gh $($Arguments -join ' ') exit=$exitCode output=$joined"
    }

    return [string]::Join([Environment]::NewLine, @($output | ForEach-Object { [string]$_ }))
}

function Invoke-GhJson {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $text = Invoke-GhText -Arguments $Arguments
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    return ($text | ConvertFrom-Json -Depth 100 -ErrorAction Stop)
}

function Resolve-DispatchRun {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$Workflow,
        [Parameter(Mandatory = $true)][string]$Branch,
        [Parameter(Mandatory = $true)][DateTimeOffset]$NotBeforeUtc
    )

    $runs = @(
        Invoke-GhJson -Arguments @(
            'run',
            'list',
            '-R',
            $Repository,
            '--workflow',
            $Workflow,
            '--branch',
            $Branch,
            '--limit',
            '15',
            '--json',
            'databaseId,status,conclusion,url,createdAt,event,headSha'
        )
    )

    $eligible = @(
        $runs |
            Where-Object {
                $created = [DateTimeOffset]::MinValue
                if (-not [DateTimeOffset]::TryParse([string]$_.createdAt, [ref]$created)) {
                    return $false
                }
                $created.ToUniversalTime() -ge $NotBeforeUtc.ToUniversalTime().AddMinutes(-2) -and
                    [string]$_.event -eq 'workflow_dispatch'
            } |
            Sort-Object {
                $created = [DateTimeOffset]::MinValue
                [void][DateTimeOffset]::TryParse([string]$_.createdAt, [ref]$created)
                $created
            } -Descending
    )

    if (@($eligible).Count -lt 1) {
        return $null
    }

    return $eligible[0]
}

function Watch-RunToCompletion {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][int]$TimeoutMinutes,
        [Parameter(Mandatory = $true)][int]$PollSeconds
    )

    $deadline = (Get-Date).ToUniversalTime().AddMinutes($TimeoutMinutes)
    while ((Get-Date).ToUniversalTime() -lt $deadline) {
        $run = Invoke-GhJson -Arguments @(
            'run',
            'view',
            $RunId,
            '-R',
            $Repository,
            '--json',
            'databaseId,status,conclusion,url,createdAt,updatedAt,event,headSha'
        )

        if ([string]$run.status -eq 'completed') {
            return $run
        }

        Start-Sleep -Seconds $PollSeconds
    }

    return $null
}

function Find-FileRecursively {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$FileName
    )

    $match = Get-ChildItem -Path $Root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { [string]$_.Name -eq $FileName } |
        Select-Object -First 1
    return $match
}

function Resolve-ReleaseTagFromControlReport {
    param(
        [Parameter(Mandatory = $true)]$ControlReport,
        [Parameter(Mandatory = $true)][string]$Mode
    )

    $executions = @($ControlReport.executions)
    if (@($executions).Count -lt 1) {
        return ''
    }

    $targetMode = switch ($Mode) {
        'CanaryCycle' { 'CanaryCycle' }
        'PromotePrerelease' { 'PromotePrerelease' }
        'PromoteStable' { 'PromoteStable' }
        'FullCycle' { 'CanaryCycle' }
        default { $Mode }
    }

    $execution = @(
        $executions |
            Where-Object { [string]$_.mode -eq $targetMode } |
            Select-Object -First 1
    )
    if (@($execution).Count -ne 1) {
        return ''
    }

    return [string]$execution[0].target_release.tag
}

function Assert-ReleaseAssets {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string[]]$RequiredAssets
    )

    $release = Invoke-GhJson -Arguments @(
        'release',
        'view',
        $Tag,
        '-R',
        $Repository,
        '--json',
        'tagName,url,assets'
    )

    $assetNames = @($release.assets | ForEach-Object { [string]$_.name })
    $missing = @()
    foreach ($required in @($RequiredAssets)) {
        $name = ([string]$required).Trim()
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }
        if (@($assetNames | Where-Object { [string]$_ -eq $name }).Count -eq 0) {
            $missing += $name
        }
    }

    if (@($missing).Count -gt 0) {
        throw "release_verification_failed: missing_assets=$([string]::Join(',', $missing))"
    }

    return [ordered]@{
        tag = [string]$release.tagName
        url = [string]$release.url
        assets_checked = @($RequiredAssets)
    }
}

function Invoke-HostNsisValidation {
    param(
        [Parameter(Mandatory = $true)][string]$SurfaceRepoRoot,
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$ReleaseTag,
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$ScratchRoot
    )

    $installerScriptPath = Join-Path $SurfaceRepoRoot 'scripts/Install-WorkspaceInstallerFromRelease.ps1'
    $manifestPath = Join-Path $SurfaceRepoRoot 'workspace-governance.json'
    if (-not (Test-Path -LiteralPath $installerScriptPath -PathType Leaf)) {
        throw "nsis_host_validation_failed: script_missing=$installerScriptPath"
    }
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "nsis_host_validation_failed: manifest_missing=$manifestPath"
    }

    $hostReportPath = Join-Path $ScratchRoot 'nsis-host-validation-report.json'
    $hostCommandOutput = & pwsh -NoProfile -File $installerScriptPath `
        -WorkspaceRoot $WorkspaceRoot `
        -ManifestPath $manifestPath `
        -Mode Install `
        -Channel canary `
        -Tag $ReleaseTag `
        -Repository $Repository `
        -OutputPath $hostReportPath 2>&1
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    if ($exitCode -ne 0) {
        $message = if (Test-Path -LiteralPath $hostReportPath -PathType Leaf) {
            [string](Get-Content -LiteralPath $hostReportPath -Raw)
        } elseif (@($hostCommandOutput).Count -gt 0) {
            [string]::Join([Environment]::NewLine, @($hostCommandOutput | ForEach-Object { [string]$_ }))
        } else {
            "host_report_missing=$hostReportPath"
        }
        throw "nsis_host_validation_failed: exit_code=$exitCode $message"
    }

    $hostReport = Get-Content -LiteralPath $hostReportPath -Raw | ConvertFrom-Json -Depth 100
    if ([string]$hostReport.status -ne 'pass') {
        throw "nsis_host_validation_failed: status=$([string]$hostReport.status) reason_code=$([string]$hostReport.reason_code)"
    }

    return [ordered]@{
        status = [string]$hostReport.status
        reason_code = [string]$hostReport.reason_code
        report_path = [System.IO.Path]::GetFullPath($hostReportPath)
        install_report_path = [string]$hostReport.install_report_path
        release_tag = [string]$hostReport.release_tag
        repository = [string]$hostReport.repository
    }
}

$phaseResults = [System.Collections.Generic.List[object]]::new()
$scratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("release-program-" + [Guid]::NewGuid().ToString('N'))
New-Item -Path $scratchRoot -ItemType Directory -Force | Out-Null

$report = [ordered]@{
    schema_version = '1.0'
    generated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    status = 'fail'
    reason_code = ''
    mode = $Mode
    dry_run = [bool]$DryRun
    phase_results = @()
    enrollment = [ordered]@{}
    policy_summary = [ordered]@{}
    reason_code_taxonomy = @($reasonCodeTaxonomy)
    details = [ordered]@{
        dispatch = [ordered]@{}
        control_plane_run = [ordered]@{}
        control_plane_report = [ordered]@{}
        release_verification = [ordered]@{}
        host_validation = [ordered]@{}
    }
}

try {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw 'gh_cli_missing'
    }
    Add-PhaseResult -Target $phaseResults -Phase 'preflight' -Status 'pass' -ReasonCode 'ok'

    if (-not (Test-Path -LiteralPath $PolicyPath -PathType Leaf)) {
        throw 'platform_policy_missing'
    }
    if (-not (Test-Path -LiteralPath $EnrollmentPath -PathType Leaf)) {
        throw 'enrollment_missing'
    }

    $policy = Get-Content -LiteralPath $PolicyPath -Raw | ConvertFrom-Json -Depth 100
    $enrollment = Get-Content -LiteralPath $EnrollmentPath -Raw | ConvertFrom-Json -Depth 100

    if ([string]::IsNullOrWhiteSpace([string]$policy.platform_policy.schema_version)) {
        throw 'platform_policy_invalid'
    }
    foreach ($field in @('repo_id', 'release_workflow', 'channels_supported', 'required_assets')) {
        if ($null -eq $enrollment.PSObject.Properties[$field] -or [string]::IsNullOrWhiteSpace([string]$enrollment.$field)) {
            throw "enrollment_invalid"
        }
    }

    $targetRepository = [string]$enrollment.repo_id
    $targetWorkflow = [string]$enrollment.release_workflow
    $targetBranch = if ($null -ne $enrollment.PSObject.Properties['release_branch'] -and -not [string]::IsNullOrWhiteSpace([string]$enrollment.release_branch)) {
        [string]$enrollment.release_branch
    } else {
        'main'
    }

    $report.enrollment = [ordered]@{
        repo_id = $targetRepository
        release_workflow = $targetWorkflow
    }
    $report.policy_summary = [ordered]@{
        schema_version = [string]$policy.platform_policy.schema_version
        autonomy = [string]$policy.platform_policy.autonomy
    }

    $dispatchStartUtc = [DateTimeOffset]::UtcNow
    $dispatchArgs = @(
        'workflow',
        'run',
        $targetWorkflow,
        '-R',
        $targetRepository,
        '--ref',
        $targetBranch,
        '-f',
        "mode=$Mode",
        '-f',
        "dry_run=$(Convert-BoolToLowerString -Value $DryRun)"
    )
    Invoke-GhText -Arguments $dispatchArgs | Out-Null

    $report.details.dispatch = [ordered]@{
        repository = $targetRepository
        workflow = $targetWorkflow
        branch = $targetBranch
        mode = $Mode
        dry_run = [bool]$DryRun
        started_at_utc = $dispatchStartUtc.ToString('o')
    }
    Add-PhaseResult -Target $phaseResults -Phase 'control_plane_dispatch' -Status 'pass' -ReasonCode 'ok'

    Start-Sleep -Seconds 6
    $run = Resolve-DispatchRun -Repository $targetRepository -Workflow $targetWorkflow -Branch $targetBranch -NotBeforeUtc $dispatchStartUtc
    if ($null -eq $run) {
        throw 'control_plane_run_not_found'
    }

    $runId = [string]$run.databaseId
    $report.details.control_plane_run = [ordered]@{
        run_id = $runId
        status = [string]$run.status
        conclusion = [string]$run.conclusion
        created_at_utc = [string]$run.createdAt
        url = [string]$run.url
    }

    $completedRun = Watch-RunToCompletion -Repository $targetRepository -RunId $runId -TimeoutMinutes $WatchTimeoutMinutes -PollSeconds $PollSeconds
    if ($null -eq $completedRun) {
        throw 'control_plane_watch_timeout'
    }

    $report.details.control_plane_run.status = [string]$completedRun.status
    $report.details.control_plane_run.conclusion = [string]$completedRun.conclusion
    $report.details.control_plane_run.updated_at_utc = [string]$completedRun.updatedAt
    $report.details.control_plane_run.url = [string]$completedRun.url

    $downloadRoot = Join-Path $scratchRoot ("run-" + $runId)
    New-Item -Path $downloadRoot -ItemType Directory -Force | Out-Null
    Invoke-GhText -Arguments @('run', 'download', $runId, '-R', $targetRepository, '--dir', $downloadRoot) | Out-Null

    $controlReportFile = Find-FileRecursively -Root $downloadRoot -FileName 'release-control-plane-report.json'
    if ($null -eq $controlReportFile) {
        throw 'control_plane_report_missing'
    }
    $controlReport = Get-Content -LiteralPath $controlReportFile.FullName -Raw | ConvertFrom-Json -Depth 100
    $report.details.control_plane_report = [ordered]@{
        path = [System.IO.Path]::GetFullPath($controlReportFile.FullName)
        status = [string]$controlReport.status
        reason_code = [string]$controlReport.reason_code
        message = [string]$controlReport.message
        mode = [string]$controlReport.mode
    }

    if ([string]$completedRun.conclusion -ne 'success' -or [string]$controlReport.status -ne 'pass') {
        $reason = [string]$controlReport.reason_code
        if ([string]::IsNullOrWhiteSpace($reason)) {
            $reason = 'control_plane_run_failed'
        }
        throw $reason
    }
    Add-PhaseResult -Target $phaseResults -Phase 'control_plane_watch' -Status 'pass' -ReasonCode 'ok'

    $promotionMode = @('CanaryCycle', 'PromotePrerelease', 'PromoteStable', 'FullCycle') -contains $Mode
    if ($promotionMode -and -not $DryRun) {
        $releaseTag = Resolve-ReleaseTagFromControlReport -ControlReport $controlReport -Mode $Mode
        if ([string]::IsNullOrWhiteSpace($releaseTag)) {
            throw 'release_verification_failed'
        }

        $verification = Assert-ReleaseAssets -Repository $targetRepository -Tag $releaseTag -RequiredAssets @($enrollment.required_assets)
        $report.details.release_verification = $verification
        Add-PhaseResult -Target $phaseResults -Phase 'release_verify' -Status 'pass' -ReasonCode 'ok' -Message ("tag={0}" -f $releaseTag)

        if ($HostValidateInstaller) {
            $hostValidation = Invoke-HostNsisValidation `
                -SurfaceRepoRoot $SurfaceRepoRoot `
                -Repository $targetRepository `
                -ReleaseTag $releaseTag `
                -WorkspaceRoot $HostWorkspaceRoot `
                -ScratchRoot $scratchRoot
            $report.details.host_validation = $hostValidation
            Add-PhaseResult -Target $phaseResults -Phase 'host_nsis_validation' -Status 'pass' -ReasonCode 'ok' -Message ("tag={0}" -f $releaseTag)
        } else {
            Add-PhaseResult -Target $phaseResults -Phase 'host_nsis_validation' -Status 'skipped' -ReasonCode 'host_validation_skipped'
        }
    } else {
        Add-PhaseResult -Target $phaseResults -Phase 'release_verify' -Status 'skipped' -ReasonCode 'program_validate_ok'
        Add-PhaseResult -Target $phaseResults -Phase 'host_nsis_validation' -Status 'skipped' -ReasonCode 'host_validation_skipped'
    }

    $report.status = if ($Mode -eq 'Validate') { 'warn' } else { 'pass' }
    $report.reason_code = if ($Mode -eq 'Validate') { 'program_validate_ok' } else { 'ok' }
}
catch {
    $failureReason = [string]$_.Exception.Message
    $report.status = 'fail'
    $report.reason_code = if ([string]::IsNullOrWhiteSpace($failureReason)) { 'program_runtime_error' } else { $failureReason }
    Add-PhaseResult -Target $phaseResults -Phase 'failure' -Status 'fail' -ReasonCode $report.reason_code -Message $failureReason
}
finally {
    $report.phase_results = @($phaseResults)
    Write-ProgramReport -Report $report -Path $OutputPath | Out-Null
    if (Test-Path -LiteralPath $scratchRoot -PathType Container) {
        Remove-Item -LiteralPath $scratchRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ([string]$report.status -eq 'fail') {
    exit 1
}

exit 0
