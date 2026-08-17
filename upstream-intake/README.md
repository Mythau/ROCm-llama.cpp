# Upstream intake workflow

This directory turns upstream llama.cpp commits into an ordered, auditable
intake queue for the culled ROCm fork. It does not merge upstream into the fork
and it never commits a patch attempt automatically.

## Branches and state

- `upstream/master` is the unmodified upstream source.
- `yolo-mainline` is the promoted culled runtime.
- `intake/<upstream-tip>` is a disposable candidate branch in its own worktree.
- `state.json` advances only when each upstream commit receives a recorded
  decision.

Commit the workflow itself before creating the first candidate worktree so the
candidate branch also contains these scripts and policy files.

## 1. Build the queue

From the repository root:

```powershell
./upstream-intake/Invoke-UpstreamIntake.ps1 -Action Plan
```

Add `-Fetch` when the upstream remote should be refreshed. Planning writes a
JSON report and prints the four classifications:

- `skip`: only culled paths are touched;
- `try_full`: all touched paths already survive in the target tree;
- `review_partial`: retained and culled paths are mixed;
- `scope_change`: the commit introduces paths outside the current target tree.

Classification is triage, not approval. A backend-specific commit can touch a
shared retained test while its implementation belongs entirely to a removed
backend. Commits whose retained overlap consists only of tests, documentation,
or build metadata are marked `low_signal_only` in the JSON plan and also require
`-ForceReview`.

## 2. Create a candidate worktree

```powershell
./upstream-intake/Invoke-UpstreamIntake.ps1 -Action Start
```

The command prints the worktree path and candidate branch. The active source
worktree may be dirty; it is not modified.

## 3. Attempt one upstream commit

```powershell
./upstream-intake/Invoke-UpstreamIntake.ps1 `
  -Action Attempt `
  -Commit e79e4bf66 `
  -WorktreePath C:/path/printed/by/start
```

`try_full` commits are attempted directly. `review_partial` and `scope_change`
require `-ForceReview`. The cherry-pick uses `--no-commit`, leaves the complete
staged change available for inspection, and runs the no-resurrection policy.

For a conflict, resolve retained code normally while keeping explicitly culled
paths absent. Then run the policy gate directly:

```powershell
./upstream-intake/Test-UpstreamCandidate.ps1 `
  -RepositoryPath C:/candidate/worktree `
  -BaselineRef yolo-mainline `
  -Mode Policy
```

Do not silently discard part of a mixed patch. A deliberate partial port is a
`Partial` decision and its omitted paths remain in the decision record.

## 4. Build and test

Configure and test the retained HIP build:

```powershell
./upstream-intake/Test-UpstreamCandidate.ps1 `
  -RepositoryPath C:/candidate/worktree `
  -Mode Build `
  -Backend Hip `
  -Configure
```

The validator derives affected subsystems from the candidate diff and prints
the required gates. Use `-RunPythonServerTests` for server/speculative patches
and `-RunUiTests` for UI changes. The UI gate runs Svelte checking, unit tests,
and a production build; install `tools/ui` dependencies first. Vulkan changes
get a separate `-Backend Vulkan` build.

Quick performance validation builds and tests first, prints the full server
test plan, and runs one warmup plus one measurement only when
`-RunPerformance` is supplied:

```powershell
./upstream-intake/Test-UpstreamCandidate.ps1 `
  -RepositoryPath C:/candidate/worktree `
  -Mode Quick `
  -Backend Hip `
  -ServerExecutable C:/candidate/build/bin/llama-server.exe `
  -RunPerformance
```

Use `-Mode Final -RunPerformance` before promotion. Final mode uses one complete
warmup and three measurements through the established ROCm YOLO server runner.

## 5. Commit and record

After review and validation, commit in the candidate worktree with provenance:

```text
Upstream-Commit: <full upstream SHA>
Upstream-Mode: full | partial
Evaluation-Report: upstream-intake/reports/<report>
```

Then advance the ordered ledger from the source worktree:

```powershell
./upstream-intake/Invoke-UpstreamIntake.ps1 `
  -Action Record `
  -Commit <upstream-sha> `
  -Decision Accepted `
  -AppliedCommit <candidate-commit> `
  -EvaluationReport upstream-intake/reports/<report>
```

For commits with no downstream patch, use `-Decision Skipped` or
`-Decision Rejected`. Recording is sequential, which prevents the watermark
from jumping over an undecided commit. Accepted and partial decisions require
an evaluation report and an applied commit carrying the full
`Upstream-Commit:` trailer.

## Promotion

Promote only an intake branch whose entire upstream range has decisions and
whose final HIP/server validation passed. Preserve one downstream commit per
accepted upstream patch or atomic upstream series so regressions remain
bisectable. Do not merge `upstream/master` into `yolo-mainline`.
