---
status: confirmed
confidence: high
since: 2026-10-30
supersedes: <decision-file>
supersededBy: <decision-file>
---

## Context

The library's tag row is a horizontal strip of chips with the `全部 %d`
control pinned beside it, outside the scroll. Two problems came out of
that layout:

1. The strip was cut with a **hard edge** at the scroll view's boundary.
   A chip cut in half sat flush against the pinned control, so the
   control read as sitting *on top of* the strip — the user's complaint
   that the button "压在上边".
2. The two were separated by **nothing**: `HStack(spacing: 0)`, with the
   only gap being the scroll content's own trailing padding.

The same shape appears twice on the screen — the tag row and the
filter-status row (selected chips + "5 of 8" + 清除) — so whatever fixes
it has to hold for both.

## Decision

Both horizontal strips **fade their trailing edge** instead of being cut,
and the pinned control on the tag row is separated by a hairline rule.

| Element | Rule |
|---|---|
| Fade | `fadeOutTrailingEdge()` — a mask to transparent, one-sided (trailing), on the viewport |
| Separation | 1pt `Color(.separator)` rule, 22pt tall, 12pt gaps either side |
| Pinned control | stays **outside** the scroll — unchanged |

## Consequences

**Enables**

- The strip and the control read as two things, not one crowded thing.
- The fix is one line per strip plus one shared helper, and it holds for
  any content length — a strip shorter than the screen is unaffected.

**Forecloses**

- A colour fade is impossible without hardcoding the row's background.
  The mask is deliberately colour-free so it survives a background change.
- The pinned control cannot be moved into the scroll to make the row
  simpler. It is pinned on purpose: a button at the end of a scroll is
  the one thing the user cannot reach.
- The fade is on the *viewport*, so the last chip is slightly faded even
  at the end of the scroll. That is inherent to viewport fades and is
  accepted.

## Confidence

High. The layout was checked against a real render, the change is
presentational only, and the pinned-control rule is unchanged from what
the code already argued for.
