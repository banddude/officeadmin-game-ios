# Architecture, world model, and API boundary

## Backend

The backend is the existing OfficeAdmin server (private repo `banddude/officeadmin-books`).
This app talks only to its versioned HTTP API under `/api/v1/` and authenticates the same way
the existing OfficeAdmin iOS client does. Nothing here reaches the database directly.

## Auth

- Bearer API key or the existing session flow, exactly as the OfficeAdmin iOS app does it.
- Credentials live in the iOS Keychain. Never in source, plists, or UserDefaults.
- Single organization for now (Shaffer Construction); the org id rides on every request.

## World model

`OfficeAdmin API -> WorldMapper -> World (RealityKit/SceneKit scene)`

The mapper turns real records into world entities and is pure and unit-tested:

| OfficeAdmin record | World entity |
|---|---|
| project with an address | a job site placed at its real coordinates, with a building/state marker |
| crew schedule / clock state | crew characters placed at the job or office they are assigned to |
| approval request, open question, unread client message | an in-world quest: a character, mail on the desk, or a marker |
| invoice / receivable / payment | money and mail in the office; overdue shows as world state |
| quote / bid due | a marker with a due date on the site or the office whiteboard |

`In-world action -> existing OfficeAdmin API write -> refetch`. No optimistic local truth.

## Scenes

- `World/` the game world: a RealityKit diorama board. `WorldBoard` (pure, in Core)
  projects real site coordinates (Web Mercator, meters) onto a padded local board —
  Los Angeles center as fallback — with building footprints by category and the office
  as the home node in its corner. The player walks a little character with a thumbstick
  or by tapping the ground/buildings; the camera follows. Walking up to a site shows its
  card, walking into an attention pickup opens it, and the office door goes inside.
  Apple Maps is never the visual — CLGeocoder is the only MapKit-adjacent dependency.
- `Office/` a walkable 3D office interior. Desk, mail, phone, whiteboard, calendar.
- `Site/` a job-site close-up: progress, crew present, what is needed.

## Layout

- `App/` app entry and navigation between scenes
- `Core/API/` typed client for the OfficeAdmin endpoints this app uses
- `Core/Auth/` Keychain-backed credential store
- `Core/World/` mappers from API records to world state, the board projection and
  walk rules (`WorldBoard`, `WorldWalk`), with tests
- `Scenes/World`, `Scenes/Office`, `Scenes/Site`
- `Assets/` stylized low-poly models and materials (original or permissively licensed only)
- `docs/` this file and endpoint notes
