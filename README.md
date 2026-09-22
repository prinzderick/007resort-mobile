# 007resort-mobile

Android tablet client for the **007 Resort & Spa Integrated Facility Operations Platform**.

One Flutter app runs on all 18 property tablets. What each tablet shows is
decided by its **device mode**, which the 007 Resort & Spa API assigns through device
registration. The mode is never hardcoded per build.

> Status: **Phase 0 - scaffolding only.** Screens are placeholders; no business
> features are implemented yet.

Architecture, API contracts and decisions live in
[prinzderick/007resort-docs](https://github.com/prinzderick/007resort-docs).

## Modes and tablet allocation

| Mode              | Tablets | Purpose |
|-------------------|---------|---------|
| `attendant`       | 12      | Shared moving-attendant (waiter) tablets. Checked out from Reception per shift: tablet -> staff -> shift -> facility. |
| `supervisor`      | 4       | One each: Restaurant, Indoor Club, Pool Bar, Bush Bar/Event Centre. |
| `sportsEntrance`  | 1       | Scan QR -> API validates -> show a clear result: `VALID`, `USED`, `EXPIRED`, `WRONG FACILITY`, `NOT YET VALID`, `CANCELLED`. |
| `sportsStore`     | 1       | Scan QR -> show purchased/rented entitlement from the API -> record release/return. |
| `unregistered`    | -       | Default until the API registers the device. Shows "Device not registered". |

## Architecture

```
 Android tablet (this app)              Property server
 +---------------------------+  Wi-Fi   +------------------------------+
 | Flutter UI (mode-driven)  | -------> | 007 Resort & Spa API (ASP.NET Core)    |
 | ApiClient  /api/v1/...    | <------- |  - payments, inventory,      |
 | display state only        |  HTTPS   |    bookings, tickets,        |
 +---------------------------+          |    pricing, permissions      |
                                        +------------------------------+
```

- **Thin client.** The API is the single "brain". The app must **not**
  reimplement business rules (payments, inventory, bookings, ticket validation,
  pricing, permissions). It renders what the API returns and sends every
  operational mutation to `/api/v1/...`.
- **Offline:** controlled queueing only - see
  [`lib/core/offline/offline_queue.dart`](lib/core/offline/offline_queue.dart).
- **State management:** intentionally **no package yet** (Riverpod / Bloc /
  etc. is pending the architecture review). Use plain Flutter widgets until
  the decision is recorded in 007resort-docs.

### Layout

```
lib/
  main.dart                 entry point: reads config, builds ApiClient
  app/                      app widget, placeholder router, theme, home
  core/
    config/app_config.dart  --dart-define configuration
    api/api_client.dart     minimal HTTP client (GET /api/v1/system/info)
    device/device_mode.dart DeviceMode enum + API parsing
    offline/                offline queueing design notes
  features/
    device_checkout/        Reception tablet checkout (placeholder)
    attendant/              waiter workflow (placeholder)
    supervisor/             outlet supervisor (placeholder)
    sports_entrance/        QR entrance validation (placeholder)
    sports_store/           QR release/return (placeholder)
test/                       unit + widget tests
```

## Setup

Requirements: Flutter (stable, 3.44+), Android SDK, Java 17+.

```bash
flutter pub get
```

## Run

```bash
# Emulator against a local API on the host (default http://10.0.2.2:5080)
flutter run

# Custom API / environment
flutter run --dart-define=R007_API_BASE_URL=http://192.168.1.10:5080 --dart-define=R007_ENV=dev
# or: cp .env.example .env && flutter run --dart-define-from-file=.env
```

## Test

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
flutter build apk --debug
```

CI (`.github/workflows/ci.yml`) runs format, analyze, test, a debug APK build
and a gitleaks secret scan on every push and PR to `main`.

## Configuration

See [docs/configuration.md](docs/configuration.md) and
[.env.example](.env.example).

| Define                | Default                |
|-----------------------|------------------------|
| `R007_API_BASE_URL` | `http://10.0.2.2:5080` |
| `R007_ENV`          | `dev`                  |

No secrets in dart-defines (they are embedded in the APK). Android signing keys
are never committed.

## Conventions

See [CONTRIBUTING.md](CONTRIBUTING.md). In short: no business rules in the
client, money as API decimal strings, UTC from the API, an `Idempotency-Key`
on every mutating request, Conventional Commits, PRs to protected `main`.
