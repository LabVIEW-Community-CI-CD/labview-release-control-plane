# Local Agent Instructions

## Mission
This repository is the org-level release orchestration control-plane for enrolled LabVIEW repos.

## Contract Files
- Platform policy schema: `contracts/platform-policy.schema.json`.
- Repo enrollment schema: `contracts/repo-enrollment.schema.json`.
- Program report schema: `contracts/program-report.schema.json`.
- Incident envelope schema: `contracts/incident-envelope.schema.json`.

## Reusable Program Workflow
- Canonical workflow: `.github/workflows/release-program.yml`.
- Canonical composite action: `.github/actions/run-control-plane/action.yml`.
- Runtime script: `scripts/Invoke-ReleaseProgram.ps1`.

## Wave-0 Enrollment Set
- `LabVIEW-Community-CI-CD/labview-cdev-surface-fork`
- `LabVIEW-Community-CI-CD/labview-cdev-cli`
