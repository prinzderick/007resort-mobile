# Live demo on a tablet over Wi-Fi

Two ways to demo. **A** needs nothing but the tablet; **B** shows the real
system. Allow ~15 minutes for the full walk-through.

## 0. Get the APK onto the tablet

1. Download the CI artifact **`007resort-mobile-debug-apk`** (GitHub Actions run of the PR/branch).
   It contains two files:
   * `007resort-mobile-demo-mock.apk` - built-in demo server, no backend needed (**Demo A**)
   * `007resort-mobile-debug.apk` - talks to the real Laravel node (**Demo B**)
2. Copy to the tablet (USB, Drive, or `adb install -r <file>.apk`). Allow "install unknown apps" once.
3. First launch: allow the **camera** when the Sports screens ask.

For several tablets at once (waiter + supervisor + sports) use **Demo B**; with the mock every tablet has its own
private in-memory server, so approvals cannot cross tablets (a single tablet can still play both roles - see A6).

---

## Demo A - mock server (single tablet, no network)

Install `007resort-mobile-demo-mock.apk`. A purple **DEMO MODE** strip sits at the top with a
**Simulate Wi-Fi drop** switch.

### A1. Waiter takes an order
1. **Enrol**: name `Waiter Tablet 03`, code `ATT-2026` -> *Enrol tablet*.
2. **Sign in**: staff `amaka`, PIN `1234` (or type `04A1B2C3` in the NFC field to show card sign-in).
3. **Check out** the tablet: choose **Restaurant** -> *Check out tablet*.
4. Tap **T1** -> **Take order**. Categories on the left; add *Beef Suya* twice, open **Mains**, add *Jollof Rice*
   (pick an extra) and *Grilled Steak* (doneness is required). The cart shows an **estimated** total; the server sets the real one.
5. **Send order**. The order card shows the server number, real total and each line as ROUTED.
6. Within ~10-20 s lines move ACCEPTED -> IN PROGRESS -> **READY**: a green banner **"Order ready to serve"** appears
   with sound + vibration. Tap **Mark served**.
7. Tap T1 -> **Add order to tab** to add a second order to the same table.

### A2. Bar customer (no tables)
Sign out, check out to **Pool Bar** -> **New** -> `Mr Bello` -> add beers -> Send. The customer appears under
"Customers / tabs".

### A3. Offline resilience (the important one)
1. Tap a free table -> **Take order** -> add items.
2. Flip **Simulate Wi-Fi drop** on. A red **Reconnecting...** banner appears.
3. **Send order**: toast "saved and will be sent automatically"; the order shows **PENDING CONFIRMATION**.
   (Sports scanning, void/discount and approvals refuse to guess while offline.)
4. Flip the switch off: within seconds the banner says *Sending 3 queued actions...*, then the order becomes a normal
   SENT order with a server number.

### A4. Supervisor approval
1. As Amaka open an order -> **Void order** -> reason -> "Sent to a supervisor for approval"; the order shows
   *Waiting for a supervisor to approve*. Also try **... -> Discount / comp** on a line.
2. Menu -> **Sign out (keep tablet)**. (To act as supervisor on the same tablet: sign in screen -> *Reset tablet
   enrolment*, then enrol `SUP-2026`; mock state persists while the app stays open.)
3. Sign in `ngozi` / `9999`. **Approvals** tab -> Approve (enter PIN `9999`) or Reject (reason + PIN). Live monitor shows
   the effect; **Tables & tabs** shows occupancy.
4. Trainee route: `chidi` / `2345` has no void permission -> the button reads **Void (supervisor)** and asks for a
   supervisor's number+PIN (`ngozi` / `9999`).

### A5. Sports Entrance
Reset enrolment -> code `ENT-2026`, device type **Sports Entrance scanner** -> sign in `sports1` / `5555`.
Point the camera at any QR containing e.g. `R007-DEMO-VALID-1` (generate one with any QR site) **or tap the demo chips**:
VALID (green), scan again -> **ALREADY USED** (red), EXPIRED, WRONG FACILITY, NOT YET VALID, CANCELLED. Turn the Wi-Fi
switch on and scan: **NO CONNECTION** - it never shows a guessed result.

### A6. Sports Store
Reset -> `STO-2026` -> sign in `sports1`. Chip **Court + 2 rackets + water** shows exactly what was paid/rented.
Tick *Tennis racket* -> **Release selected**; it can no longer be selected, and forcing a second release shows the
server's *already released* message. Tick it again -> **Record return**.

### A7. Waiter takes payment at the table (mock)
Sign in `amaka` / `1234` (attendant tablet, Restaurant), take an order (T1, *Beef Suya* x2 = 7,000) and wait for READY (or not).
1. The order card says **Bill not printed yet** -> **Print bill** -> blue *Bill printed, awaiting payment* with the server's
   amount due / confirmed / pending cashier / remaining. (The mock lets the waiter print; in production the cashier usually does.)
2. **Take payment**: *Cash* - type an amount and the cash received, **Change to give** shows; **Record cash collected**.
   It is now *Pending cashier confirmation* - the bill is NOT paid. ~12 s later the demo "cashier" confirms it (green
   *Payment confirmed* alert); when everything is confirmed the order leaves the board.
3. Split it: *Card machine* for the rest - approval code + last 4 + slip. Approval code **0000** is rejected by the demo
   cashier after ~12 s: red *Payment rejected by the cashier* alert and the reason on the collection.
4. *Pay link* (or *Transfer* with the amount only): QR + short link and **Waiting for payment...**; ~12 s later it flips to
   a green **PAID** (provider confirmation). *Transfer* with a bank reference records a manual pending transfer instead.
5. Offline: flip **Simulate Wi-Fi drop**; *Transfer* / *Pay link* show *Needs a connection*; a **Cash** record is saved as
   *Pending sync* (the order itself stays confirmed) and is sent when the Wi-Fi is back. Bill print / hand-over need the network.
6. **My cash** (wallet icon): cash in hand vs the limit (mock: NGN 10,000; a warning at 80%, a forced *hand over first*
   prompt when a cash collection would exceed it), **Hand over to cashier**: declared amount -> *waiting for the cashier to count it*
   -> a few seconds later *Received* (a declared amount ending in **.50** is counted 100.00 short, to show the variance).
7. Policy: sign in `ngozi` / `9999` on the attendant tablet - she has a *staff override that denies cash holding*: the
   **Cash** tender is disabled with *Cash goes to the cashier* and there is no My cash icon.

Screenshots: `docs/screenshots/s40_*` ... `s54_*` (mock) and `r01_*` ... `r11_*` (real API).

---

## Demo B - real system over Wi-Fi

Prerequisites: the Local node is running and reachable from the tablet (`http://<server-ip>:<port>`), seeded with
staff, facilities, catalog, tables and a device registration code (from the admin UI: **IT -> Devices -> new registration code**),
plus a Reverb server (ports/keys come from `GET /api/v1/system/info -> realtime`).

1. Put the tablet on the property Wi-Fi. Quick reachability check in the tablet browser: `http://<server-ip>:<port>/api/v1/system/info`.
2. Install `007resort-mobile-debug.apk`. On first launch enter the **server address** -> *Connect* (verified against `/system/info`).
3. **Enrol** with a one-time registration code (`scripts/local-node.sh device-code <FACILITY>` on the server, or the admin UI).
   Pick the **Tablet role** (Attendant / Supervisor / Sports Entrance / Sports Store): it is sent as `mode` and the server
   returns it (with the `homeFacility` summary), so the UI persona always comes from the server. Suggested home facility per code:
   waiter pool = RECEPTION, supervisor = RESTAURANT (or its outlet), entrance = SPORTS_ARENA, store = SPORTS_STORE.
   Full step-by-step, with screenshots: `docs/REAL_API_TEST_REPORT.md`.
4. Repeat the Demo A flows with real staff (staff number + PIN or NFC card). Run a second tablet as the **KDS / supervisor**
   and move tickets ACCEPTED -> IN PROGRESS -> READY: the waiter tablet raises the READY alert within a second.
5. Sports: issue a booking at Reception (POS), show the entitlement QR to the Entrance and Store tablets.
6. Offline: switch the tablet to airplane mode with Wi-Fi off (or block the server) to show queueing; restore to show replay.
7. Waiter collection (needs the API with `docs/WAITER_COLLECTION.md`): the waiter tablet must be **checked out**; the facility
   takes payment after service so the order must be SERVED first. Waiter cash holding is **off by default** (Cash shows
   *Cash goes to the cashier*): IT enables it per waiter with `PATCH /staff/{id}/collection-policy {"cashHolding":"ALLOW","cashLimit":"6000.00"}`
   or the facility rule `waiter_cash_holding`. A cashier confirms/rejects with `POST /payments/{id}/confirm|reject`
   (cash needs an open cash session) and receives a hand-over with `POST /cash-handovers/{id}/receive`; the tablet reacts live.

### If something does not work
* *Cannot reach ...* on the address screen: wrong IP/port, tablet on guest Wi-Fi, or server firewall.
* Enrolment `422`: registration code already used/expired - issue a new one.
* *Tablet role not resolved*: the server returned no/unknown `mode` for this device. Use *Reset tablet enrolment* and re-enrol.
* *This device is already checked out*: someone did not return the tablet; an admin checks it in (`POST /devices/{id}/checkin`).
* No READY sound but banner works: check tablet volume; realtime falls back to 10 s polling automatically.
* Camera black: grant the camera permission, or use the code field / a handheld scanner (keyboard wedge).
