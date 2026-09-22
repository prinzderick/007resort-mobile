# Contributing to 007resort-mobile

## Branches

`main` is protected; all changes go through pull requests.

| Prefix      | Use for                         |
|-------------|---------------------------------|
| `feature/*` | new functionality               |
| `fix/*`     | bug fixes                       |
| `docs/*`    | documentation only              |
| `chore/*`   | tooling, CI, dependencies       |

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/):
`feat: ...`, `fix: ...`, `docs: ...`, `chore: ...`, `refactor: ...`,
`test: ...`, `ci: ...`. PR titles follow the same format.

## Pull requests

- Target `main`; keep PRs small and focused.
- CI must be green (format, analyze, test, APK build, secret scan).
- Fill in the PR template checklist.

## Client rules (non-negotiable)

1. **No business rules in the client.** Payments, inventory, bookings, ticket
   validation, pricing and permissions are decided by the 007 Resort & Spa API. The app
   displays results and sends operational mutations to `/api/v1/...`.
2. **Money** is received from the API as decimal **strings** and displayed
   as-is (formatting only). Never parse money to `double` for arithmetic; if
   a total is needed, the API provides it.
3. **Time:** the API sends UTC timestamps. Keep them in UTC in memory and
   localise **only for display**.
4. **Idempotency:** every mutating request (POST/PUT/PATCH/DELETE) sends an
   `Idempotency-Key` header with a UUID generated once per user action and
   reused on retry.
5. **Device mode** comes from the API's device registration, never from a
   build flag or local setting.
6. **No secrets** in the repo or in dart-defines: no `.env`, `key.properties`,
   `*.jks`, `*.keystore`, `google-services.json`, tokens or passwords. CI runs
   gitleaks on every push.

## Code style

- `dart format .` (CI fails on unformatted code).
- `flutter analyze` must report no issues (see `analysis_options.yaml`).
- Add or update tests with every change.
- Do not add new dependencies (especially state management) without an
  agreed decision recorded in 007resort-docs.
