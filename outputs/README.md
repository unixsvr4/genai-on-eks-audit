# outputs/

Every script in `scripts/` tees its full terminal output (stdout + stderr) to
a timestamped `<script>-<date>-<time>.out.txt` here (via `scripts/lib/env.sh`), so a run can
be reviewed or shared — e.g. walked through with students — without
re-running anything live.

One file **per run**, never overwritten:

```
01-deploy-infra-20260903-145514.out.txt
01-deploy-infra-20260903-153109.out.txt
01-deploy-infra-latest.out.txt -> 01-deploy-infra-20260903-153109.out.txt
```

`<script>-latest.out.txt` is a relative symlink to the newest run, so
`cat outputs/01-deploy-infra-latest.out.txt` always shows the last one. Runs
that start within the same second get a `_2`, `_3` suffix.

This used to be a single fixed `<script>.out.txt` that every rerun clobbered —
which threw away exactly the transcript you most want, since you rerun a script
precisely when the first attempt went wrong. It cost us a successful
`99-destroy-all` run, overwritten ten minutes later by a second no-op run of the
same script.

**Local only.** The whole directory is gitignored (`**/outputs/*` — matched at
any depth) because transcripts carry account IDs, ARNs and your home IP.
Nothing here is ever pushed. This `README.md` is the one exception, kept so the
directory stays tracked. To share one deliberately:

```bash
git add -f outputs/02-gpu-infrastructure-20260903-145903.out.txt
```

Nothing prunes old runs — delete them yourself when the directory gets noisy.
