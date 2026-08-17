[CmdletBinding()]
param(
    [ValidateSet("Plan", "Start", "Attempt", "Record")]
    [string] $Action = "Plan",

    [string] $RepositoryPath = (Split-Path -Parent $PSScriptRoot),
    [string] $Commit,
    [string] $WorktreePath,
    [string] $BranchName,

    [ValidateSet("Accepted", "Partial", "Skipped", "Rejected")]
    [string] $Decision,
    [string] $AppliedCommit,
    [string] $EvaluationReport,
    [string] $Notes,

    [switch] $Fetch,
    [switch] $ForceReview,
    [switch] $NoWrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$policyPath = Join-Path $PSScriptRoot "policy.json"
$statePath = Join-Path $PSScriptRoot "state.json"
$reportsPath = Join-Path $PSScriptRoot "reports"
$decisionsPath = Join-Path $PSScriptRoot "decisions"

function Invoke-Git {
    param(
        [Parameter(Mandatory)] [string] $WorkingDirectory,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [switch] $AllowFailure
    )

    $output = @(& git -C $WorkingDirectory @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "git $($Arguments -join ' ') failed ($exitCode):`n$($output -join "`n")"
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Output = $output
    }
}

function Read-JsonFile {
    param([Parameter(Mandatory)] [string] $Path)
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 30
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] $Value
    )
    $json = $Value | ConvertTo-Json -Depth 30
    [System.IO.File]::WriteAllText($Path, "$json`n", [System.Text.UTF8Encoding]::new($false))
}

function Resolve-RepositoryRoot {
    param([Parameter(Mandatory)] [string] $Path)
    $resolved = [System.IO.Path]::GetFullPath($Path)
    (Invoke-Git -WorkingDirectory $resolved -Arguments @("rev-parse", "--show-toplevel")).Output[0]
}

function Test-Prefix {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Prefix
    )
    $Path.StartsWith($Prefix, [System.StringComparison]::Ordinal)
}

function Test-ForbiddenPath {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] $Policy
    )

    foreach ($exception in $Policy.forbidden_prefix_exceptions) {
        if ($Path -eq $exception -or (Test-Prefix -Path $Path -Prefix $exception)) {
            return $false
        }
    }
    foreach ($prefix in $Policy.forbidden_prefixes) {
        if (Test-Prefix -Path $Path -Prefix $prefix) {
            return $true
        }
    }
    foreach ($property in $Policy.restricted_addition_roots.psobject.Properties) {
        $root = $property.Name
        if (-not (Test-Prefix -Path $Path -Prefix $root)) {
            continue
        }
        $relative = $Path.Substring($root.Length)
        foreach ($allowed in $property.Value) {
            if ($relative -eq $allowed -or (Test-Prefix -Path $relative -Prefix $allowed)) {
                return $false
            }
        }
        return $true
    }
    return $false
}

function Test-LowSignalPath {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] $Policy
    )
    foreach ($prefix in $Policy.low_signal_prefixes) {
        if ($Path -eq $prefix -or (Test-Prefix -Path $Path -Prefix $prefix)) {
            return $true
        }
    }
    return $false
}

function Get-ChangedPaths {
    param(
        [Parameter(Mandatory)] [string] $Repo,
        [Parameter(Mandatory)] [string] $Sha
    )

    $rows = (Invoke-Git -WorkingDirectory $Repo -Arguments @(
        "diff-tree", "--no-commit-id", "--name-status", "-r", "-M", $Sha
    )).Output
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $rows) {
        if ([string]::IsNullOrWhiteSpace($row)) {
            continue
        }
        $parts = $row -split "`t"
        $status = $parts[0]
        if (($status.StartsWith("R") -or $status.StartsWith("C")) -and $parts.Count -ge 3) {
            $items.Add([pscustomobject]@{ Status = $status; Path = $parts[1]; Role = "source" })
            $items.Add([pscustomobject]@{ Status = $status; Path = $parts[2]; Role = "destination" })
        } elseif ($parts.Count -ge 2) {
            $items.Add([pscustomobject]@{ Status = $status; Path = $parts[1]; Role = "path" })
        }
    }
    @($items)
}

function Get-Subsystems {
    param(
        [Parameter(Mandatory)] [object[]] $Paths,
        [Parameter(Mandatory)] $Policy
    )

    $result = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($path in $Paths.Path) {
        foreach ($property in $Policy.subsystems.psobject.Properties) {
            foreach ($prefix in $property.Value) {
                if ($path -eq $prefix -or (Test-Prefix -Path $path -Prefix $prefix)) {
                    [void] $result.Add($property.Name)
                }
            }
        }
    }
    if ($result.Count -eq 0) {
        [void] $result.Add("other")
    }
    @($result | Sort-Object)
}

function Get-CommitAssessment {
    param(
        [Parameter(Mandatory)] [string] $Repo,
        [Parameter(Mandatory)] [string] $Sha,
        [Parameter(Mandatory)] [System.Collections.Generic.HashSet[string]] $TargetPaths,
        [Parameter(Mandatory)] $Policy
    )

    $changes = @(Get-ChangedPaths -Repo $Repo -Sha $Sha)
    $retained = [System.Collections.Generic.List[object]]::new()
    $culled = [System.Collections.Generic.List[object]]::new()
    $newScope = [System.Collections.Generic.List[object]]::new()

    foreach ($change in $changes) {
        if ($TargetPaths.Contains($change.Path)) {
            $retained.Add($change)
        } elseif ($change.Status -eq "D" -or (Test-ForbiddenPath -Path $change.Path -Policy $Policy)) {
            $culled.Add($change)
        } else {
            $newScope.Add($change)
        }
    }

    if ($retained.Count -eq 0 -and $newScope.Count -eq 0) {
        $classification = "skip"
    } elseif ($culled.Count -gt 0 -and ($retained.Count -gt 0 -or $newScope.Count -gt 0)) {
        $classification = "review_partial"
    } elseif ($newScope.Count -gt 0) {
        $classification = "scope_change"
    } else {
        $classification = "try_full"
    }

    $lowSignalOnly = $retained.Count -gt 0
    foreach ($change in $retained) {
        if (-not (Test-LowSignalPath -Path $change.Path -Policy $Policy)) {
            $lowSignalOnly = $false
            break
        }
    }

    $subject = (Invoke-Git -WorkingDirectory $Repo -Arguments @("show", "-s", "--format=%s", $Sha)).Output[0]
    $fullSha = (Invoke-Git -WorkingDirectory $Repo -Arguments @("rev-parse", "$Sha^{commit}")).Output[0]
    [pscustomobject]@{
        commit = $fullSha
        short_commit = $fullSha.Substring(0, 9)
        subject = $subject
        classification = $classification
        low_signal_only = $lowSignalOnly
        subsystems = @(Get-Subsystems -Paths $changes -Policy $Policy)
        changed_count = $changes.Count
        retained_paths = @($retained | Select-Object -ExpandProperty Path -Unique)
        culled_paths = @($culled | Select-Object -ExpandProperty Path -Unique)
        new_scope_paths = @($newScope | Select-Object -ExpandProperty Path -Unique)
    }
}

function Get-Queue {
    param(
        [Parameter(Mandatory)] [string] $Repo,
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] $Policy
    )

    $targetLines = (Invoke-Git -WorkingDirectory $Repo -Arguments @(
        "ls-tree", "-r", "--name-only", $State.target_ref
    )).Output
    $targetPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($path in $targetLines) {
        [void] $targetPaths.Add($path)
    }

    $range = "$($State.last_evaluated_upstream)..$($State.upstream_ref)"
    $commits = (Invoke-Git -WorkingDirectory $Repo -Arguments @("rev-list", "--reverse", "--no-merges", $range)).Output
    $queue = [System.Collections.Generic.List[object]]::new()
    foreach ($sha in $commits) {
        $queue.Add((Get-CommitAssessment -Repo $Repo -Sha $sha -TargetPaths $targetPaths -Policy $Policy))
    }
    @($queue)
}

$repoRoot = Resolve-RepositoryRoot -Path $RepositoryPath
$policy = Read-JsonFile -Path $policyPath
$state = Read-JsonFile -Path $statePath

if ($Fetch) {
    Invoke-Git -WorkingDirectory $repoRoot -Arguments @("fetch", "upstream", "master") | Out-Null
}

switch ($Action) {
    "Plan" {
        $upstreamTip = (Invoke-Git -WorkingDirectory $repoRoot -Arguments @("rev-parse", $state.upstream_ref)).Output[0]
        $queue = @(Get-Queue -Repo $repoRoot -State $state -Policy $policy)
        $counts = [ordered]@{}
        foreach ($group in ($queue | Group-Object classification)) {
            $counts[$group.Name] = $group.Count
        }
        $plan = [ordered]@{
            generated_at = [DateTimeOffset]::Now.ToString("o")
            repository = $repoRoot
            target_ref = $state.target_ref
            upstream_ref = $state.upstream_ref
            from = $state.last_evaluated_upstream
            to = $upstreamTip
            counts = $counts
            commits = $queue
        }
        if (-not $NoWrite) {
            $name = "plan-$($state.last_evaluated_upstream.Substring(0, 9))-$($upstreamTip.Substring(0, 9)).json"
            $outputPath = Join-Path $reportsPath $name
            Write-JsonFile -Path $outputPath -Value $plan
            Write-Host "Plan report: $outputPath"
        }
        $queue | Select-Object short_commit, classification, @{n="subsystems";e={$_.subsystems -join ","}}, subject | Format-Table -AutoSize
        $countSummary = ($counts.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ", "
        Write-Host "Total: $($queue.Count); $countSummary"
    }

    "Start" {
        $upstreamTip = (Invoke-Git -WorkingDirectory $repoRoot -Arguments @("rev-parse", $state.upstream_ref)).Output[0]
        if ([string]::IsNullOrWhiteSpace($BranchName)) {
            $BranchName = "intake/$($upstreamTip.Substring(0, 9))"
        }
        if ([string]::IsNullOrWhiteSpace($WorktreePath)) {
            $parent = Split-Path -Parent $repoRoot
            $WorktreePath = Join-Path $parent "upstream-intake-$($upstreamTip.Substring(0, 9))"
        }
        $WorktreePath = [System.IO.Path]::GetFullPath($WorktreePath)
        if (Test-Path -LiteralPath $WorktreePath) {
            throw "Worktree path already exists: $WorktreePath"
        }
        $branchCheck = Invoke-Git -WorkingDirectory $repoRoot -Arguments @("show-ref", "--verify", "--quiet", "refs/heads/$BranchName") -AllowFailure
        if ($branchCheck.ExitCode -eq 0) {
            throw "Branch already exists: $BranchName"
        }
        Invoke-Git -WorkingDirectory $repoRoot -Arguments @(
            "worktree", "add", "-b", $BranchName, $WorktreePath, $state.target_ref
        ) | Out-Null
        Write-Host "Created $BranchName at $WorktreePath"
        Write-Host "Next: $PSCommandPath -Action Attempt -Commit <sha> -WorktreePath `"$WorktreePath`""
    }

    "Attempt" {
        if ([string]::IsNullOrWhiteSpace($Commit)) {
            throw "-Commit is required for Attempt."
        }
        if ([string]::IsNullOrWhiteSpace($WorktreePath)) {
            throw "-WorktreePath is required for Attempt."
        }
        $candidateRoot = Resolve-RepositoryRoot -Path $WorktreePath
        $dirty = (Invoke-Git -WorkingDirectory $candidateRoot -Arguments @("status", "--porcelain")).Output
        if ($dirty.Count -gt 0) {
            throw "Candidate worktree is not clean. Commit or abandon the previous attempt first.`n$($dirty -join "`n")"
        }
        $queue = @(Get-Queue -Repo $repoRoot -State $state -Policy $policy)
        $fullCommit = (Invoke-Git -WorkingDirectory $repoRoot -Arguments @("rev-parse", "$Commit^{commit}")).Output[0]
        $assessment = $queue | Where-Object { $_.commit -eq $fullCommit } | Select-Object -First 1
        if ($null -eq $assessment) {
            throw "$Commit is not in the current intake queue."
        }
        if ($assessment.classification -eq "skip") {
            throw "$($assessment.short_commit) is classified skip; record it instead of applying it."
        }
        if (($assessment.classification -eq "review_partial" -or $assessment.classification -eq "scope_change" -or $assessment.low_signal_only) -and -not $ForceReview) {
            $reason = if ($assessment.low_signal_only) { "low-signal-only" } else { $assessment.classification }
            throw "$($assessment.short_commit) is $reason. Re-run with -ForceReview to create an inspectable attempt."
        }

        $attemptResult = Invoke-Git -WorkingDirectory $candidateRoot -Arguments @(
            "cherry-pick", "--no-commit", $fullCommit
        ) -AllowFailure
        $attempt = [ordered]@{
            generated_at = [DateTimeOffset]::Now.ToString("o")
            commit = $fullCommit
            classification = $assessment.classification
            subject = $assessment.subject
            candidate_worktree = $candidateRoot
            cherry_pick_exit_code = $attemptResult.ExitCode
            cherry_pick_output = $attemptResult.Output
            assessment = $assessment
        }
        $attemptPath = Join-Path $reportsPath "attempt-$($assessment.short_commit).json"
        Write-JsonFile -Path $attemptPath -Value $attempt

        if ($attemptResult.ExitCode -ne 0) {
            Write-Host "Patch has conflicts. The candidate worktree was left intact for review."
            Write-Host "Attempt report: $attemptPath"
            exit 2
        }

        $testScript = Join-Path $PSScriptRoot "Test-UpstreamCandidate.ps1"
        & $testScript -RepositoryPath $candidateRoot -BaselineRef $state.target_ref -Mode Policy
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Patch applied, but the cull-policy gate failed. Nothing was committed."
            Write-Host "Attempt report: $attemptPath"
            exit $LASTEXITCODE
        }
        Write-Host "Patch applied and staged; nothing was committed."
        Write-Host "Inspect: git -C `"$candidateRoot`" diff --cached"
        Write-Host "Attempt report: $attemptPath"
    }

    "Record" {
        if ([string]::IsNullOrWhiteSpace($Commit) -or [string]::IsNullOrWhiteSpace($Decision)) {
            throw "-Commit and -Decision are required for Record."
        }
        $fullCommit = (Invoke-Git -WorkingDirectory $repoRoot -Arguments @("rev-parse", "$Commit^{commit}")).Output[0]
        $queue = @(Get-Queue -Repo $repoRoot -State $state -Policy $policy)
        if ($queue.Count -eq 0) {
            throw "The intake queue is empty."
        }
        if ($queue[0].commit -ne $fullCommit) {
            throw "The next sequential decision is $($queue[0].short_commit), not $($fullCommit.Substring(0, 9))."
        }
        $assessment = $queue | Where-Object { $_.commit -eq $fullCommit } | Select-Object -First 1
        if ($null -eq $assessment) {
            throw "$Commit is not in the current intake queue."
        }
        if (($Decision -eq "Accepted" -or $Decision -eq "Partial") -and [string]::IsNullOrWhiteSpace($AppliedCommit)) {
            throw "-AppliedCommit is required for Accepted and Partial decisions."
        }
        if (($Decision -eq "Accepted" -or $Decision -eq "Partial") -and [string]::IsNullOrWhiteSpace($EvaluationReport)) {
            throw "-EvaluationReport is required for Accepted and Partial decisions."
        }
        if (($Decision -eq "Skipped" -or $Decision -eq "Rejected") -and -not [string]::IsNullOrWhiteSpace($AppliedCommit)) {
            throw "Skipped and Rejected decisions cannot have -AppliedCommit."
        }
        if (-not [string]::IsNullOrWhiteSpace($AppliedCommit)) {
            $AppliedCommit = (Invoke-Git -WorkingDirectory $repoRoot -Arguments @("rev-parse", "$AppliedCommit^{commit}")).Output[0]
            $ancestor = Invoke-Git -WorkingDirectory $repoRoot -Arguments @(
                "merge-base", "--is-ancestor", $state.target_ref, $AppliedCommit
            ) -AllowFailure
            if ($ancestor.ExitCode -ne 0) {
                throw "Applied commit $AppliedCommit is not descended from $($state.target_ref)."
            }
            $message = (Invoke-Git -WorkingDirectory $repoRoot -Arguments @(
                "show", "-s", "--format=%B", $AppliedCommit
            )).Output -join "`n"
            if ($message -notmatch "(?m)^Upstream-Commit:\s+$([regex]::Escape($fullCommit))\s*$") {
                throw "Applied commit $AppliedCommit lacks the full Upstream-Commit: $fullCommit trailer."
            }
        }

        $record = [ordered]@{
            recorded_at = [DateTimeOffset]::Now.ToString("o")
            upstream_commit = $fullCommit
            subject = $assessment.subject
            classification = $assessment.classification
            decision = $Decision.ToLowerInvariant()
            applied_commit = $AppliedCommit
            evaluation_report = $EvaluationReport
            notes = $Notes
            retained_paths = $assessment.retained_paths
            culled_paths = $assessment.culled_paths
            new_scope_paths = $assessment.new_scope_paths
        }
        $recordPath = Join-Path $decisionsPath "$($fullCommit.Substring(0, 9)).json"
        Write-JsonFile -Path $recordPath -Value $record

        $existing = @($state.decisions | Where-Object { $_.upstream_commit -ne $fullCommit })
        $state.decisions = @($existing + [pscustomobject]$record)
        $state.last_evaluated_upstream = $fullCommit
        $state.last_observed_upstream = (Invoke-Git -WorkingDirectory $repoRoot -Arguments @("rev-parse", $state.upstream_ref)).Output[0]
        Write-JsonFile -Path $statePath -Value $state
        Write-Host "Recorded $Decision for $($fullCommit.Substring(0, 9)): $recordPath"
    }
}
