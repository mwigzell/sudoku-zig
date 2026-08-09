Status: closed
triaged: 2025-01 — const-correctness fix, all AC met

## Problem

**S3 from full code review:** `Board.asView()` takes `self: *Board` but never mutates anything. A mutable pointer on read-only function invites callers to assume mutation is possible, and blocks legitimate const-correct access.

Related question (not the fix): `asRow`, `asCol`, `asBox` are declared inside `Board` but take no `self` — they're free functions wearing a uniform they don't need. Whether RowView/ColView/BoxView should eventually move to a Grid topology module is an architectural decision, not part of the const-correctness fix.

---

## What's wrong with `*Board` vs `*const Board`

A mutable pointer lies about intent — it promises you might mutate, when the function only reads. In Zig this has real consequences beyond style:

1. **Callers must have non-const state.** If `asView` is `fn asView(self: *Board)`, and someone's board reference is `*const Board` (because they're in a read-only context), they can't call it at all. The type system blocks them even though nothing dangerous would happen — the function doesn't write.

2. **Zig won't implicitly downcast `*T` to `*const T` *inside the callee*,** but it *will* let you pass any pointer through a mutable binding if the signature demands it. This means functions accepting `*Board` silently accept pointers that could later be mutated downstream — even when the caller just wanted to peek.

The fix is simple: make the read-only accessor const-correct so Zig enforces the boundary.

## Acceptance Criteria

- [x] `asView()` signature changed from `self: *Board` to `self: *const Board`
- [x] All call sites still compile (no changes needed — callers can coerce `*const` into the parameter)
- [x] All 41 tests pass
**Commit:** see below

## Open Question (deferred)

Should RowView, ColView, BoxView and their constructors move to a `Grid` topology module? CONTEXT.md already describes "Immutable topology engine" as a separate concern. If yes, that's a later architectural change under its own issue — not part of this const-correctness fix.
