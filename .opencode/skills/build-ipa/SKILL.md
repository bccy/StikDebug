---
name: build-ipa
description: Build the StikDebug IPA via the GitHub Actions workflow (build_ipa.yml) and download the finished IPA to the local machine. Use when the user asks to 编译/打包/出包/构建 IPA, wants the compiled IPA delivered locally after code changes, or says "trigger the build"/"run the workflow". Do NOT use for local Xcode builds.
---

# Build IPA via GitHub Actions

Goal: turn the current code into `StikDebug-Debug.ipa` on this machine by letting GitHub Actions compile it, then downloading the artifact back.

## How it works

- The workflow `.github/workflows/build_ipa.yml` (in this repo) builds on `macos-latest`, packages `.app` into `.ipa`, and uploads it as artifact `StikDebug-Debug.ipa` (read the `upload-artifact` step to confirm the name).
- Builds trigger on: push to `main` (or `semi-rewrite`) and `workflow_dispatch`.
- **The build compiles the code that is on GitHub, not the local working tree.** Local changes must be committed and pushed first. Never promise a build of uncommitted code.

## Prerequisites (verify first, ~1 command each)

- `gh` CLI installed and authenticated: `gh auth status` — must be logged in as an account with access to the repo shown by `git remote get-url origin`.
- `gh` must have the right repo: run `gh repo set-default` with the value of `git remote get-url origin` if the default repo is wrong.
- Workflow file exists: `.github/workflows/build_ipa.yml`. If the user edited it locally, it must be pushed before the build.

## Procedure

### 1. Choose a branch strategy — default to a temporary branch

The build compiles whatever is on GitHub. Pushing to `main` also publishes the Nightly release (workflow step "Deploy to Nightly Release" only fires for `refs/heads/main`), so:

- **Default (safest): temporary branch.** Create/push a scratch branch, build from it, then merge to `main` only after the IPA is verified.
  ```powershell
  git checkout -b build-test
  git add <intended files>          # never `git add -A` blindly; skip .reasonix/ etc.
  git commit -m "<concise message>"
  git push origin build-test
  ```
- **Rebuild of already-pushed code:** skip straight to step 3 (`--ref main` or the branch to rebuild).
- **User insists on `main`:** commit + push to `main`, then continue; the Nightly release will be updated.

### 2. (After push) let GitHub register the branch

Wait ~10 seconds, then find the latest run:

```powershell
gh run list --workflow build_ipa.yml --limit 1 --json databaseId,status,conclusion,headSha,headBranch
```

Verify `headSha` matches the pushed commit (`git rev-parse HEAD`). If the list is empty or shows an older sha, poll `gh run list` a few times (up to ~60s).

### 3. Trigger the build

- Temporary branch / any ref that is not auto-triggered (auto-trigger branches: `main`, `semi-rewrite`):
  ```powershell
  gh workflow run build_ipa.yml --ref <branch>
  ```
- Otherwise the push already started a run; skip this step unless a manual run is wanted.

### 4. Watch the build (long timeout!)

`gh run watch <databaseId> --exit-status` — this returns non-zero on build failure. **The macOS build takes 5–15 minutes: run the command with a timeout of at least 1_500_000 ms.** Do not use the default tool timeout.

On failure: `gh run view <databaseId> --log-failed` and summarize the failing step to the user.

### 5. Download the artifact

```powershell
gh run download <databaseId> -n StikDebug-Debug.ipa -D build/ipa
```

Confirm the artifact name matches the `name:` in the workflow's `upload-artifact` step (it may have been edited).

### 6. Report

List the downloaded file (`Get-ChildItem build/ipa`), print the full path of the `.ipa` to the user, and note the run URL from `gh run view <databaseId>`.

## Notes

- After a successful temp-branch build: download & verify the IPA, then merge the branch into `main` (`git checkout main && git merge build-test && git push origin main`) — unless the user already merged it.
- If the push-triggered run seems missing, remember `workflow_dispatch` can force a run on any ref (step 3).
- `vars.UPLOAD_IPA` in the repo settings controls whether artifacts are uploaded; default `true`.
- Build-only usage: this skill never signs or installs the IPA — the artifact is unsigned, intended for sideloading (TrollStore / Sideloadly / etc.).
