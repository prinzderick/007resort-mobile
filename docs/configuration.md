# Configuration

Build-time configuration uses `--dart-define` (or `--dart-define-from-file`).
See [`.env.example`](../.env.example). Everything else (server address, device
enrolment, device role) is entered/assigned at runtime.

| Define                | Default   | Description |
|-----------------------|-----------|-------------|
| `R007_MOCK`           | `false`   | `true` = run against the built-in Mock API (seeded data, simulated kitchen/approvals/scans). |
| `R007_API_BASE_URL`   | *(empty)* | Preset server address without `/api/v1`. When empty the tablet asks for it on first launch (verified against `GET /api/v1/system/info`). |
| `R007_ENV`            | `dev`     | `dev`, `staging` or `production`. |
| `R007_IDLE_LOCK_SECS` | `300`     | Inactivity before the attendant/supervisor tablet locks (PIN to resume). |
| `R007_REVERB_KEY/PORT/SCHEME` | `r007-local` / `8081` / `ws` | Fallback only; the app reads host/port/key/scheme from `/system/info -> realtime`. |

Runtime state kept on the tablet (Android Keystore-backed secure storage): server
address, device id + **device token**, staff session tokens, checkout, the queue
encryption key. The encrypted offline queue is an app-private file.
dart-define values are compiled into the APK and are **not secret**.

Cleartext HTTP is enabled in the Android manifest because the Local node is on
the property LAN (`http://192.168.x.x`). Use HTTPS for the Cloud node.

## Device role resolution (assumed)

The contract's `Device` has a `kind` and `homeFacilityId` but no "mode" field. The app derives the mode:

| Device `kind` | `homeFacilityId` / facility `kind` | Mode |
|---|---|---|
| `MOBILE_TABLET` | none | Attendant (shared waiter pool; checkout picks the facility) |
| `MOBILE_TABLET` | facility of kind `SPORTS_STORE` | Sports Store |
| `MOBILE_TABLET` | facility of kind `SPORTS_ENTRANCE` | Sports Entrance |
| `MOBILE_TABLET` | any other facility | Supervisor (dedicated tablet) |
| `ENTRANCE_SCANNER` | - | Sports Entrance |
| anything else / unresolved | - | "Tablet role not resolved" (never unlocks a UI) |

Dedicated tablets (supervisor, sports) are checked out to their home facility automatically at sign-in and checked in on sign-out.

## Contract areas assumed or not yet covered

Reconciled with `api/openapi/v1.yaml`, `api/realtime.md`, `api/mvp-flows.md` (as of the version in `007resort-docs`).
Items below are what the contract does **not** pin down or the MVP does not use yet:

* **Device mode** (above) - needs confirming, ideally an explicit `mode`/`role` on `Device`.
* **Shifts**: the contract has `shiftId` on checkout but no endpoint to list a staff member's shifts, so the app checks out **without** a shift.
* **Modifiers**: the catalog contract has no modifier groups. The UI supports them (mock only); selections are sent as line `notes`.
* **Tabs**: the app opens tabs for named customers (bars) and attaches orders via `tabId`; it does not settle tabs/payments (cashier role, out of scope for tablets). "Add another order to an open tab" = new order with the table's/tab's `tabId`.
* **Tables**: `POST /tables/{id}/open` is called on first order for a free table; `openOrderIds` are not used (orders are matched by `tableId`/`tabId`).
* **Void by staff lacking `order.void.execute`**: the app routes them through supervisor PIN step-up (`X-Step-Up-Token`, flow A2 3b). Whether the server accepts a step-up token from a caller without the execute permission is assumed yes; if not, the server returns `403 permission_denied` and the UI shows it.
* **Line-level void**: not in the contract (order-level void only). Comps/discounts are line adjustments.
* **Approval decision**: `POST /approvals/{id}/decision` with `stepUpToken` from `POST /auth/staff/step-up` (`permission`, `entityType`, `entityId` filled from the approval).
* **Sports Store `ITEM` (goods) release**: item has no `rentalStatus`; the app treats `quantityRedeemed < quantity` as "not yet handed over" and lets the server decide (409 on duplicates).
* **Sports facility for `redeem`**: `facilityId` sent = the tablet's checked-out/home facility.
* **min client version**: `GET /system/info -> minClientVersion.mobile` is read but the "update required" screen is not yet enforced.
* **Realtime channel auth path**: `POST /api/v1/broadcasting/auth` (as documented); `private-site.status` liveness (75 s) is not used - the app polls every 10 s instead.
* **`GET /orders`** returns summaries without lines: the app fetches `GET /orders/{id}` for each open order (bounded to the 40 most recent) to show per-item status.
