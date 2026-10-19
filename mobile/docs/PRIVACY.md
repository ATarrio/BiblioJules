# BiblioJules — Privacy Policy

This policy applies to the BiblioJules mobile app (`com.bibliojules.mobile`).

## Who we are
BiblioJules is an open-source library/catalog application. **BiblioJules runs no online service of its own and stores no user data.** When you use the app in local mode, no account exists and no data leaves your phone. When you enter a server URL, you are connecting to **your own server** (or one you control), not to BiblioJules.

## BiblioJules vs your server — an important distinction

| | BiblioJules (developer/maintainer) | Your server (if you use sync mode) |
|---|---|---|
| Runs a service? | No | Yes — you host it |
| Stores user accounts / passwords? | No | Yes — it holds your users' accounts and passwords |
| Stores catalog data? | No | Yes — whatever you choose to sync |
| Controls account deletion? | No | You / your server administrator do |

**BiblioJules itself does not store any user data, accounts, or passwords.** Any data stored belongs to the server you connect to, which you operate or control. BiblioJules only talks to that server when you explicitly configure and use sync mode.

## What data is collected
**Nothing by BiblioJules.**

- BiblioJules does not create or manage user accounts.
- BiblioJules does not collect analytics, crash reports, advertising identifiers, or usage statistics.
- BiblioJules does not use third-party SDKs that transmit data.

### Data on your device (local mode)
Your library catalog, reading history, notes, and settings remain stored locally on your phone. You can delete them by clearing the app's storage in Android Settings.

### When you connect to a server (sync mode)
The app communicates with **the server URL you provide** over HTTPS (`usesCleartextTraffic="false"` enforces this). The data transmitted is the catalog/book data you choose to sync (e.g., loan status, notes, shelf assignments). **Your server handles authentication, storage, and account management — not BiblioJules.** Your server may store user accounts and passwords; BiblioJules does not see or store them.

## Permissions used

| Permission | Purpose | Data transmitted? |
|---|---|---|
| `CAMERA` | Scan ISBN barcodes to look up books / add to your catalog. | No — image processing is local. You choose whether to sync the result to your server. |
| `INTERNET` | Connect to the server URL you configure for sync. | Only the data you actively sync to that server. No background transmission. |

## Account deletion
BiblioJules has no accounts and stores no passwords. If you use sync mode, account creation, authentication, and deletion are provided by **your server** — that server holds the accounts and passwords, not BiblioJules. Contact your server administrator (or the service that runs your server) for account deletion. If you run local mode only, delete the app's local storage in Android Settings to remove all data.

## Data retention
No data is retained by BiblioJules — the developer neither runs a service nor keeps accounts. Any data you sync is retained according to your server's policy.

## Children's data / COPPA
The app does not target children under 13 and does not seek or knowingly collect data from children. Use requires connecting to an adult-managed server.

## Changes
This policy may be updated when the app is updated. Changes will be noted in the app's release notes (`pubspec.yaml` / Play release notes).

## Contact
For questions about the app or this policy: see the project repository or contact the maintainers via the repository's issue tracker.
