# OfficeAdmin Game (iOS)

A real game, not a dashboard. A comfy, fully 3D world for running Shaffer Construction,
where the world is built from live OfficeAdmin data and every action in the world writes
back through the existing OfficeAdmin API. OfficeAdmin stays the single system of record and
its normal UI is never touched.

## What it is

- **A 3D world map that is accurate to the real world.** Real job sites at their real
  locations, with terrain and streets underneath, rendered in a clean, warm, stylized look.
- **Characters.** The crew, Mike, and Maricar as characters who are where the data says they
  are: at a job, in the office, on the road.
- **An office.** A 3D office interior you walk through. The desk, the mail, the phone, and the
  whiteboard are how you handle what needs handling.
- **Quests, not queues.** Things that need Mike show up in the world as characters, mail, or
  markers, and are handled with in-world taps: approve, delegate, answer.
- **Company state as world state.** Money, receivables, job progress, and workload show up
  as the world changing, not as charts.

References for feel: Animal Crossing, Stardew Valley, Two Point Hospital, Kairosoft's
Game Dev Story, Townscaper, and Dorfromantik. Comfortable, readable, satisfying.

## Rules

- Native iOS. Swift, RealityKit or SceneKit for 3D, MapKit for real-world geography.
- Real OfficeAdmin data drives every piece of world state. No fake state, no fake scoring.
- Every action writes back through existing, supported OfficeAdmin APIs. No side database.
- No dashboards, tables, or chart screens. If it looks like an admin panel it is wrong.
- No secrets, tokens, or production credentials are ever committed.

See `docs/ARCHITECTURE.md` for the API boundary and the world model.
