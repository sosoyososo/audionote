# audionote Development Guidelines

Auto-generated from all feature plans. Last updated: 2026-01-18

## Active Technologies

- Swift 5.9 + SwiftUI, Speech Framework, AVFoundation (001-voice-transcription)

## Project Structure

```text
src/
tests/
```

## Commands

# Add commands for Swift 5.9

## Code Style

Swift 5.9: Follow standard conventions

## Recent Changes

- 001-voice-transcription: Added Swift 5.9 + SwiftUI, Speech Framework, AVFoundation

<!-- MANUAL ADDITIONS START -->

## Feature Development Workflow

This project uses an integrated workflow combining **Superpowers** and **Speckit** for feature development.

### Quick Start

Use `/feature [description]` to start the complete workflow:

```
/feature Add dark mode support
```

### Workflow Overview

| Phase | Tool | Description |
|-------|------|-------------|
| 1. Clarification | Superpowers brainstorming | Understand requirements, propose approaches |
| 2. Specification | Speckit specify | Generate `specs/XXX-feature/spec.md` |
| 3. Planning | Speckit plan | Generate `plan.md`, `research.md` |
| 4. UI Design | /ui-ux-pro-max | Auto-triggered for UI tasks |
| 5. Tasks | Speckit tasks | Break into executable tasks |
| 6. Implement | Speckit implement | Execute implementation |

### UI Detection

UI design phase (`/ui-ux-pro-max`) is automatically triggered when the feature involves:
- Keywords: UI, view, 界面, 页面, 按钮, 样式, 颜色, 布局
- Files in: Views/, ViewModels/
- Description contains UI-related terms

### Manual Commands

If you prefer manual control:

| Command | Purpose |
|---------|---------|
| `/superpowers:brainstorming` | Start brainstorming for a feature |
| `/speckit.specify` | Generate feature specification |
| `/speckit.plan` | Create implementation plan |
| `/speckit.tasks` | Break plan into tasks |
| `/speckit.implement` | Execute implementation |
| `/ui-ux-pro-max` | Design UI components |

<!-- MANUAL ADDITIONS END -->
