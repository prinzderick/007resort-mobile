# 007resort-mobile

Android tablet client for the **007 Resort & Spa Integrated Facility Operations Platform**.

One Flutter app runs on all 18 property tablets. What a tablet shows is decided
by the **device** it was enrolled as (device kind + home facility, assigned on
the server) and by the **permissions of the signed-in staff member** - never by
a per-role build.

> Status: **MVP demoable.** Every flow below runs against a built-in Mock API
> (`--dart-define=R007_MOCK=true`) and against the real Laravel API
> (contract: [`007resort-docs/api/`](https://github.com/prinzderick/007resort-docs)).
> Both use the exact same UI and code path; only the `R007Api` implementation differs.

## What is in the app

| Mode | Who | What it does |
|------|-----|--------------|
| **Attendant** (shared waiter pool, 12) | Waiters | Sign in (staff no. + PIN, password or NFC-card UID), **check out the tablet** to a facility for the shift, live tables + customer tabs, open table/tab, browse the per-facility catalog, cart, **send order** (locks lines), per-item preparation status, **READY notification** (sound + haptic + banner), mark served, add more orders to an open tab, void / discount / comp (approval route), return tablet at end of shift. |
| | | **Waiter payment collection** (see below): order card shows the bill state, **Take payment** at the table (cash / card machine / transfer / pay link, split across tenders), a clear status per collection, **My cash** and hand-over to the cashier. |
| **Supervisor** (dedicated, 4) | Outlet supervisors | Live monitor of facility orders, tables & tabs, **approvals queue** (approve / reject with reason, PIN step-up), can void / discount directly when permitted. |
| **Sports Entrance** (1) | Gate | Camera QR scan -> `redeem` -> ONE full-screen unmistakable result (VALID / ALREADY USED / EXPIRED / WRONG FACILITY / NOT YET VALID / CANCELLED) with haptics + sound, scan history. **Never guesses offline**: shows NO CONNECTION. |
| **Sports Store** (1) | Store | Scan entitlement QR -> exactly what was paid/rented -> **Release** items / **Record return** (OK / damaged / lost). Duplicate release is blocked by the server and surfaced verbatim. |

Cross-cutting: server-URL entry + saved config, device enrolment with a
registration code (device token in Android Keystore-backed secure storage),
connectivity/outbox banner, idle **auto-lock** (PIN to resume), permissions-driven
UI (hide/disable what the staff cannot do - the server still enforces), large
touch targets and tablet split layouts.

### Waiter payment collection (owner rule)

The cashier prints the bill; the waiter takes a portable card machine / cash / transfer link to the table and
**collects, but can never mark a bill paid**. Everything a waiter collects by hand is **PENDING** until the cashier
verifies it (or auto-confirmed when the provider - Paystack pay link / per-bill transfer account - confirms).
Contract: `007resort-api` `docs/WAITER_COLLECTION.md` + OpenAPI (`x-additive`).

* **Order card**: `Bill not printed yet` -> (`bill.print`) **Print bill** -> `Bill printed, awaiting payment` with server
  figures (amount due / confirmed / pending cashier / remaining). A printed bill freezes the order (void/discount hidden).
* **Take payment sheet** (`payment.collect`): tender picker (big targets), amount pre-filled with the server's remaining,
  **Cash** (received + change), **Card machine** (manual bank POS: approval code, last 4, slip/RRN - a future integrated
  terminal only adds `terminalId` and a *Waiting for machine...* state), **Transfer** (bill's own account, or a customer
  bank reference = manual record), **Pay link** (QR + link, `Waiting for payment...` -> **PAID**). Statuses per
  collection: *Pending cashier confirmation* / *Confirmed* / *Rejected* (with the cashier's reason) / *Waiting for
  payment* / *Pending sync*.
* **Idempotent + duplicate-tap safe**: one client UUIDv7 `id` + `Idempotency-Key` per on-screen attempt; the button
  is disabled in flight; ambiguous failures (5xx/timeout) retry the SAME attempt.
* **Live**: realtime `bill.printed`, `payment.collected/confirmed/rejected`, `cash-handover.received` are hints -> board
  reload; the 10 s poll is the fallback. For a pay link / transfer the poll also asks the server to
  `GET /payments/paystack/verify/{ref}` (a local node cannot receive the Paystack webhook).
* **Cash policy** (`GET /staff/{id}/collection-policy`, facility rule overridden per staff): when cash holding is not
  allowed the **Cash** tender is shown disabled with *Cash goes to the cashier* and **My cash** is hidden; otherwise
  My cash shows cash in hand vs the limit (warning near it), `cash_limit_exceeded` forces a *hand over first* prompt,
  `cash_holding_not_allowed` disables Cash. Re-read on login/checkout, every ~minute, and when a sheet opens.
* **My cash**: cash in hand, limit, pending, today's collections, **hand over to cashier** (declared amount; the
  server returns `PENDING_RECEIPT`, then the cashier's count -> *Received / SHORT / OVER* with the variance).
* **Offline**: only manual **cash / card-machine records** are queued (client id, encrypted queue, marked *Pending
  sync*, never shown as confirmed; already-saved amounts are not offered again). **Pay link / transfer, bill print
  and hand-over need the network** and say so.
* No local money math beyond display (remaining/change preview); the server validates amounts (`over_collection`).

### Offline resilience (spec / architecture 13)

* Only **order creation** is queued (`open table` -> `create order` -> `send order`), each
  with a **client-generated UUIDv7 id** and a persisted **Idempotency-Key** that is re-sent unchanged on replay.
* Queue is **AES-256-GCM encrypted at rest** (key in Keystore-backed secure storage), **ordered** (one in flight),
  **bounded** (50 actions / 30 minutes; beyond that new orders are refused with "reconnect" instead of piling up
  unverifiable state).
* Orders made offline show **PENDING CONFIRMATION** until the server confirms; server rejections are shown
  (banner -> Review), never silently dropped.
* Also queued: a waiter's manual **cash / card-machine collection record** (never a settlement).
* **Never queued**: ticket validation/redeem, release/return, void/discount/approvals, bill print, pay link/transfer, hand-over, login/step-up. These need a
  live, authoritative answer and show a connectivity error instead.
* Catalog is cached for offline browsing. Realtime is a hint channel only: 10 s polling + reload on reconnect.

## Architecture

```
 UI (features/*)  --Riverpod-->  controllers/services (core/state)  -->  R007Api  (the ONE seam)
                                                                          |-- HttpR007Api  (dio, /api/v1, ETag/If-Match, refresh, problem+json)
                                                                          '-- MockR007Api  (seeded data, simulated KDS/approvals/scans)
 Realtime: PusherClient (Pusher protocol / Laravel Reverb) with backoff, eventId de-dupe, reload-on-reconnect
 Offline:  OfflineQueue (encrypted file) + OutboxController + connectivity probe
```

Decisions (recorded here; none are architecture-level enough for an ADR):

* **Riverpod** (`flutter_riverpod` 2.x) for state, **go_router** for navigation with a single pure
  `baseRouteFor(AppState)` redirect (unit-tested) deciding which screen family a device/staff state may see.
* **dio** for HTTP; **flutter_secure_storage** for device token, session, queue key; **mobile_scanner** for QR;
  a small in-repo **Pusher-protocol client** on `web_socket_channel` (no native plugin, reads host/port/key from
  `GET /system/info -> realtime`).
* Offline queue = one AES-GCM (`encrypt`) encrypted file rather than SQLite: the queue is capped at 50 small records,
  so a database adds nothing but a native dependency.
* The client **never computes prices, tax or permissions**. Order lines are sent without prices; totals shown are the
  server's. The cart shows a clearly labelled *estimate* (display only, exact decimal arithmetic on strings).

### Layout

```
lib/
  main.dart                 entry: loads persisted state, ProviderScope
  app/                      app widget, go_router, shell (connectivity banner, demo strip, idle lock), theme
  core/
    api/                    R007Api (interface, DTOs, errors), HttpR007Api
    mock/                   MockR007Api + seeded demo data
    models/                 wire models (contract v1)
    state/                  app state, connectivity, outbox, board (live facility view), approvals, sports, cart
    offline/                encrypted bounded ordered queue
    realtime/               Pusher/Reverb client
    storage/ util/ config/  secure KV store, money display helpers, dart-define config
  features/
    bootstrap/ auth/        server URL, enrolment, login, tablet checkout, lock screen
    attendant/ supervisor/ sports/ shared/
test/
  unit/                     queue, HTTP client (contract mapping), money
  widget/                   full flows on the Mock API (attendant, offline, supervisor, sports, permissions)
  integration/              real-API test (skipped unless R007_API_BASE_URL is set)
```

## Run

Requirements: Flutter (stable 3.44+), Android SDK, JDK 17+.

```bash
flutter pub get

# 1) Instant demo, no backend needed (built-in Mock API):
flutter run --dart-define=R007_MOCK=true

# 2) Against a real node (server address is typed on the tablet the first time,
#    or preset here):
flutter run
flutter run --dart-define=R007_API_BASE_URL=http://192.168.1.10:8080
```

Build APKs:

```bash
flutter build apk --debug                                   # real API
flutter build apk --debug --dart-define=R007_MOCK=true      # demo APK (mock)
```

CI builds both and uploads them as the `007resort-mobile-debug-apk` artifact.
Step-by-step tablet demo: [docs/DEMO.md](docs/DEMO.md).

### Mock demo credentials (only with `R007_MOCK=true`)

| Enrolment code | Tablet becomes |
|---|---|
| `ATT-2026` | Attendant (waiter pool) |
| `SUP-2026` | Supervisor (Restaurant) |
| `ENT-2026` | Sports Entrance |
| `STO-2026` | Sports Store |

| Staff | PIN | Notes |
|---|---|---|
| `amaka` (1001) | `1234` | waiter; can request void/discount (needs supervisor approval); NFC `04A1B2C3` |
| `chidi` (1002) | `2345` | trainee; no void/discount permission (supervisor-PIN route only) |
| `ngozi` (2001) | `9999` | supervisor; approves; NFC `04D4E5F6` |
| `sports1` (3001) | `5555` | Sports operator |

The demo strip at the top has a **"Simulate Wi-Fi drop"** switch, and Sports screens show tappable demo QR codes.

## Test

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test                       # unit + widget (mock) tests; integration test skips
flutter build apk --debug

# Waiter-collection integration test (needs the API with docs/WAITER_COLLECTION.md; leaves 1 printed bill behind):
R007_API_BASE_URL=http://127.0.0.1:8095 R007_DEVICE_ID=<uuid> R007_DEVICE_TOKEN=<token> R007_STAFF_ID=wait1 R007_STAFF_PIN=1234 \
  flutter test test/integration/real_collection_test.dart

# Real-API integration test (follows api/mvp-flows.md Flow A):
R007_API_BASE_URL=http://127.0.0.1:8080 R007_REG_CODE=... R007_STAFF_ID=S-0042 R007_STAFF_PIN=4821 \
  flutter test test/integration/real_api_test.dart
```

## API integration status and assumptions

Verified against a locally running Laravel node (`feature/api-org-devices` + `feature/api-catalog-orders`, dev demo seed,
one throwaway merge): system info, device reuse by token, PIN login, facility tree, checkout / check-in, catalog, tables,
create (client UUIDv7) -> idempotent replay -> send (`If-Match`) -> list, void -> 202 approval -> supervisor step-up +
decision -> VOIDED, and inline `X-Step-Up-Token` void. **Not yet verified against a real server:** Reverb realtime,
Sports (entitlements/redeem/release/return - no server module yet), tabs, serve after KDS READY.

See "Contract areas assumed" in [docs/configuration.md](docs/configuration.md#contract-areas-assumed-or-not-yet-covered).

## Conventions

See [CONTRIBUTING.md](CONTRIBUTING.md). In short: no business rules in the client, money as API decimal strings, UTC
from the API, an `Idempotency-Key` on every mutating request, Conventional Commits, PRs to protected `main`.
