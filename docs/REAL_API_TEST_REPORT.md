# Real-API test report (Android emulator vs the Laravel local node)

Run: 2026-09-23/24. App: `feature/mobile-mvp` debug build (no `R007_MOCK`), Android tablet emulator `r007_tablet`
(Pixel Tablet, API 34). Node: `007resort-api` `integration/mvp` (+ `fix/device-home-facility`), API `http://10.0.2.2:8080/api/v1`,
Reverb `10.0.2.2:8081`, MySQL `r007_local`. Screenshots: `docs/screenshots/sNN_*.jpg` (numbers below).

## Results

| # | Flow | Result | Evidence |
|---|------|--------|----------|
| 1 | Server address -> enrol (fresh code, role Attendant) | PASS (after fixes B1, B2) | s00, s02 |
| 2 | PIN login `wait1`/1234, facility list loaded after login, tablet checkout to Restaurant | PASS | s05 |
| 3 | Tables + catalog from the API, create order, send | PASS. Server refuses sold-out stock (`insufficient_stock`) with a clear message; retry after editing the cart edits the same server draft (B4) | s06, s07, s07b, s08 |
| 4 | Kitchen (`kitchen1` + KDS device token via curl) ACCEPTED -> IN_PROGRESS -> READY | PASS: green "Order ready to serve" banner within ~1.5 s (Reverb push; polling is the fallback), then card shows READY | s09, s37 |
| 5 | Mark served | PASS | s10 |
| 6 | Attendant requests void (no `order.void` permission) | PASS: 202 PENDING_APPROVAL, "Waiting for a supervisor to approve" | s11 |
| 7 | Supervisor tablet (role Supervisor, home Restaurant), login `supervisor1`, approvals badge, approve with PIN | PASS; order becomes VOIDED on the server (DB verified) | s12-s15 |
| 8 | Supervisor live orders | PASS after B5 (was empty) | s16 |
| 9 | Sports Entrance (role Sports Entrance, home SPORTS_ARENA), `supervisor1`, manual "enter token" field (also in release builds) | VALID, then ALREADY USED, EXPIRED, CANCELLED, WRONG FACILITY all verified with real tokens | s18-s23 |
| 10 | Entrance offline | PASS: NO CONNECTION, "ticket NOT checked, do not admit"; nothing guessed; Try again after reconnect -> VALID | s24, s25 |
| 11 | Sports Store (role Sports Store, `storekeeper1`): look up, release rental, return | PASS; duplicate release blocked in the UI and by the server (`409 ticket_used`) | s26-s29 |
| 12 | Offline order (Wi-Fi + data off) | PASS: two orders on two tables saved as PENDING CONFIRMATION, banner "4 actions waiting" | s31, s32 |
| 13 | Restore network: ordered replay | PASS: exactly one server order per queued order (RESTAU-000060/61, lines match), no duplicates (checked in MySQL) | s33 |
| 14 | Access token expiry (`session.access_expires_at` forced into the past) | PASS: silent refresh, no re-login, UI keeps working | s34 |
| 15 | Server stopped then started mid-session | PASS: "Reconnecting... last known data" banner, automatic recovery within ~20 s, realtime socket reconnects | s35, s36 |
| 16 | Idle lock (built with `R007_IDLE_LOCK_SECS=25`), PIN unlock; lock on app restart | PASS | s37b, s38, s09_locked |
| 17 | Sign out / return tablet | PASS (dedicated tablets now always check in, see B7) | - |

## Bugs found and fixed

API (`007resort-api`, branch `fix/device-home-facility`, PR #11 into `integration/mvp`, merged into the running node):
* **A1** device payloads (`register`, `GET /devices/{id}`, list) lacked the home facility, so a device-token-only client called a staff-only endpoint and got 401. Now include `homeFacility {id, code, name, kind}` (+ `mode`, already present). Test + OpenAPI updated.
* **A2** re-using a client line id on a second order (what a retry after a refused send did) returned a **500** (PK violation). Now a `409 line_id_in_use`. Test added.

Mobile:
* **B1** enrolment showed "Something went wrong": `CircularDependencyError` between `apiProvider` and `AppController` in real mode (server URL derived from controller state). Server URL now lives in its own provider.
* **B2** persona is now the server's explicit `mode` (never inferred from facility code); protected endpoints are no longer called before login; the facility list loads after login. Enrol screen has a *Tablet role* selector (sent as `mode`).
* **B3** the "Reconnecting" banner appeared on the server-address screen (probing a placeholder URL) - no probing before a server is set.
* **B4** after a refused send (stock) the server keeps a DRAFT; the retry created a second order with the same line ids (-> A2). The retry now reconciles lines on the same draft and sends.
* **B5** supervisor Live orders was empty on busy outlets: the newest 60 orders were mostly settled. The list now asks the server for unsettled statuses only.
* **B6** Sports Store offered a release action for goods (`kind ITEM`) which the server rejects (`not a rental item`). Goods are shown as "PAID - HAND OVER" and are not selectable.
* **B7** dedicated tablets (supervisor/sports) were not checked in on sign-out after an app restart (checkout record not persisted), blocking the next enrolment with "already checked out". Sign-out now always checks in.
* **B8** unhandled `WebSocketChannelException` when Reverb is unreachable; handled (reconnect with backoff continues).
* **B9** stale "Order ready" banner after the order was served/voided; alerts are pruned on refresh.
* Debug builds show the exception type on "Something went wrong"; launcher icon replaced (was default Flutter); label already "007 Resort & Spa".

## Remaining / notes

* Tables can show "0 orders" while occupied (table occupancy comes from the server; settled orders leave it OCCUPIED) - server-side table release on settle is not the mobile app's concern but looks odd.
* The attendant sees a void result only as the order disappearing/VOIDED on refresh; there is no dedicated "your void was approved" toast yet.
* Emulator camera (virtual scene) cannot scan real QR codes; the manual token field was used. On a real tablet the camera path uses `mobile_scanner` (not exercised here).
* Sample QR tokens in `LOCAL_NODE.md` are single-use: after a demo run re-seed (`local-node.sh seed`) or issue new entitlements.
* Sports Entrance/Store enrol with kind `MOBILE_TABLET` + mode `SPORTS_ENTRANCE`/`SPORTS_STORE`, as in the seed.
* Attendant checkout is refused (409) if the previous holder never returned the tablet; an admin/manager checks it in.

## Owner demo script (about 10 minutes)

Prereqs: node running (`scripts/local-node.sh status`), tablet/emulator can reach `http://<host>:8080` (emulator: `10.0.2.2`).
Codes: `scripts/local-node.sh device-code RECEPTION | RESTAURANT | SPORTS_ARENA | SPORTS_STORE`.

1. Install the debug APK, enter the server address, *Connect*.
2. Enrol "Waiter Tablet 03", code for RECEPTION, role Attendant. Sign in `wait1` / `1234`, check out to Restaurant.
3. Table T5 -> Take order -> Jollof Rice -> Send. Show the server order number and ROUTED lines.
4. As kitchen (curl, or the KDS app): accept -> in progress -> ready. The waiter tablet shows the green READY banner; tap *Mark served*.
5. *Void order* -> reason: shows "Sent to a supervisor for approval".
6. Menu -> Return tablet; *Reset tablet enrolment*; enrol a RESTAURANT code as Supervisor; sign in `supervisor1`/`1234`; Approvals -> Approve (PIN 1234).
7. Sign out; reset; enrol a SPORTS_ARENA code as Sports Entrance; `supervisor1`; enter a fresh token -> VALID, again -> ALREADY USED.
8. Sign out; enrol SPORTS_STORE as Sports Store; `storekeeper1`; scan the rental token -> release racket -> record return.
9. Offline: turn Wi-Fi off, take an order (PENDING CONFIRMATION), turn Wi-Fi on: it is sent automatically, once.
10. Optional resilience: `scripts/local-node.sh restart` while the app is open: banner, then automatic recovery.
