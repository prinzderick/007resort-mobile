// Offline behaviour - controlled queueing (design notes, no implementation).
//
// The Otueke API is the single authority for payments, inventory, bookings,
// ticket validation, pricing and permissions. Tablets talk to it over the
// property Wi-Fi. When the network is unavailable:
//
// 1. The client MUST NOT make business decisions locally (no offline ticket
//    validation, no offline stock deduction, no offline price calculation).
// 2. Only operations explicitly whitelisted by the API contract may be
//    queued (e.g. capturing an order draft). Anything that needs an
//    authoritative answer (ticket scan, payment, release of rented items)
//    shows a clear "offline - cannot complete" state instead.
// 3. Every queued mutation carries the Idempotency-Key (UUID) generated when
//    the user performed the action, so replay after reconnect is safe and
//    the server de-duplicates.
// 4. Queued items record the device, staff, shift and a device-local UTC
//    timestamp; the server decides whether to accept them and records its
//    own authoritative timestamps.
// 5. The queue is visible to the user (pending count) and is drained in
//    order; server rejections are surfaced, never silently dropped.
//
// Storage choice and the whitelist are pending the architecture review.
