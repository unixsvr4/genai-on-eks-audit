# manifests/

Populated at runtime by `scripts/*.sh` — each script `curl`s the exact tag-pinned manifest URLs recorded in `RESEARCH.md` into subdirectories here, mirroring the upstream repo's own layout. Contents are gitignored (fetched fresh each run, not vendored) — this file exists just so the directory itself is tracked.
