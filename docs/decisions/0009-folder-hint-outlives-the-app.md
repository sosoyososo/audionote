# ADR-0009: The folder hint outlives the app; the access bookmark does not

- **Status:** Accepted
- **Date:** 2026-10-22
- **Related:** ADR-0007 (the storage-state rules), ADR-0008 (the same "what survives an uninstall" question, for the provider profiles)

## Context

The data lives in a folder the user picks in the Files app, and it
survives an uninstall. Two things do not:

- The **access bookmark** — a security-scoped bookmark, stored in
  `UserDefaults`, which dies with the app.
- The **path fallback** — the same folder's path, also in
  `UserDefaults`.

So after a reinstall the app can reach the folder, but it has no idea
*which* folder it was. The onboarding copy can only say "pick the same
folder again", and a user with several folders in "On My iPhone" has to
remember which one.

The internal path cannot help either: it contains a per-install
container id, so it is different on every install. But the folder's
**name** — the last path component — is what the user sees in the Files
app, and that is stable.

## Decision

### 1. The folder's name is remembered in the Keychain

`StorageFolderHint` stores the folder's name under
`service = "audioNote.storage"`, `account = "lastFolderName"`.

The Keychain is the only store in the app that survives an uninstall,
and it is the right tier for a fact of this kind: the app has to be
able to name the folder after a fresh install.

The onboarding copy then says "your data is still in the **AudioNote**
folder in the Files app — pick that folder again" instead of "pick the
same folder again".

### 2. The access bookmark stays in `UserDefaults`, and must not move

This is the load-bearing half of the decision, and it is the opposite
of the hint's.

A security-scoped bookmark is the app's *permission* to the folder.
`UserDefaults` dies with the app, so a fresh install has no permission
— and that is the correct behaviour: **a reinstalled app must not
inherit folder access without the user asking for it.** Moving the
bookmark to the Keychain would hand a reinstalled app standing access
to the user's data on the strength of a credential nobody re-authorized.

### 3. The bookmark cannot go into the folder either, and the reason is circular

Storing the bookmark *in* the data folder looks appealing — everything
in one place. It does not work: without a bookmark the app has no
permission to read the folder, so a bookmark stored inside it could
never be read to restore access. The credential cannot be kept in the
thing it unlocks.

### 4. The hint is a hint, never a credential

`StorageFolderHint` tells the user which folder to pick. It grants
nothing, and the user still has to pick the folder through the system
picker, which is what actually produces access.

## Consequences

- After a reinstall, the app names the folder instead of asking the user
  to remember it.
- The Settings screen shows the current folder's name, so the question
  "where is my data?" has an answer in the app.
- A user who deliberately points the app at a different folder overwrites
  the hint — the hint always names the folder the app last used.

## Alternatives rejected

- **Store the bookmark in the Keychain** so a reinstalled app recovers
  its access automatically. It would make the reinstall path seamless —
  and it would hand a fresh install standing access to the user's data
  without the user re-authorizing anything. Not worth it, and the
  system's design is deliberate.
- **Store the bookmark in the data folder.** Circular: no bookmark, no
  permission to read the folder.
- **Store the hint in `UserDefaults` alongside the bookmark.** It dies
  with the app, which is the exact problem being solved.
- **Keep the full internal path.** It contains a per-install container
  id, so it is wrong after every reinstall. Only the name is stable.

## Verification

- `ios/AudioNoteTests/StorageFolderHintTests.swift` — 6 tests: the
  empty case, the round trip, the name-is-the-last-path-component
  derivation, the blank name, the overwrite, and the forget.
- Full suite: 237 tests, 0 failures.
