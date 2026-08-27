# Household sharing — release handoff

> Everything the household-sharing release needs from a human, and the exact copy
> for the two disclosure documents. The implementation is finished and tested in
> the repository; nothing on this page can be done by a coding agent, because all
> of it needs an authorized Apple Developer Program Account Holder/Admin, a real
> iCloud account, or a legal judgement call.
>
> The contract these steps close out is [`household-sharing.md`](./household-sharing.md)
> → *Release handoff* and *Verification and definition of done*. Implementation
> state is in [`status.md`](./status.md).

## 1. Apple provisioning (blocks everything else)

1. In Apple Developer, create or confirm the CloudKit container
   **`iCloud.com.tridge.app`** and associate it with the App ID **`com.tridge.app`**.
2. Enable **CloudKit** and **Push Notifications** for that App ID, then refresh
   the provisioning profiles.
3. Confirm the entitlements the repo already ships (`Tridge/Tridge.entitlements`):
   the iCloud container identifier, the `CloudKit` service, the ubiquity
   key-value store identifier, and `aps-environment` driven by `$(APS_ENVIRONMENT)`
   so a Debug build never carries a production push environment.

Until step 1 exists, **the TestFlight lane cannot archive** — the signed build
requests a container that is not there. Unsigned simulator builds and CI are
unaffected, which is why the repository work could be completed and verified
without it.

## 2. Development schema

Run once, from Xcode, on a Debug build signed into a development iCloud account:

1. Edit the `Tridge` scheme → Run → Arguments → add `-initializeCloudKitSchema`.
2. Launch once. The log line is `Initialized the CloudKit development schema`.
3. **Remove the argument again.**

The helper exists only in `#if DEBUG` and only behind that argument, so there is
no path to it from a Release build. Never run it against production.

After the two-account matrix passes, promote **that exact schema** to production
in CloudKit Console. Promotion is one-way and additive: after it, no shipped
entity or field may be removed, renamed, or retyped — future changes add
optional/defaulted fields in a new model version.

## 3. Test accounts and devices

Two different iCloud accounts, preferably on two physical devices. Keep exactly
one active Tridge installation signed into the Household **owner's** account —
that is a documented rollout constraint (ADR 0007), not an enforced device lock,
and the acceptance list depends on it.

## 4. Two-account acceptance

Run the checklist in [`household-sharing.md`](./household-sharing.md) →
*Two-account acceptance*. Simulator-only testing does not complete the contract:
App Attest, real invitations, and background push acceptance all need hardware.

## 5. Privacy policy — proposed replacement copy

**Do not merge this with the app change.** Any merged `server/**` change may
deploy before the app release, and the currently deployed policy is correct for
the app that is live today (local-only inventory, no cloud sync). Once the
sharing build is approved for rollout, a separate release-only PR edits
`server/src/privacy.ts` and deploys it **immediately before** that build is
distributed.

The changes below are the minimum needed to describe what the sharing build
actually does. Everything not mentioned stays exactly as it is.

### Replace the "What Tridge does" section

```html
<h2>What Tridge does</h2>
<p>Tridge turns a grocery-receipt image into a fridge inventory. Your inventory is stored on your device and in your own iCloud account, so it is available on your devices and can be shared with people you invite. Tridge does not provide its own account sign-in, advertising, or tracking.</p>
```

### Insert a new section after it

```html
<h2>Your fridge inventory and household sharing</h2>
<p>Your saved inventory — item names, quantities, storage locations, purchase and expiry dates, and the record of items you have eaten, tossed, or deleted — is stored in your device's local database and in the CloudKit database of the iCloud account signed in on your device. Apple operates iCloud; Tridge has no server that stores your inventory and no ability to read it.</p>
<p>Sharing is opt-in and invite-only. When you share a fridge, Apple's CloudKit sharing gives the people you invite read and write access to that fridge's records. Invitations are sent to specific recipients you choose; there is no public link, and only the person who started a fridge can invite people. Membership is managed by CloudKit; Tridge does not store or receive the names, email addresses, or phone numbers of the people you invite.</p>
<p>Your inventory is retained in your iCloud account until you remove it. In the app's Household screen you can export a fridge as a file, leave a fridge someone shared with you, stop sharing a fridge you started while keeping your own copy, or delete a fridge — including deleting a shared fridge for everyone. Leaving a fridge removes your access only; the person who started it keeps the data. Tridge also keeps the database created by earlier versions of the app on your device until you erase it from the same screen.</p>
<p>Receipt images and the raw text read from a receipt are never stored in iCloud. Only the inventory you confirm is saved.</p>
```

### Amend "Your choices"

```html
<h2>Your choices</h2>
<p>You can use manual item entry instead of receipt scanning. In the app's Household screen you can export a fridge's data, delete a fridge, leave a fridge shared with you, and erase the database kept by earlier versions of Tridge. If you have a privacy question or request, contact the project through the <a href="https://github.com/JINGBANZ/Tridge/issues">Tridge issue tracker</a>; do not include receipt images or other sensitive information in a public issue.</p>
```

Also bump the effective date to the deployment day.

## 6. App Store privacy answers — what changed

The release owner makes the final classification; this is what the implemented
data flow actually is, so the answers can be checked against something true.

| Question | What the sharing build does |
| --- | --- |
| Data collected | Tridge's own servers collect nothing new. Inventory is written to the user's own iCloud account (Apple-operated), which Apple's guidance treats as data stored on the user's behalf rather than collected by the developer. |
| Data types stored in iCloud | "Other User Content": item names, quantities, storage locations, purchase and expiry days, and stock history. No contact info, no identifiers, no location, no purchase history. |
| Data linked to the user | The developer holds none. Tridge never receives an iCloud identity: the account is reduced to a SHA-256 digest used only as a local scoping key and is never transmitted or logged. |
| Tracking | None. Unchanged. |
| Data shared with third parties | Unchanged: receipt images go to Cloudflare (Worker) and OpenAI (scan) only. Inventory goes to Apple iCloud only. Membership is never sent to the scan Worker. |
| Sharing between users | New: an invited person can read and write the shared fridge's inventory. This is user-initiated and revocable. |

## 7. `Tridge/PrivacyInfo.xcprivacy`

Review, and update **only** if Apple's manifest rules require a declaration for
the implemented flow. As implemented:

- `NSPrivacyTracking` stays `false`; there are no tracking domains.
- The existing `UserDefaults` required-reason declaration (`CA92.1`) still
  covers everything the app writes there: the active-Household UUID, the
  bootstrap barrier, per-store history tokens, the share-title retry marker, the
  lifecycle-transition record, the upgrade markers, and the reminder hour.
- No new required-reason API is used. There is no file-timestamp, disk-space,
  active-keyboard, or system-boot-time API in the sharing code.
- `NSPrivacyCollectedDataTypes` stays empty on the current reading: the app
  collects nothing to its own servers, and inventory is stored in the user's own
  iCloud account. If the release owner classifies iCloud-stored inventory as
  collected data, add `NSPrivacyCollectedDataTypeOtherUserContent` with purpose
  `AppFunctionality`, linked `false`, tracking `false`.

That last point is the one judgement call, and it is deliberately left to the
release owner rather than guessed at.

## 8. Distribute

Run the existing **TestFlight** workflow (GitHub → Actions → TestFlight → Run
workflow) once step 1 is done, then perform the upgrade and two-account
acceptance checklist on real devices.
