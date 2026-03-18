---
description: Start a complete feature development workflow with Superpowers + Speckit integration
handoffs:
  - label: Clarify & Design
    agent: superpowers:brainstorming
    prompt: Clarify requirements and propose design approaches
  - label: Generate Spec
    agent: speckit.specify
    prompt: Generate feature specification
  - label: Plan Implementation
    agent: speckit.plan
    prompt: Create implementation plan
  - label: Design UI
    agent: ui-ux-pro-max:ui-ux-pro-max
    prompt: Design UI components
  - label: Create Tasks
    agent: speckit.tasks
    prompt: Break into executable tasks
  - label: Implement
    agent: speckit.implement
    prompt: Execute implementation
---

## Workflow: Superpowers + Speckit Integration

This command starts the complete feature development workflow for AudioNote iOS app.

### Phase 1: Requirements Clarification (Superpowers)

1. **Invoke brainstorming**: Use `superpowers:brainstorming` skill to:
   - Ask clarifying questions (one at a time)
   - Propose 2-3 approaches with trade-offs
   - Present design and get user approval

### Phase 2: Specification (Speckit)

2. **Generate spec**: Use `/speckit.specify` with the refined feature description

### Phase 3: Planning (Speckit)

3. **Create plan**: Use `/speckit.plan` to generate implementation plan

### Phase 4: UI Design (Conditional)

4. **Detect UI relevance**: Check if task involves UI changes:
   - Keywords: `UI`, `view`, `界面`, `页面`, `按钮`, `样式`, `颜色`, `布局`
   - File paths: `Views/`, `ViewModels/`
   - Feature description contains UI-related terms

5. **If UI-related**: Use `/ui-ux-pro-max` for UI design before implementation

### Phase 5: Implementation

6. **Create tasks**: Use `/speckit.tasks`

7. **Execute**: Use `/speckit.implement`

## Usage

```
/feature Add a dark mode toggle in settings
```

This will:
1. Run brainstorming to clarify dark mode requirements
2. Generate spec document
3. Create implementation plan
4. (If UI) Design UI components
5. Break into tasks
6. Execute implementation
