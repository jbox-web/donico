# Oracle scripts

The Ruby gem is the oracle. Two scripts, `generated-files.sh` and
`commands.sh`, run the gem and the binary on throwaway copies of the local
clones of the image repositories and compare them (design document, section 8,
first two checks). They are meant for the owner's machine: the clones live on
private forges and cannot be reached from a public CI. Two more scripts check
the checkers and the shipped binary: `self-test.sh` and `static-smoke.sh`,
described at the end.

```sh
scripts/oracle/generated-files.sh <gem checkout> <bin/donico> <fleet>...
scripts/oracle/commands.sh        <gem checkout> <bin/donico> <fleet>...
```

- `<gem checkout>`: the Ruby gem repository. Its `ruby` and `bundle` are
  resolved once, with `mise which`, from that directory.
- `<bin/donico>`: the binary, built by `mise dev:build`.
- `<fleet>`: a directory of image repositories (`<fleet>/ci-config/docker-images`).
  Several can be given. A subdirectory without `donico.yml` is counted and
  skipped.

Both scripts end with `N compared, M different` and exit 1 if `M > 0`, and
also when nothing was compared (`N = 0`: a wrong fleet directory would
otherwise end green), when a gem failure is not allowed, or when the worker of
a repository died before its end (the report lists it as unfinished). A fleet
may be given once only. They need GNU tools, `rsync` and `timeout` first on
`PATH`, and use at most four children at a time, each bounded by `timeout 60`.
Two runs of the same script cannot overlap: the second one is refused while
the lock of the first (`<script>.lock`, next to its records) exists.

## What keeps them harmless

- The fleets are read-only: every repository is copied once with `rsync -a`,
  `.git` included, under `$HOME/.local/tmp/claude-jbox-donico-oracle/<script>/`,
  recreated at each run. No `.env*` file is ever copied or read, nor the other
  usual carriers of secrets (`*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.jks`,
  `id_rsa*`, `id_ed25519*`, `.npmrc`, `.netrc`, `auth.json`, `credentials*`).
  `.git/config` is copied with the rest of `.git`: a remote URL that embeds a
  token is therefore duplicated there until the next run. The gem and the
  binary run in that copy, addressed by its physical path.
- Every child (gem, binary, and the hook scripts they execute) runs under
  `env -i`, with a `PATH` made of `scripts/oracle/fake`, then the directory of
  the resolved `ruby`, then `/usr/bin:/bin`. `fake/` holds `docker`, `curl`,
  `wget`, `ssh`, `scp`, `sftp`, `nc`, `ncat`, `telnet`, `ftp` and `rsync`
  (all but `docker` are symlinks to it). A fake appends its call to
  `ORACLE_LOG` and, in `ORACLE_CALLERS`, the command line of its parent process
  (this is how the oracle knows a call came from a hook); it does nothing else.
- Before the first copy, a self-check proves, inside that exact environment,
  that `command -v` resolves each of those names to the fake directory and that
  a fake logs and exits 0. The script aborts otherwise.
- 15 repositories carry `bin/inspec-container-up` scripts, one also
  `bin/inspec-container-down`. Each copy is scanned: the commands the scripts
  call are listed in the report. The analyser reads the first word of every
  logical line, the words after `|`, `&&`, `||`, `;`, `if`, `then`, `do`, `else`,
  `elif`, `while`, `until` and `!`, and the commands inside `$( )` and
  backticks. A script calling a command that is neither a fake, a function it
  defines, a shell word nor in the explicit allow-list of local tools
  (`HOOK_LOCAL_TOOLS` in `lib.sh`: `cat grep cut head tail tr sort uniq wc
  date basename dirname sleep mkdir touch`) is reported as skipped for `test`
  and never run. `awk`, `sed` and `trap` are not allowed: each can run code the
  analyser does not read. So is a script holding a form the analyser cannot
  follow: a command after a variable assignment (`A=1 cmd`), after an opening
  brace or parenthesis on the same line, after a lone `&`, on the line of a
  `case` pattern, inside a process substitution, named by a variable (`$tool
  ...`), or a line with an unbalanced quote. The scan refuses what it cannot
  read; it is not a sandbox, and the fakes on `PATH` remain the barrier. The
  variables the scripts read and do not define themselves are exported with a
  dummy value, `oracle` unless `oracle_dummy_values` says otherwise: `run_mode`
  takes `default` then `dind`, the two branches of the gitlab-runner hook, and
  `test` runs once per value. A hook that never made a call is caught by the
  `hook` assertion below.
- Every variable starting with `CI_` is absent, even when a hook reads it
  (the names in `CI_*` and `DONICO_*` are never exported as dummies);
  `CI_COMMIT_TIMESTAMP` is fixed at `2026-07-31T10:20:30+02:00`;
  `DONICO_RELEASE` is absent.

## The fake docker

One line `--- call` per call (`--- call <name>` for the other fakes), one line
per argument, then one `env NAME=VALUE` line per name in `ORACLE_VARS`
(`NAME=<unset>` when absent, or when the name is not an identifier). The
record of a call is written in one piece, so two fakes running at once never
interleave their lines. `ORACLE_VARS` is computed per repository from the
gem: the build arg names plus the names of the Inspec inputs. The fake prints
`fakecontainer0001`, and exits 0 unless its arguments joined by spaces match
`ORACLE_FAIL_MATCH`, in which case it exits with `ORACLE_FAIL_STATUS`, still
printing the id unless `ORACLE_FAIL_SILENT` is set.

## generated-files.sh

In the copy: generate with the gem, keep both files, generate with the binary,
compare after normalising the warning line (design 7, item 6). Any other file
the binary leaves in the copy is a difference too. Per repository,
`identical` or `DIFFERENT` (the binary against the gem: a bug). Separately
`stale` when the files of the clone's working tree (called "committed" in the
report) differ from the gem's own output; that is not a bug of the binary.

## commands.sh

For every row (taken from the gem, never from the binary) and every action of
`build test push clean login`, plus `lint-dockerfile` once per repository, runs
the gem then the binary and compares the call log, the exit status and stdout.
`lint-commits` is not ported (item 12) and not compared.

The gem is the reference, so it must behave as the pass says before a pair
means anything. Otherwise the pair is a `GEMFAIL`: it is not compared, it is
listed in the report, and it makes the script exit 1 unless the pair matches an
entry of `ORACLE_GEMFAIL_ALLOWED` in `lib.sh` (empty, each entry to be justified
by a comment). A gem that times out (exit 124), exits with another status than
the pass expects, or makes no docker call is a `GEMFAIL`. A binary that times
out, or deviates in any way, is a `DIFF`.

Passes (the names in the report), with the exit status the gem must give:

| Pass | What | Gem exit |
|---|---|---|
| `success` | every declared secret exported with a dummy value; `test` runs once per variant of the hook dummies, and for a repository with a `bin/inspec-container-up` both sides must show a fake call made by that hook | 0 |
| `missing-secret` | `build` and `push` of rows declaring `secret_envs`, each id left out in turn: both sides must exit 1, make no docker call and name the declaration (the wording is not compared, item 9) | 1 |
| `fail-clean` | `rmi` fails (status 7); the gem flattens it to 1 (`Tasks::Bake#clean`) | 1 |
| `fail-lint` | `hadolint` fails (7); the gem flattens it to 1 (`common.rake`) | 1 |
| `fail-test-start` | the container start fails (125); skipped when the repository has a hook starting the container | 125 |
| `fail-test-start-silent` | same, and the fake prints no container id: neither side may call `kill` | 125 |
| `fail-test-inspec` | `inspec exec` fails (100) | 100 |
| `fail-test-cleanup` | `kill` fails (7) | 7 |

Normalisation of stdout: these rules and no other, each a deliberate
difference of design section 7.

- `bin/rake` becomes `donico` on the gem side (item 6).
- `build`, `push`, `login`: `^exec: ` lines are removed on both sides (item 13).
- `test`: `^(run_cmd|with_exit_status): ` lines are removed on the binary side
  (item 11).
- `clean`, `lint-dockerfile`: nothing is removed.
- In `docker run` calls only (call logs) and in logged `docker run` lines
  (stdout), the argument right before `hadolint` or `inspec` becomes
  `<tool-image>` (item 4).
- `build`, `push`: in the call logs, the `env NAME=VALUE` lines of every name
  but `BUILD_DATE` are removed on both sides (item 22: the gem exports every
  build arg to docker, the binary `BUILD_DATE` alone). `BUILD_DATE` is still
  compared.

Never add a filter to hide a difference: fix `src/` with a failing spec first,
or record the difference in design section 7 and here with its item number.

## Reading the report

Sections, in order: the self-check; the hook scripts and the commands they
call; skipped and failing repositories (`gem failure` means the gem itself
misbehaved on that copy or pair, with the reason: not a difference of the
binary, but the comparison proved nothing, so the run fails); the differences,
each with the repository, the task, the pass, both exit codes and the two
sides' lines (`<` gem, `>` binary); the stale files; the counts per fleet and
pass, per pass and per fleet, each as `same / different / gem failure /
skipped`; the hosts named in the call logs (registry prefixes of image names,
and URLs; a URL there comes from a hook script and went to a fake); the elapsed
time; the number of gem failures not allowed; the last line, `N compared, M
different`. The script exits 1 if `M > 0` or if a gem failure is not allowed.

### Files and records

Under `$HOME/.local/tmp/claude-jbox-donico-oracle/<script>/`:

- `work/<fleet>.<repository>/<pass>.<task>[.vN].{g,b}.{calls,callers,out,err,exit}`
  for every pair, kept (`g` gem, `b` binary; `calls` the fake log, `callers`
  who made each call, `out` and `err` the streams, `exit` the status), with the
  normalised forms `calls.n` and `out.n` beside them; `.vN` numbers the hook
  variants of `test`. For `generated-files.sh`: `generated.generate-files.{g,b}.*`
  and the directories `committed/`, `gem/`, `bin/` holding the generated files.
- `rec/<fleet>.<repository>.tsv`: one record per pair, tab separated, `status`,
  `pass`, fleet, repository, then `<task> gem=<exit> bin=<exit>` (the reason
  for a `GEMFAIL` or `SKIP`). The status is `SAME`, `DIFF`, `GEMFAIL`, `SKIP`,
  `STALE` (generated files only), `NOCFG` (no `donico.yml`) or `DONE` (the
  last line of a worker that reached its end). Only `SAME` and `DIFF` count as
  compared. `rec/*.diff` holds the details of the differences, `rec/*.hooks`
  the commands each hook calls.
- `all.tsv` (every record), `selfcheck.log`, `work/*.corpus` (the normalised
  call logs the host inventory is built from) and, per repository,
  `work/<fleet>.<repository>/info.*` (the matrix as the gem lists it).

## self-test.sh

```sh
scripts/oracle/self-test.sh <gem checkout> <bin/donico>
```

Proves the gate can fail. On a tiny project of its own (never the fleets: one
row, one declared secret, a start hook) it runs the two scripts with the real
binary (expected: exit 0, 0 different) and with wrappers placed in front of
it: one appends an argument to the `buildx bake` call (call log), one makes
`clean` exit 3 (exit status), one prints one more line on `login` (stdout),
one always provides the declared secret (missing-secret pass), one makes
`generate-files` write nothing, one makes it leave one more file. Each mutation
must be reported different with exit 1. A fleet holding no project must make
both scripts fail on "nothing was compared". Its records go under
`self-test/runs/`, apart from those of a run over the fleets. Run it after any
change to `lib.sh` or the scripts.

## static-smoke.sh

```sh
scripts/oracle/static-smoke.sh <native bin/donico> <linux binary> <platform>
```

The two scripts above and the specs only ever ran the native binary; the
static Linux binary that ships had run nothing but `--version`. This one runs
the same fixed list of commands twice, on a small project of its own (two
rows, a `.inspecrc`, `test_variants`, `login_env`, build args, no secret, no
`.env`): once with the native binary on the host, once with the Linux binary
inside a throwaway `alpine:3.24` container of `<platform>` (`linux/amd64` or
`linux/arm64`). The list: `help`, `generate-files`, `matrix`, `image-builder`,
the `build`, `push`, `test`, `clean` and `login` tasks of the rows, an unknown
task, `lint-dockerfile`, and a `test` where the fake docker fails the
`inspec exec` call with status 100.

The `docker` on the `PATH` of both sides is a shell script that logs its
arguments (`--- call`, then one line per argument), prints a container id for
the start and fails the Inspec call on demand. The one real docker call of the
script starts the container, bounded by `timeout 900`: `docker run --rm --name
donico-static-smoke-<pid> --platform <platform> --user <uid>:<gid> -v
<project>:/work -v <binary>:/usr/local/bin/donico:ro -v <fake dir>:/fake:ro -w
/work -e PATH=/fake:/usr/bin:/bin alpine:3.24 ...` (the container is removed
by name when the bound is hit; the host run is bounded by `timeout 300`). Everything but the project
copy is mounted read-only, the container is removed, and each command runs
under `env -i` with a `HOME` of its own.

Compared per command: exit status, stdout, stderr and the fake's call log, then
the two generated files, after replacing the project path by `<project>` (the
only normalisation). The report is one `same` or `DIFFERENT` line per command
and file, then `N compared, M different`; the script exits 1 if `M > 0`, or
when a side produced fewer results than the list or the comparison would be
empty (the build made no `buildx` call, the failing run did not exit 100,
`generate-files` wrote nothing). Records are kept under
`$HOME/.local/tmp/claude-jbox-donico-smoke/<platform>/`.

The Linux binaries come from `mise release:static`, run in a throwaway copy of
the repository with one local commit made in that copy only, so that the
build sees a clean tree: the binary must then say no `-dirty` in
`--version`. (`shard.lock` is tracked for that reason: without it,
crystalreleaser's docker builder runs `shards install` in the mounted tree and
the build of the other architecture sees an untracked file.)

