# Architecture and API boundary

## Backend

The backend is the existing OfficeAdmin server (private repo `banddude/officeadmin-books`).
This app talks only to its versioned HTTP API under `/api/v1/` and authenticates the same way
the existing OfficeAdmin iOS client does. Nothing in this repo may reach the database directly.

## Auth

- Bearer API key or the existing session flow, exactly as the OfficeAdmin iOS app does it.
- Keys live in the iOS Keychain on device. Never in source, plists, or UserDefaults.
- The organization id is part of every request context; this app is single-org for now.

## Data flow

`OfficeAdmin API -> GameStateMapper -> SwiftUI views`. The mapper turns real records
(projects, quotes, invoices, receivables, crew schedule, approval requests) into game
presentation (world tiles, quests, company meters). It is pure and unit-tested.

`User action -> existing OfficeAdmin API write -> refetch`. No optimistic local truth.

## Layout

- `App/` SwiftUI app, three tabs: World, NeedsMike, Company
- `Core/API/` typed client for the OfficeAdmin endpoints this app uses
- `Core/Auth/` Keychain-backed credential store
- `Core/GameState/` mappers from API records to game state, with tests
- `docs/` this file and endpoint notes
