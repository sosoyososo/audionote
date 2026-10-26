# ADR-0008: The provider profiles belong in the data folder, and the API key does not

- **Status:** Accepted
- **Date:** 2026-10-22
- **Amends:** ADR-0003 (the profiles move out of `UserDefaults`)
- **Related:** ADR-0007 (the storage-state rules the move inherits)

## Context

`ProviderProfileStore` kept the LLM provider profiles in `UserDefaults`.
A profile carries an `id`, and that `id` is the **Keychain account name**
its API key is stored under (`keychain.set(apiKey, account: profile.id.uuidString)`).

`UserDefaults` lives in the app's container, so it dies with the app.
The Keychain does not. That asymmetry is the whole problem:

- The user reinstalls the app.
- Their profiles are gone. Their API keys are still in the Keychain.
- The keys are now **orphans**: nothing knows which account to look up.
- The user re-enters the API key by hand, for every provider, on every
  device they ever reinstall on.

The data was not lost — it was *unreachable through the index*. And the
index was the one thing that had been left behind.

The obvious fix — make the Keychain account a stable function of the
provider instead of a random UUID — is dirtier than it looks: the user
would still have to re-create each profile (name, base URL, model) before
the key could be found, and "the profile's identity is its display name"
is a worse identity than a UUID.

## Decision

### 1. The profiles live in the data folder, in `profiles.json`

`UserDefaults` → `profiles.json`, next to `transcriptions.json` and
`relatedNotes.json`. The folder is the user's, and it is the only place
in the app that survives an uninstall.

The ids come back with the folder, so the Keychain accounts come back
with them, and the API keys are found again. **A reinstall stops costing
the user their API keys.**

### 2. The API key does not go into the folder

The folder syncs (iCloud Drive), gets copied to a computer, and gets
shared with other people. A secret in it is a leak, and a leak that
travels is worse than a leak that does not.

The key stays in the Keychain, which is per-device by design: a user
with two devices re-enters the key once per device, which is the correct
trade for a secret that is portable.

### 3. The migration preserves the ids, and it is the delicate part

On the first run after the upgrade, the profiles are copied from
`UserDefaults` into the folder **with their ids unchanged**, and the
`UserDefaults` copy is then deleted.

Regenerating an id during the migration would be a silent, total failure
of the feature: the profile would come back, the user would see it, and
the key would not be found — and the key would be *unrecoverable*,
because the account name it was stored under would no longer exist
anywhere. The tests assert the id survives, and they assert it by
looking the key up **through the migrated profile**, not through the id it
used to have: asking for the old id directly would find the key even if
the migration had thrown the id away, which is exactly the bug the test
exists to catch.

### 4. The read is asynchronous, and the callers wait for it

The folder is a user-visible FileProvider location and can be slow. The
profiles are read once per session and cached in memory; the read is
`await`ed at every site that needs a profile — the LLM path, the
related-notes path, and the settings screen.

`ProviderProfileStore.ensureLoaded()` is idempotent and safe to await
from several places at once: the first caller starts the read and the
rest wait for it.

A caller that skipped the wait would find an empty profile list, decide
"the user has not configured a provider", and silently skip the LLM
path. That is why the wait is at the call sites and not hidden behind a
synchronous accessor.

### 5. The write is the commit point

`upsert`, `delete` and `setActive` write the file first and update the
in-memory state only afterwards. A failed write must not leave the
session showing a profile the folder does not have — that is the same
"the app believes something the disk does not" failure that ADR-0007 is
about, in a smaller disguise.

### 6. The related-notes service takes its profile by injection

`RelatedNotesService` already took its storage, its records and its LLM
by injection. The profile was the one thing it reached for globally,
which meant its tests had to mutate a singleton to exercise it at all —
making them order-dependent, and making a test run write into whatever
folder the store happened to point at.

It now takes a `RelatedNotesProfileSource`. The shared store conforms to
it; the tests supply a stub.

### 7. What did **not** move, and why

- **The access bookmark stays in `UserDefaults`.** Putting it in the
  folder would be circular: without a bookmark the app has no permission
  to read the folder, so a bookmark *in* the folder could not be read to
  restore access. It also dies with the app on purpose — a fresh install
  should not inherit folder access without the user asking.
- **The API key stays in the Keychain.** See rule 2.
- **`needsProviderSetup` stays in `UserDefaults`.** It is a one-shot flag
  for *this installation* — "show the setup toast once" — not
  configuration.
- **The language selection stays in `UserDefaults`.** It is a
  device-local UI preference with no value in travelling.

## Consequences

- A reinstall no longer costs the user their API keys, as long as they
  pick the same folder.
- The profiles are now visible in the Files app, as JSON. That is
  consistent with the records file being visible, and it means the
  configuration is as backup-able as the data.
- Two devices sharing an iCloud folder share the *profile* but not the
  key. The second device asks for the key once.
- The profiles are read asynchronously, so the settings screen shows a
  loading placeholder rather than the "no providers configured" empty
  state before the read finishes.
- **Known limitation.** If the folder is unreachable, the profiles are
  unreachable too — and the settings screen is unreachable as well,
  because the whole app is already gated on the folder. That is not a
  new restriction; it is the one that was already there.

## Alternatives rejected

- **Derive the Keychain account from the provider's name and base URL.**
  Then the user still has to re-create the profile before the key can be
  found, and "the display name is the identity" is a worse identity than
  a UUID — two providers with the same name would collide.
- **Keep the profiles in `UserDefaults` and mirror them into the folder.**
  Two sources of truth that drift, with a precedence rule to remember.
- **Put the API key in the folder too.** A secret in a folder that syncs
  and gets shared. No.
- **Put the bookmark in the folder.** Circular: no bookmark, no
  permission to read the folder.

## Verification

- `ios/AudioNoteTests/ProviderProfileStorageTests.swift` — 12 tests:
  the file's load outcomes (missing / parsed / corrupt), the payload
  round-trip, the migration (ids preserved, key still findable through
  the migrated profile, the legacy copy cleared, the folder not
  overwritten by a stale legacy copy), a first run, and the three
  mutations.
- Full suite: 231 tests, 0 failures.
- Red-verified: a migration that regenerates the ids fails 6 of the 8
  store tests.
