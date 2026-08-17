[CmdletBinding()]
param(
    [ValidateSet("Policy", "Build", "Quick", "Final")]
    [string] $Mode = "Policy",

    [string] $RepositoryPath = (Split-Path -Parent $PSScriptRoot),
    [string] $BaselineRef = "yolo-mainline",
    [ValidateSet("Hip", "Vulkan")]
    [string] $Backend = "Hip",
    [string] $BuildDirectory,
    [int] $Parallel = 32,
    [switch] $Configure,
    [switch] $RunPythonServerTests,
    [switch] $RunUiTests,
    [switch] $AllowScopeExpansion,

    [string] $ServerExecutable,
    [string] $ControlServer,
    [string] $Model,
    [ValidateSet("none", "ngram-mod", "mtp", "mtp+ngram-mod")]
    [string] $Spec = "mtp+ngram-mod",
    [string] $SpecActiveLimit = "draft-mtp=1,ngram-mod=2",
    [int] $ActiveRequests = 4,
    [ValidateSet("partitioned", "unified")]
    [string] $Kv = "partitioned",
    [ValidateSet("disjoint", "shared")]
    [string] $Workload = "disjoint",
    [string] $Purpose = "Evaluate an upstream intake candidate",
    [switch] $RunPerformance,
    [switch] $NoWrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$policyPath = Join-Path $PSScriptRoot "policy.json"
$reportsPath = Join-Path $PSScriptRoot "reports"
$policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json -Depth 30

function Invoke-Native {
    param(
        [Parameter(Mandatory)] [string] $Program,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [string] $WorkingDirectory = $repoRoot
    )
    Push-Location $WorkingDirectory
    try {
        & $Program @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "$Program $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
        }
    } finally {
        Pop-Location
    }
}

function Get-GitLines {
    param([Parameter(Mandatory)] [string[]] $Arguments)
    $lines = @(& git -C $repoRoot @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed:`n$($lines -join "`n")"
    }
    $lines
}

function Test-Prefix {
    param([string] $Path, [string] $Prefix)
    $Path.StartsWith($Prefix, [System.StringComparison]::Ordinal)
}

function Test-ForbiddenPath {
    param([string] $Path)
    foreach ($exception in $policy.forbidden_prefix_exceptions) {
        if ($Path -eq $exception -or (Test-Prefix -Path $Path -Prefix $exception)) {
            return $false
        }
    }
    foreach ($prefix in $policy.forbidden_prefixes) {
        if (Test-Prefix -Path $Path -Prefix $prefix) {
            return $true
        }
    }
    foreach ($property in $policy.restricted_addition_roots.psobject.Properties) {
        if (-not (Test-Prefix -Path $Path -Prefix $property.Name)) {
            continue
        }
        $relative = $Path.Substring($property.Name.Length)
        foreach ($allowed in $property.Value) {
            if ($relative -eq $allowed -or (Test-Prefix -Path $relative -Prefix $allowed)) {
                return $false
            }
        }
        return $true
    }
    return $false
}

function Get-AddedPaths {
    $rows = [System.Collections.Generic.List[string]]::new()
    $committed = @(Get-GitLines -Arguments @("diff", "--name-status", "$BaselineRef...HEAD"))
    $staged = @(Get-GitLines -Arguments @("diff", "--cached", "--name-status"))
    foreach ($row in @($committed + $staged)) {
        if ([string]::IsNullOrWhiteSpace($row)) {
            continue
        }
        $parts = $row -split "`t"
        if ($parts[0] -eq "A" -and $parts.Count -ge 2) {
            $rows.Add($parts[1])
        } elseif (($parts[0].StartsWith("R") -or $parts[0].StartsWith("C")) -and $parts.Count -ge 3) {
            $rows.Add($parts[2])
        }
    }
    @($rows | Sort-Object -Unique)
}

function Get-CandidateChangedPaths {
    $paths = [System.Collections.Generic.List[string]]::new()
    $committed = @(Get-GitLines -Arguments @("diff", "--name-only", "$BaselineRef...HEAD"))
    $staged = @(Get-GitLines -Arguments @("diff", "--cached", "--name-only"))
    foreach ($path in @($committed + $staged)) {
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $paths.Add($path)
        }
    }
    @($paths | Sort-Object -Unique)
}

function Get-AffectedSubsystems {
    param([string[]] $Paths = @())
    $subsystems = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($path in $Paths) {
        foreach ($property in $policy.subsystems.psobject.Properties) {
            foreach ($prefix in $property.Value) {
                if ($path -eq $prefix -or (Test-Prefix -Path $path -Prefix $prefix)) {
                    [void] $subsystems.Add($property.Name)
                }
            }
        }
    }
    if ($subsystems.Count -eq 0) {
        [void] $subsystems.Add("other")
    }
    @($subsystems | Sort-Object)
}

$repoRoot = [System.IO.Path]::GetFullPath($RepositoryPath)
$repoRoot = @(Get-GitLines -Arguments @("rev-parse", "--show-toplevel"))[0]
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$policyFailures = [System.Collections.Generic.List[string]]::new()
$scopeAdditions = [System.Collections.Generic.List[string]]::new()
$changedPaths = @(Get-CandidateChangedPaths)
$affectedSubsystems = @(Get-AffectedSubsystems -Paths $changedPaths)
$requiredGates = [System.Collections.Generic.List[string]]::new()
$requiredGates.Add("cull-policy")
$requiredGates.Add("diff-check")
if ($affectedSubsystems -contains "hip") { $requiredGates.Add("hip-build-and-ctest") }
if ($affectedSubsystems -contains "vulkan") { $requiredGates.Add("vulkan-build-and-ctest") }
if ($affectedSubsystems -contains "server_spec") { $requiredGates.Add("server-python-and-inference") }
if ($affectedSubsystems -contains "ui") { $requiredGates.Add("ui-check-unit-build") }
if ($affectedSubsystems -contains "models_conversion") { $requiredGates.Add("retained-model-load-smoke") }

foreach ($path in @(Get-AddedPaths)) {
    if (Test-ForbiddenPath -Path $path) {
        $policyFailures.Add($path)
    } else {
        $scopeAdditions.Add($path)
    }
}

Invoke-Native -Program "git" -Arguments @("-C", $repoRoot, "diff", "--check", "$BaselineRef...HEAD")
Invoke-Native -Program "git" -Arguments @("-C", $repoRoot, "diff", "--cached", "--check")

$policyReport = [ordered]@{
    generated_at = [DateTimeOffset]::Now.ToString("o")
    repository = $repoRoot
    baseline_ref = $BaselineRef
    forbidden_additions = @($policyFailures)
    scope_additions = @($scopeAdditions)
    scope_expansion_allowed = [bool] $AllowScopeExpansion
    affected_subsystems = $affectedSubsystems
    required_gates = @($requiredGates)
}
$policyReportPath = Join-Path $reportsPath "policy-$timestamp.json"
if (-not $NoWrite) {
    $policyJson = $policyReport | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($policyReportPath, "$policyJson`n", [System.Text.UTF8Encoding]::new($false))
}

if ($policyFailures.Count -gt 0) {
    Write-Error "Cull-policy failure: forbidden paths were added:`n$($policyFailures -join "`n")"
    exit 3
}
if ($scopeAdditions.Count -gt 0 -and -not $AllowScopeExpansion) {
    Write-Error "New retained scope requires review. Re-run with -AllowScopeExpansion after approval:`n$($scopeAdditions -join "`n")"
    exit 4
}
if ($NoWrite) {
    Write-Host "Policy gate passed. Report writing disabled."
} else {
    Write-Host "Policy gate passed. Report: $policyReportPath"
}
Write-Host "Affected subsystems: $($affectedSubsystems -join ', ')"
Write-Host "Required gates: $($requiredGates -join ', ')"

if ($Mode -eq "Policy") {
    exit 0
}

if ([string]::IsNullOrWhiteSpace($BuildDirectory)) {
    $relativeBuild = if ($Backend -eq "Hip") {
        $policy.validation.hip_build_directory
    } else {
        $policy.validation.vulkan_build_directory
    }
    $BuildDirectory = Join-Path $repoRoot $relativeBuild
} else {
    $BuildDirectory = [System.IO.Path]::GetFullPath($BuildDirectory)
}

if ($Configure) {
    $configureArgs = [System.Collections.Generic.List[string]]::new()
    foreach ($arg in @(
        "-S", $repoRoot,
        "-B", $BuildDirectory,
        "-G", "Ninja",
        "-DCMAKE_BUILD_TYPE=Release",
        "-DBUILD_SHARED_LIBS=ON",
        "-DLLAMA_BUILD_TESTS=ON",
        "-DLLAMA_BUILD_SERVER=ON",
        "-DGGML_RPC=OFF"
    )) {
        $configureArgs.Add($arg)
    }
    if ($Backend -eq "Hip") {
        foreach ($arg in @(
            "-DGGML_HIP=ON",
            "-DGGML_VULKAN=OFF",
            "-DAMDGPU_TARGETS=$($policy.validation.amdgpu_targets)",
            "-DGPU_BUILD_TARGETS=$($policy.validation.amdgpu_targets)",
            "-DGGML_HIP_MMQ_MFMA=ON",
            "-DGGML_HIP_GRAPHS=OFF",
            "-DGGML_CUDA_NO_PEER_COPY=ON",
            "-DGGML_HIP_NO_VMM=ON",
            "-DGGML_HIP_UNSAFE_MATH=OFF",
            "-DGGML_HIP_EXPORT_METRICS=OFF"
        )) {
            $configureArgs.Add($arg)
        }
    } else {
        $configureArgs.Add("-DGGML_HIP=OFF")
        $configureArgs.Add("-DGGML_VULKAN=ON")
    }
    Invoke-Native -Program "cmake" -Arguments @($configureArgs)
} elseif (-not (Test-Path -LiteralPath $BuildDirectory)) {
    throw "Build directory does not exist. Supply -Configure or an existing -BuildDirectory."
}

Invoke-Native -Program "cmake" -Arguments @(
    "--build", $BuildDirectory, "--config", "Release", "--parallel", $Parallel
)
Invoke-Native -Program "ctest" -Arguments @(
    "--test-dir", $BuildDirectory, "-C", "Release", "-L", "main", "--output-on-failure"
)

if ($RunPythonServerTests) {
    Invoke-Native -Program "python" -Arguments @("-m", "pytest", "tests/python/server")
} elseif ($affectedSubsystems -contains "server_spec") {
    Write-Warning "Server/speculative paths changed; run again with -RunPythonServerTests before promotion."
}

if ($RunUiTests) {
    $uiDirectory = Join-Path $repoRoot "tools/ui"
    if (-not (Test-Path -LiteralPath (Join-Path $uiDirectory "node_modules"))) {
        throw "UI dependencies are absent. Run npm install in tools/ui before -RunUiTests."
    }
    Invoke-Native -Program "npm.cmd" -Arguments @("run", "check") -WorkingDirectory $uiDirectory
    Invoke-Native -Program "npm.cmd" -Arguments @("run", "test:unit", "--", "--run") -WorkingDirectory $uiDirectory
    Invoke-Native -Program "npm.cmd" -Arguments @("run", "build") -WorkingDirectory $uiDirectory
} elseif ($affectedSubsystems -contains "ui") {
    Write-Warning "UI paths changed; run again with -RunUiTests before promotion."
}

if ($affectedSubsystems -contains "vulkan" -and $Backend -ne "Vulkan") {
    Write-Warning "Vulkan paths changed; a separate -Backend Vulkan build is required before promotion."
}
if ($affectedSubsystems -contains "hip" -and $Backend -ne "Hip") {
    Write-Warning "HIP paths changed; a separate -Backend Hip build is required before promotion."
}

if ($Mode -eq "Build") {
    exit 0
}

if ([string]::IsNullOrWhiteSpace($ServerExecutable)) {
    $candidate = Join-Path $BuildDirectory "bin/llama-server.exe"
    if (Test-Path -LiteralPath $candidate) {
        $ServerExecutable = $candidate
    } else {
        throw "-ServerExecutable is required for $Mode performance validation."
    }
}
if ([string]::IsNullOrWhiteSpace($Model)) {
    $Model = $policy.validation.server_model
}

$runner = Join-Path $repoRoot "skills/llamacpp-server-test/scripts/standard_server_test.py"
$runnerMode = $Mode.ToLowerInvariant()
$runnerOutput = Join-Path $reportsPath "performance-$runnerMode-$timestamp"
$runnerAction = if ($RunPerformance) { "run" } else { "plan" }
$runnerArgs = [System.Collections.Generic.List[string]]::new()
foreach ($arg in @(
    $runner,
    "--action", $runnerAction,
    "--mode", $runnerMode,
    "--purpose", $Purpose,
    "--server", $ServerExecutable,
    "--model", $Model,
    "--spec", $Spec,
    "--active-requests", $ActiveRequests,
    "--server-parallel", $policy.validation.server_parallel,
    "--ctx-size", $policy.validation.ctx_size,
    "--prompt-tokens", $policy.validation.prompt_tokens,
    "--predict-tokens", $policy.validation.predict_tokens,
    "--batch-size", $policy.validation.batch_size,
    "--ubatch-size", $policy.validation.ubatch_size,
    "--kv", $Kv,
    "--workload", $Workload,
    "--output", $runnerOutput
)) {
    $runnerArgs.Add([string] $arg)
}
if ($Spec -ne "none" -and -not [string]::IsNullOrWhiteSpace($SpecActiveLimit)) {
    $runnerArgs.Add("--spec-active-limit")
    $runnerArgs.Add($SpecActiveLimit)
}
if (-not [string]::IsNullOrWhiteSpace($ControlServer)) {
    $runnerArgs.Add("--control-server")
    $runnerArgs.Add($ControlServer)
}

if (-not $RunPerformance) {
    Write-Host "Performance execution was not requested; generating the required visible plan only."
}
Invoke-Native -Program "python" -Arguments @($runnerArgs)
