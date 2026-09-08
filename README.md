# OfficeAdmin Game (iOS)

A real game, not a dashboard. A comfy, fully 3D world for running Shaffer Construction,
where the world is built from live OfficeAdmin data and every action in the world writes
back through the existing OfficeAdmin API. OfficeAdmin stays the single system of record and
its normal UI is never touched.

## What it is

- **A 3D world board that is accurate to the real world.** Real job sites projected from
  their real coordinates onto a stylized game board — cream blocks, streets, parks, a
  water edge — laid out like a cozy diorama, never like a survey map.
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

- Native iOS. Swift, RealityKit for 3D. Real-world geography comes from geocoding and
  coordinate projection; Apple Maps is only ever a coordinate source, never the visual.
- Real OfficeAdmin data drives every piece of world state. No fake state, no fake scoring.
- Every action writes back through existing, supported OfficeAdmin APIs. No side database.
- No dashboards, tables, or chart screens. If it looks like an admin panel it is wrong.
- No secrets, tokens, or production credentials are ever committed.

See `docs/ARCHITECTURE.md` for the API boundary and the world model.
