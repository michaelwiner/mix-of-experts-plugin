---
name: moe
description: Start a feature development workflow powered by multi-model consultation (Mix of Experts)
argument-hint: "<feature description>"
allowed-tools:
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Bash
  - Task
  - LSP
  - WebSearch
  - WebFetch
  - AskUserQuestion
  - TodoWrite
---

# Mix of Experts Feature Development

The user wants to build a feature using the Mix of Experts workflow.

**Initial request:** $ARGUMENTS

Load the `moe-workflow` skill and follow its instructions to guide the user through the full feature development lifecycle with multi-model consultation at key decision points.

The feature to build is described above in the initial request. If no feature was specified, ask the user what they want to build.
