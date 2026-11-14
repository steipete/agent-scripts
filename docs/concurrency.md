---
summary: Swift concurrency mental model: isolation first, async/await second.
read_when:
  - Working with Swift async/await, actors, Task, TaskGroup, or Sendable
  - Debugging data races or isolation issues in Swift code
  - Understanding MainActor vs @concurrent vs nonisolated
---

# Swift Concurrency (Approachable) - RepoBar Notes

## Goal
Practical mental model: isolation first, async/await second.

## Core Ideas
- `async/await`: pause/resume, not background work.
- Isolation domains: who can touch state, not which thread runs code.
- Structured concurrency: prefer `async let` / `TaskGroup` over unstructured `Task`.
- Inheritance: isolation flows from caller to callee unless you opt out.
- Compiler safety: isolation and `Sendable` prevent data races.

## Async/Await (Deep Cut)
- `async` marks a function that can suspend.
- `await` marks a suspension point; code resumes where it paused.
- `await` only inside `async` functions.
- Sequential `await` is serial; use `async let` for parallel I/O.
- Most app work is I/O-bound; `await` keeps UI responsive.
- CPU-bound work still blocks the current actor unless you opt out.

## Tasks (Units of Work)
- `Task {}` starts async work from sync code; inherits actor, priority, task-locals.
- SwiftUI `.task` / `.task(id:)` auto-cancels when view disappears.
- `TaskGroup`: dynamic fan-out; child tasks are structured.
  - Cancellation propagates from parent to children.
  - Errors cancel siblings and rethrow when results are consumed.
  - Results arrive as tasks finish, not submission order.
  - Waits for all: group returns after all children finish or cancel.
- `Task.detached {}` inherits nothing (no actor, priority, task-locals); last resort.
- Structured concurrency = tree of tasks, easier cleanup + cancellation.

## Where Code Runs (Isolation Domains)
- `@MainActor`: UI isolation; safe default for app code.
- `actor`: protects its own mutable state; exclusive access. Not a thread.
- `nonisolated`: opts out of actor isolation; cannot touch actor state.

## From Threads to Isolation
- Data race: concurrent access to same memory with at least one write.
- Swift model: isolate data, let compiler enforce boundaries.
- Runtime uses cooperative thread pool (limited to CPU cores); blocking it can deadlock.
  - Avoid `DispatchSemaphore.wait()` / sync waits in async code.

## Approachable Concurrency Defaults
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: app starts on MainActor.
- `SWIFT_APPROACHABLE_CONCURRENCY = YES`: async stays on caller actor.
- Xcode 26 enables both by default.
- Use `@concurrent` for CPU-heavy work off main actor (Swift 6.2+).

## Isolation Inheritance Rules
- Functions run on caller isolation unless annotated.
- Closures inherit isolation from definition context.
- `Task {}` inherits actor + priority + task-locals.
- `Task.detached {}` inherits nothing.

## Sendable (Crossing Boundaries)
- `Sendable` types safe across isolation domains.
- Structs/enums with `Sendable` members are implicitly `Sendable`.
- Actors and `@MainActor` types are `Sendable`.
- Classes need `final` + immutable stored properties to be `Sendable`.
- `@unchecked Sendable` is a promise; wrong == data races.
- Do not make everything `Sendable`; only cross boundaries when needed.

## When to Introduce an Actor
- Use only when:
  - State is non-`Sendable`,
  - Operations must be atomic,
  - It cannot live on an existing actor (often `MainActor`).
- Otherwise, keep on `@MainActor`.

## Preferred Patterns
- Mark ViewModels `@MainActor` by default.
- `async let` for parallel fetches; `TaskGroup` for dynamic sets.
- Keep state on one actor; cross boundaries only when needed.
- If compiler complains, trace inheritance path.
- Start simple; add complexity only when you hit real problems.

## Common Mistakes
- Thinking `async` == background; CPU work still blocks without `@concurrent`.
- Overusing `Task.detached` instead of structured concurrency.
- Creating too many actors for simple app state.
- Spamming `@unchecked Sendable` instead of redesigning boundaries.
- Calling `MainActor.run` instead of annotating the function.
- Blocking cooperative pool with semaphores or sync waits.
- Creating `Task` inside `async` functions instead of `async let`/`TaskGroup`.

## Quick Reference
- `async`: function can suspend.
- `await`: suspension point.
- `Task {}`: start async work, inherits context.
- `Task.detached {}`: start async work, no inheritance.
- `@MainActor`: UI isolation.
- `actor`: isolated mutable state.
- `nonisolated`: opt out of isolation.
- `Sendable`: safe to cross boundaries.
- `@concurrent`: run off main actor (Swift 6.2+).
- `async let`: parallel work.
- `TaskGroup`: dynamic parallel work.
