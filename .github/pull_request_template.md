## Summary

<!-- What does this PR change and why? Link the issue / otueke-docs spec. -->

## Type

- [ ] feat
- [ ] fix
- [ ] docs
- [ ] chore / refactor / test / ci

## Checklist

- [ ] Title follows Conventional Commits (`feat: ...`, `fix: ...`)
- [ ] No business rules in the client (payments, inventory, bookings, ticket validation, pricing, permissions stay in the API)
- [ ] Money displayed from API decimal strings (no `double` arithmetic)
- [ ] Timestamps kept in UTC; localised only for display
- [ ] Every mutating request sends an `Idempotency-Key` (UUID)
- [ ] No secrets, keystores, `key.properties`, `.env` or `google-services.json` committed
- [ ] `dart format`, `flutter analyze` and `flutter test` pass locally
- [ ] Tests added/updated
- [ ] Screenshots attached for UI changes

## Notes for reviewers

