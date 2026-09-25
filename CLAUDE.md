# CLAUDE.md - ChekiLens Claude Code Agent Guidelines

> This file is automatically read by Claude Code CLI and Claude extensions upon startup.

## Development Workflow & Quota Management

1. **Always Check Progress First**:
   - Run `cat docs/PROGRESS.md` and `git status` + `git log -n 3` before executing any task.
   - Inform the user of current checkpoint and the exact task you are working on.

2. **Strict Atomic Execution**:
   - Only execute **ONE** task from `docs/PROGRESS.md` at a time.
   - Do NOT touch unrelated files or attempt to build multiple features at once.
   - Keep diffs small, focused, and verified.

3. **Verification & Completion Protocol**:
   - Run build/test command: `swift test` or `xcodebuild -scheme ChekiLens test` when available.
   - Update `docs/PROGRESS.md`: mark completed task as `[x]`, update checkpoint summary and next step.
   - Create a clean git commit: `git commit -m "feat(module): complete Task X.X - description"`.

4. **Tech Stack**:
   - Swift 5.9 / Swift 6, SwiftUI (iOS 17/18 HIG matching `docs/ui/` designs).
   - SwiftData for persistence.
   - Core Image + Vision Framework for cheki crop, perspective correction & OCR.
   - Photos Framework for album organization.
   - StoreKit 2 for lifetime IAP.
