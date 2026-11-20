# Device Offboarding

A native macOS app for Intune administrators. Look up a user by UPN, see their Intune-managed devices and app protection registrations, and offboard them asset by asset: Wipe, Retire, Delete, or MAM selective wipe. Simulation by default, everything runs locally: no server, no account other than your own Entra sign-in, no client secret, and no third-party dependencies.

![Devices](docs/images/devices.png)

*Find the user, pick an action per device. Every asset starts at No action. Replace the screenshots in `docs/images/` with your own.*

> Not affiliated with or endorsed by Microsoft. Microsoft Intune, Entra and Microsoft Graph are trademarks of Microsoft Corporation.

## What it does

- **Search** a user by exact UPN. The identity card (name, UPN, Entra ID) must be confirmed before any device is listed. No fuzzy matching.
- **Discover** the user's Intune-managed devices and app protection (MAM) registrations. They load independently, so a failure in one never hides the other.
- **Choose** an action per asset: **Wipe**, **Retire**, **Delete** record or **No action** for devices, **Selective wipe** or **No action** for MAM. Windows wipes can keep enrollment data and user data.
- **Review** a live page that lists exactly what will be sent. Any change clears your confirmation.
- **Confirm** with an acknowledgement. A plan with a wipe also needs a typed phrase (`WIPE <n>`), and wipes, deletes and selective wipes each get a second confirmation alert.
- **Run** in simulation (nothing can change) or in production (opt-in per user). The app re-checks the user and every asset right before sending.
- **Verify** after the request: for every wipe or retire Intune accepted, the app reads the device back and tells you whether Intune registered the action.
- **Audit** every run in a local JSON Lines file, with an in-app viewer.


## Requirements

- macOS 13 Ventura or later to run the app.
- Xcode to build it (SwiftUI, Swift 5 language mode).
- A Microsoft Entra app registration of your own and an Intune role that allows the actions you want to perform (see below).
- No third-party dependencies.

## Download

Get the latest build from the [Releases page](../../releases), unzip it and move **Device Offboarding.app** to Applications. The build is ad-hoc signed and not notarized, so Control-click the app and choose **Open** the first time, or use **System Settings > Privacy & Security > Open Anyway**. The app does not remove the quarantine flag or change any security setting for you. If you prefer not to run an unsigned build, build it from source.

## Build and run

1. Open `DeviceOffboarding.xcodeproj` in Xcode. No team is needed: the app is ad-hoc signed.
2. Change the bundle identifier (`com.example.deviceoffboarding` is a placeholder) to one you own.
3. Run with ⌘R, or from Terminal:

```bash
swift test                        # core library tests
scripts/build-pkg.sh 1.0          # optional: build/DeviceOffboarding-1.0.pkg
```

To deploy the PKG with Intune, an unsigned package must be added as the **macOS app (PKG)** type, not the managed line-of-business type. Change `identifier` in `scripts/build-pkg.sh` to your own bundle identifier first.

## First launch

No tenant is built in. On first launch, an administrator enters the **Tenant ID** and **Client ID** of their own Entra app registration in **Settings** (⌘,). Until both are valid GUIDs, *Sign in with Microsoft* stays disabled. The IDs are identifiers, not secrets; they are stored in this Mac's preferences.

To pre-configure many Macs, push a configuration profile with the string keys `EntraClientId` and `EntraTenantId` in your app's preference domain (its bundle identifier). Managed values win and the Settings fields become read-only.

## Microsoft Entra app registration

1. Entra admin center > App registrations > New registration. **Single tenant**. Leave the redirect URI empty for now.
2. Authentication > Add a platform > **Mobile and desktop applications**. Add the redirect URI `http://localhost` (exactly that: no port, no path). Entra ignores the port for loopback redirects, so the app can pick a free one.
3. Authentication > Advanced settings > **Allow public client flows**: Yes.
4. API permissions > Add a permission > Microsoft Graph > **Delegated**:
   - `User.Read`
   - `User.ReadBasic.All`
   - `DeviceManagementManagedDevices.Read.All`
   - `DeviceManagementApps.Read.All`
   - `DeviceManagementManagedDevices.PrivilegedOperations.All` (Wipe)
   - `DeviceManagementManagedDevices.ReadWrite.All` (Delete, Retire)
   - `DeviceManagementApps.ReadWrite.All` (MAM selective wipe)
5. Click **Grant admin consent** for the tenant.
6. Copy the **Directory (tenant) ID** and **Application (client) ID** into the app's Settings. Do not create a client secret.

Step-by-step checklist: [`docs/EntraAppRegistration.md`](docs/EntraAppRegistration.md).

## Intune RBAC role

Delegated permissions never exceed what the signed-in admin may do. The admin needs an Intune role that allows reading managed devices and app registrations, and, for the actions they will use, the matching **Remote tasks** (Wipe, Retire, Delete) and app protection selective wipe permissions. A missing role shows as a 403 with a plain explanation.

## Using the app

1. **Sign in** with *Sign in with Microsoft*. The browser opens; the app shows the signed-in admin and tenant in the sidebar.
2. **User**: enter the UPN, check the identity card and confirm it.
3. **Devices**: set an action per device. Windows wipes show *keep enrollment data* and *keep user data*. The page also lists devices that were left out, with the reason, and the last remote actions of each device.
4. **App protection**: one entry per phone or tablet, with model, OS version and Entra device ID. Choosing selective wipe for a phone applies to all of its registrations.
5. **Review**: check the plan. Acknowledge it and, for wipes, type the phrase.
6. **Run** in simulation or switch to production. Before a production run you sign in again in the browser to confirm it is you.
7. **Results**: each action has its own state, so partial success is shown honestly. Open the audit log from here.

The sidebar is disabled while a run is in progress, and the app refuses to quit mid-run.

## Safety design

- **Wipe, Retire and Delete are three separate actions**, never chained, in code, UI, confirmations and logs.
- **Accepted is not done.** Graph answers `204` when a request is accepted, not when the device has been erased. The app reports "submitted" and then checks Intune.
- **No blind retries.** Destructive requests are sent once. A timeout or lost reply is reported as *outcome unknown*.
- **Stale plans are refused.** If the user or a device changes between review and execution, that action is not sent.
- **Devices are identified by Intune ID**, never by name. Duplicates are refused, wipes of non-corporate devices carry an explicit warning, and a pending wipe or retire blocks a second one.
- **At most 5 wipe, retire or delete actions per run.** Selective wipes are not capped.
- **macOS wipes** include a six-digit unlock PIN generated per wipe and shown once on the results screen. It is never written to a log or the audit file.

## Audit log

Every run appends JSON Lines to `~/Library/Logs/DeviceOffboarding/audit-YYYY-MM.jsonl` (file mode 600): timestamp, run ID, simulation or production, admin, tenant, target user, asset, serial, managed device or MAM registration IDs, operation, API call, HTTP status, result and message. A `runStarted` record is written before anything is sent. If the audit file cannot be written, a production run is not started.

## Privacy and security

- OAuth 2.0 authorization code flow with PKCE against Microsoft Entra ID v2.0, as a public client, in your default browser. No embedded web view and no client secret.
- The redirect is `http://localhost:<port>`; the app listens on a free loopback port for that one redirect, then stops. If the macOS firewall asks whether the app may accept incoming connections, allow it: the listener only accepts connections from your own Mac.
- The ID token is validated for audience, tenant and nonce, so only your tenant can sign in.
- Nothing is persisted: the tokens live in memory only, never in the Keychain or on disk. You sign in again after each launch.
- Requests use no redirects and no disk cache. Logging redacts tokens and authorization headers.
- Hardened runtime is on; the app has no entitlements and no third-party code. See [`docs/SecurityReview.md`](docs/SecurityReview.md).

## Known limitations

- Almost everything uses Microsoft Graph **v1.0**. One read-only call is `/beta`: app protection device details (Entra device ID, model, manufacturer). It is isolated in `MAMDeviceDetailsService.swift` and optional. If it fails, the page falls back to one entry per device tag and says so.
- What Intune's raw Graph *delete* does to the physical device is not documented by Microsoft. The portal's Delete sends Retire (or Wipe on corporate Android). Test on a spare device first.
- Check on your tenant that the per-user device path (`/users/{id}/managedDevices`) and the UPN `$filter` work with your permissions. Each is a one-line change if not.
- Intune cannot cancel a pending remote action. Wait for it, or remove a stale record in the Intune portal.
- Tenant limits apply (for example, daily caps on wipes and deletes).
- The app was written without a Mac build in the loop: run the tests and try everything in **simulation first**, then on a **test device**.
- Choosing the right user and devices is still on you: the app cannot know that a device is shared.

## License

See [LICENSE](LICENSE).
