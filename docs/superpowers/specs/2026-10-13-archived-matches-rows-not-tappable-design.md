# Archived Matches Rows Are Not Tappable — Backlog Stub

**Status:** 📋 FILED — no decision made. User deferred discussion of archiving
to a later session (2026-10-13). Nothing here is a plan.
**Created:** 2026-10-13
**Branch at filing:** `main` (`cf37c8b`)

---

## 1. Problem

When the library has an active filter (search and/or tags) and some
**archived** records match it, `LibraryArchivedMatchesView`
(`LibraryListView.swift:427-460`) lists them behind the archived banner
(`:141-158`). None of those rows can be opened — tapping one does nothing.

## 2. Cause (verified 2026-10-13, `main` @ `cf37c8b`)

```swift
// LibraryListView.swift:438-442
ForEach(archivedMatches) { record in
    RecordRowView(record: record)
        .listRowBackground(Color.orange.opacity(0.05))
}
```

`RecordRowView` is rendered as a plain view, with no `.onTapGesture`, no
`Button`, and no `NavigationLink` wrapper. `LibraryArchivedMatchesView` also
declares no `@State` sheet binding — unlike `LibraryListView` itself, which
holds `@State private var selectedRecord: TranscriptionRecord?`
(`LibraryListView.swift:5`) and presents the detail via
`.sheet(item: $selectedRecord)` (`:23-30`).

The two working detail entry points in the app are both elsewhere:

| Entry | Location |
|---|---|
| Library list row | `LibraryListView.swift:23-30` |
| 相关思考 row | `TranscriptionDetailView.swift:645-648` |

So the archived result list is the only record-rendering surface in the app
with no path to a detail at all.

## 3. Why it was filed rather than fixed

Found while scoping the tag-filter-context highlight
(`2026-10-13-detail-filter-context-highlight-design.md` §8). It is a real
defect, but the fix is not merely "add a tap handler" — see §4. The user
chose to discuss archiving separately before any decision is recorded.

## 4. Open questions (unanswered — do not assume)

1. **How should the detail be presented** — reuse the existing `.sheet(item:)`
   with a local `@State selectedRecord`, or wrap each row in a
   `NavigationLink`? The surrounding view is already inside a `NavigationView`
   (pushed from the banner), so a `NavigationLink` push is the more idiomatic
   fit and would give a back button for free; the sheet would give the detail's
   own close button. The main list uses the sheet today, so a push here would
   be the app's second convention.
2. **Does tapping an archived record need an un-archive affordance up
   front?** The detail's `actionsSection` already offers 取消归档
   (`Design.Action.Unarchive`), so pushing/sheet-ing is sufficient — but the
   user may want the banner to say so.
3. **Is a searchable/tappable archived list even wanted**, versus leaving
   the archived matches as a count-only banner? A user who can see *that* 12
   records match but can open none of them has a filter that silently fails
   at its own boundary. Removing the banner is a legitimate answer and is
   cheaper than fixing the rows.
4. **Does the archived list need the same filter-context highlight** as the
   live list? Its rows currently get no selection affordance at all.

## 5. Related

- Tag filter semantics: `TranscriptionViewModel.swift:727-730` (OR),
  `:787-790` (`archivedHitIDs` — the same predicate as the live list).
- `LibraryArchivedMatchesView` re-derives `archivedMatches` locally
  (`:429-434`) instead of exposing a filtered array on the view model; note
  the live list's `displayedRecords` (`:723-741`) carries the hit-count sort
  that this one does not (`createdAt` desc only). If §4.1 picks a push, that
  sort divergence is worth resolving at the same time.
- Tag case-sensitivity mismatch observed during the same pass — filed in
  `2026-10-13-detail-filter-context-highlight-design.md` §8.
