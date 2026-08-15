# outputs/

Every script in `scripts/` tees its full terminal output (stdout + stderr) to
a same-named `<script>.out.txt` here (via `scripts/lib/env.sh`), so a run can
be reviewed or shared — e.g. walked through with students — without
re-running anything live.

Gitignored by default (contents capture your own account IDs/ARNs/IPs); this
`README.md` is the one file kept so the directory itself stays tracked. To
commit a specific transcript deliberately:

```bash
git add -f outputs/02-gpu-infrastructure.out.txt
```

Reruns overwrite the previous file for that script name — copy or rename one
out first if you need to keep it around before running the script again.
