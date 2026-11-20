# Safety and security review (code review, nothing was compiled or run against a tenant)

Goal: the tool itself must not be able to wipe or delete the wrong thing. Only a human decision should.

## Guarantees that were checked in the code
- Nothing destructive is selected by default. Every asset starts at No Action; Wipe, Delete and Selective Wipe are separate actions and nothing chains one into another.
- At most 5 destructive actions per run and no asset twice, enforced in the confirmation policy, the review UI and again at the top of the executor (before the session check).
- Before each request: identity re-read (`PlanValidator`), then per asset a fresh read compared with the reviewed fingerprint (same user id, serial, name; or the same registration ids). Any difference sends nothing for that asset.
- Exactly one request per operation, never retried; a lost reply or 5xx is `outcomeUnknown`, never "failed" and never repeated. Delete is followed by one read, not a second delete.
- A 204 on wipe or selective wipe is "submitted", never "erased".
- Double submission is blocked (`isBusy` is set synchronously on the main actor; the sidebar is disabled during a run).
- Production is opt-in per user and drops back to simulation on user change or sign-out. The executor is chosen from the mode stored in the reviewed plan, not from the live toggle.
- Ids placed in URL paths are validated; query values are strictly percent-encoded; paging links to another host or scheme are refused.
- No client secret, tokens only in memory, ID token audience/tenant/nonce validated, state and PKCE on the loopback redirect (loopback interface only), tokens redacted from logs.

## Findings fixed in this review
1. Id check could be bypassed by a trailing newline (`$` in a regex matches before it). Now one shared character-set check (`GraphID`), max 64 chars. Not exploitable before (the URL would have failed to build) but it was a weak guard.
2. A sign-out or user change during the final re-read of a device could still let the request go out. A last cancellation check now sits immediately before each wipe, delete and selective wipe.
3. Redirects were followed and responses could be cached on disk. The network session is now ephemeral (no cache, no cookies) and refuses every redirect, so the bearer token and a destructive request can never be forwarded anywhere.
4. A production run could start even if the audit log was unwritable. Production now fails closed: no audit record written before the run, no run. Simulation is unaffected. The audit folder is mode 700 and records also carry the administrator's Entra object id.
5. Wiping a device that is not corporate-owned only showed the ownership in small print. The second confirmation now adds "NOT CORPORATE-OWNED" to that line (also when ownership is unknown).

## Second review: findings fixed
1. A `Retry-After` header of `nan`, `inf`, a negative number or a huge value parsed as a number and reached `UInt64(...)` in the sleep, which traps (app crash). It is now ignored unless finite and non-negative, the sleep is clamped, and a wait longer than 60 s is reported as throttling instead of being slept.
2. A sign-out or user change while the audit record was being written could still open the Results page and let the run continue to the executor. The run now stops there (nothing had been sent).
3. A sign-out while a token refresh was in flight stored the new tokens in memory afterwards. They are now dropped.
4. Two devices with the same name in one run produced the same audit row id (the stored time has whole-second precision). The id now includes the device or registration ids.
5. Paging links must now also have no custom port and no embedded credentials, not just the right host.
6. A stale comment said selective wipe exists only in /beta; Microsoft Learn lists it in v1.0 (checked again).

## Third review: findings fixed
1. After a production run, Back to selection kept production mode AND the earlier Wipe/Delete choices. The same device could be selected again with one more round of confirmations, or a deleted device left the plan blocked. After a production run the choices are now cleared (all No Action), the mode returns to simulation, and the device and app lists are reloaded. After a simulation nothing changes, so you can still switch to production with the same choices.
2. Quitting the app (Cmd-Q) between sending a request and writing its audit record left an action with no recorded outcome. Quit is now refused while a run is validating or executing; a message explains why.
3. `scripts/build-pkg.sh` now rejects a version argument with characters other than letters, digits, dot, dash and underscore (it ends up in file names and build settings).

## Fourth review: findings fixed
1. Token refresh was tied only to "someone is signed in". If you signed out and back in (possibly as another admin) while a refresh was in flight, the old account's refreshed tokens could be stored under the new session, and a failed old refresh could sign the new session out. Each refresh is now bound to the session that started it; a changed session discards the result and is never cleared by it.
2. `scripts/build-pkg.sh`: an invalid version is now also written to the log file.

## Identity check before production runs
Every production run needs a fresh interactive sign-in (`prompt=login`) by the same Entra account (object id + tenant) that is signed in. Protects against someone using an unlocked Mac with the app open. It does not protect against a stolen admin password plus MFA: for that, use Intune Multi Admin Approval for wipe/retire/delete (a second admin approves each action). The app does not yet handle the approval response Graph returns when that is on (HTTP 412 with `x-msft-approval-code`); it would show the action as failed.

## Fifth review: changes
1. Paging guard: a list that returns the same nextLink again, or more than 200 pages, now stops with a clear error instead of looping (and growing memory) until the app is quit.
2. HTTP 412 from a write is explained as a probable Multi Admin Approval requirement instead of a bare "HTTP 412".
3. After the browser sign-in (normal or the identity check before a production run) the app comes back to the front.
4. The splash timer runs as a main-actor task instead of a DispatchQueue closure (safer with newer Swift concurrency checks).
5. The audit page and the audit reader shared two copies of the same file-reading code; one copy was removed.
6. Action descriptions: Retire shortened; Delete now states what Microsoft documents (for Apple and Windows devices it also sends a Retire).
Considered, not changed: reading devices in parallel during discovery. It would save about a second for a user with many devices but makes request order non-deterministic in a tool where predictability matters more.

## App protection per phone (beta details, MAM cap)
- New beta read: `GET /beta/users/{id}/managedAppRegistrations`, only for `azureADDeviceId`, `deviceModel`, `deviceManufacturer`. It goes through the same `GraphClient` (same token rules, paging links must stay on graph.microsoft.com, no retries of writes because it never writes). Details are matched to v1.0 registrations by id and can never add, remove or reassign a registration. Failure is non-fatal and visible.
- Nothing destructive depends on beta: plans, fingerprints, the re-read before sending and the wipe call itself are v1.0 and per device tag, exactly as before.
- Merging is conservative: a tag joins a phone only if all its registrations report one identical Entra device ID. A wrong merge would only group display; Review still lists every request and its app group, and the confirmation lists every request.
- The per-run cap (5) now applies to Wipe, Retire and Delete only, at the administrator's request. Selective wipes are uncapped: they remove app data only, and one user's apps can span many tags. Duplicate assets are still refused across the whole plan.
- If a reload regroups a phone after a choice, the phone shows a "choose again" warning instead of hiding a partial selection.

## Second review: recommendations not changed
- Hardened runtime is now ON (ENABLE_HARDENED_RUNTIME = YES, no entitlements, works with ad-hoc signing). It stops other processes of the same user from injecting code into the app that holds the tokens. Not built here: after building, check `codesign -dv --verbose=2 "Device Offboarding.app"` shows `flags=0x10002(adhoc,runtime)` and that sign-in still works.
- Logs use `.public` privacy, so the administrator UPN, tenant id and device ids are readable in Console.app by any admin of the Mac. No tokens, no target UPN.

## Residual risk that only a human can remove
- Choosing the right user and the right devices. The identity card, ownership and serial number are shown at every step, but the tool cannot know that a device is shared or that a colleague still uses it.
- What the raw Graph DELETE does to the physical device is not documented by Microsoft (the portal's Delete sends Retire, or Wipe on corporate Android). Test on a spare device first.
- The 5-action limit is per run, not per day. Tenant limits: 1,000 deletes and 500 wipes per day.
- The package is ad-hoc signed and not notarized, as requested. Its integrity depends on how it is distributed; compare the SHA-256 of the PKG before deploying.
- The administrator's own Intune role decides what Graph allows (delegated permissions). Use a role that is limited to the needed actions.
