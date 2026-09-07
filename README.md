# OfficeAdmin Game (iOS)

A standalone, phone-first iOS app that makes running Shaffer Construction feel like a
comfortable management game. It is a **client** of the existing OfficeAdmin server: the
OfficeAdmin API, auth, and database remain the single system of record. This app never
duplicates data and never changes the normal OfficeAdmin UI.

## Three screens

1. **World**: jobs, crew, and company state shown visually; over time, a map or game-world style view.
2. **Needs Mike**: a small quest-like decision queue. Approve, delegate, or answer with taps instead of typing.
3. **Company**: money, receivables, job progress, crew workload, and company health presented as satisfying game state.

## Rules

- Real OfficeAdmin data drives every piece of game state.
- Every action writes back through existing, supported OfficeAdmin APIs. No side database.
- Game mechanics are cosmetic and organizational. No fake employee performance scoring.
- No secrets, tokens, or production credentials are ever committed. See `docs/ARCHITECTURE.md`.

## Status

Scaffold in progress. See `docs/ARCHITECTURE.md` for the API boundary and open issues for the plan.
