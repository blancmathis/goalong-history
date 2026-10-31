# seed.d — one file per seed, written by a helper (L3n owns t046_shard.sh)
- `NAME.sh` (NAME = [a-z0-9-]+) is called by the nav token `seed:NAME` as `bash NAME.sh seed`, then `bash NAME.sh unseed` after the row.
- Env: DATA (Goalong Dev data folder), BUNDLE (bundle id, for `defaults`), GOALONG (CLI path), OUT (row output folder). 60 s max.
- Exit 0 = seeded; 3 = seeded and the app must restart (state read at launch); other = nav miss (the row fails as nav).
- `unseed` must undo everything (the next row starts clean). Comment each step with the file:line of the code it targets.
- Throwaway CI runner only: no keychain, no /Applications, nothing outside DATA and the app's defaults domain without a note.
