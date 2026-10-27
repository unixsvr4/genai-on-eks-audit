# Publication record — swept 2026-10-26

Scanned and swept before the first push to a public remote. **Re-run the
checks at the bottom after any new capture**, because the capture tooling
is what caused the original problem.

## Why there was anything to sweep

`scripts/lib/env.sh` masked identifiers with a perl substitution built on
`\Q`, which suppresses regex metacharacters and does nothing about
interpolation. A masked value containing `@` had part of itself
interpolated as an empty array, so the pattern silently became one that
matched nothing. Full write-up in `RESEARCH.md`, under "Identifier masking
in `scripts/lib/env.sh` was silently broken (2026-09-02)".

It looked correct the whole time because the scripts print the
already-masked shell variable themselves, so the clause was never
exercised on the output it exists to protect. Fixed 2026-09-02 by passing
values through `%ENV` and single-quoting the perl program. Everything
captured before that date had gone through the broken mask.

## What was replaced

All of it in the working tree **and across every commit**, with
`git filter-repo`, using both `--replace-text` (file contents) and
`--replace-message` (commit messages):

- A personal email address, and its partially-masked forms. A mask that
  keeps the last three characters of a local part still gives away most of
  an address, and those partials appeared in the docs as examples of the
  masking behaviour. They now illustrate the same behaviour on
  `user.name@example.com`.
- Three cloud account ids, replaced with distinct documentation
  placeholders so the write-up can still distinguish the event account
  from a personal one. Bucket names derived from an account id changed
  with it.
- A support case number.
- Four EC2 capacity-reservation ids.

### Two mistakes in the first pass, recorded so they are not repeated

**Enumerating is not checking.** The first sweep listed every 12-digit
string, investigated only the one that sat inside an `arn:aws:` prefix,
and wrote the rest off as benign in this file. Two of them were real
account ids, plainly labelled `AWS_ACCOUNT_ID=` and embedded in bucket
names. A list of candidates is not a cleared list.

**`--replace-text` does not touch commit messages.** Blobs came back clean
while a commit message still carried the address in full, and the body of
that commit was a note about improving the masking. `--replace-message`
with the same rules is required, and the verification has to read
`git log` and not only the object store.

## Round two, after the first push — what a secret scan does not catch

The first sweep looked for credentials and identifiers and found them. It
did not look for **references to things outside the repo**, and three of
those shipped in the first push:

- A markdown link in `README.md` pointing two directories up into a
  separate private repo, with a filename and a note that post scheduling
  is tracked there. A 404 for every reader, and it named a private repo.
- An earlier variant of the same link, one directory up, in a
  pre-restructure revision of the root `README.md`, plus a file-tree
  listing naming the same draft. Only in history, which is exactly why a
  tree-only scan missed them.
- 23 xterm title escape sequences inside the committed transcripts in
  `outputs/`, each carrying a username, a hostname and a local directory
  path. Zero of them were in any current file; all 23 were in history.

Also found and fixed: a dangling link in `docs/GOTCHAS.md` to a document
that had been moved out of the repo months earlier.

**The lesson worth keeping.** A credential scan asks "is there a secret
here". Publishing also requires asking "does anything point outside this
repo, and does anything identify the machine it ran on". Those are
different questions, and the second is the one that got missed. A captured
terminal transcript is the highest-risk file type for it, because the
shell writes username, hostname and path into the stream as control
characters no reader ever sees.

## Left in deliberately

- `i-`, `subnet-` and `sg-` identifiers throughout the diagnostics. They
  are not credentials, they are useless without access to the account, and
  the infrastructure they name was destroyed at teardown. Masking fourteen
  instance ids would also break the debugging narrative, which is the
  point of those files.
- `763104351884` is AWS's own public deep-learning-container registry
  account, published in AWS documentation.
- 12-digit runs that are not accounts: a substring of `9223372036854775807`,
  a timestamp, and a fragment of an IAM role name.
- `${AWS_ACCOUNT_ID}` and `${S3_RAG_DATA_BUCKET}` are unexpanded shell
  variables.
- `a.b@gmail.com` and similar inside the masking write-up are illustrative
  values demonstrating the bug, not real addresses.
- `manifests/*` is gitignored. The rendered manifests on disk still carry a
  real account id and are not published; do not force-add them.

## Re-verify before any push

Scan what would actually be published, which is tracked files, not the
working tree:

    git ls-files -z | xargs -0 grep -hEo "[0-9]{12}" | sort -u
    git ls-files -z | xargs -0 grep -hEo \
      "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}" | sort -u
    git ls-files -z | xargs -0 grep -hEo \
      "AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}" | sort -u
    git ls-files -z | xargs -0 grep -hEo "cr-[0-9a-f]{8,}" | sort -u

Then the questions a secret scan does not ask. Anything pointing outside
the repo, anything naming the machine, and any relative link that does
not resolve:

    git ls-files -z | xargs -0 grep -nE "\]\(\.\./\.\./|/Users/|/home/"
    git ls-files -z | xargs -0 grep -naE "[a-z0-9_-]+@[a-z0-9-]+:~"

Then history, both objects and messages:

    git rev-list --objects --all | awk '{print $1}' \
      | git cat-file --batch-check | awk '$2=="blob"{print $1}' \
      | git cat-file --batch | grep -nE "<pattern>"
    git log --all --format="%B%n%an%n%ae" | grep -nE "<pattern>"

History was rewritten rather than only the tree, because a scrubbed file
with the original still in `git log -p` is not scrubbed. This was done
before the first push, when there was no divergence to manage. After a
push it means a force-push and anyone who cloned keeps the old objects.
