# Entra app registration checklist

Create the registration in your own tenant, then enter its **Application (client) ID** and **Directory (tenant) ID**
(both from the Overview page) in the app: on first launch a Settings sheet opens, later use **Device Offboarding → Settings…** (⌘,).
Both must be GUIDs. They are identifiers, not secrets. The fields are locked while someone is signed in.

To pre-configure many Macs, push a configuration profile (preference domain `com.example.deviceoffboarding`, or your own
bundle identifier if you changed it) with the string keys `EntraClientId` and `EntraTenantId`. Managed values win and the
Settings fields become read-only. In Intune this is a custom profile or a property-list (preference file) payload.

1. **Authentication → Add a platform → Mobile and desktop applications**, then add the custom redirect URI
   `http://localhost` (exactly that: no port, no path, no trailing slash). The app listens on a random free local port
   and Entra accepts `http://localhost` for any port. The macOS/iOS platform with the `msauth.…` redirect is no longer used and can be removed.
2. Authentication → **Allow public client flows: Yes**. Do NOT create a client secret or certificate.
3. Supported account types: **Single tenant**.
4. **API permissions → Microsoft Graph → Delegated**, then **Grant admin consent**:
   - `User.Read`
   - `User.ReadBasic.All` (replaces `User.Read.All`; remove the old permission and its consent if it was added)
   - `DeviceManagementManagedDevices.Read.All`
   - `DeviceManagementApps.Read.All` (added in Phase 5; after adding it, grant admin consent again and sign in again in the app)
   - `DeviceManagementManagedDevices.PrivilegedOperations.All` (Phase 8, MDM Wipe: the v1.0 `wipe` page lists it as the only delegated permission; after adding it, grant admin consent and sign in again in the app).
   - `DeviceManagementManagedDevices.ReadWrite.All` (Phase 9, Delete from Intune: the only delegated permission on the v1.0 delete page; grant admin consent and sign in again)
   - `DeviceManagementApps.ReadWrite.All` (Phase 10, MAM Selective Wipe: the only delegated permission on the v1.0 page; the app also requests `DeviceManagementApps.Read.All` separately, so keep both consented; grant admin consent and sign in again)
5. The signed-in admin also needs an Intune/Entra role that allows the action (e.g. Intune Administrator or a custom RBAC role). Delegated permissions never exceed what the admin can do.
