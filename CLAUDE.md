# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

donico is a Crystal CLI (single static binary, stdlib only) that builds, tests,
pushes and cleans Docker images described by a `donico.yml` matrix. It is a
rewrite of a Ruby gem, and **the gem is the contract**: for the same
`donico.yml`, the generated files, the docker command lines and the exit
statuses must be identical. The deliberate differences are listed in the README
("Coming from the Ruby gem") and in `CHANGELOG.md`; anything else that differs
is a bug.

## Commands

Always go through `mise`, never `crystal`/`ameba` directly: the compiling
tasks generate `licenses/` first, and the spec, coverage, lint and release
tasks carry a timeout (ameba and the multi-threaded specs can spin at 100% CPU
forever). `dev:build`, `dev:docs` and the format tasks are not bounded.

```sh
mise dev:deps            # shards install
mise dev:build           # bin/donico
mise dev:spec            # all specs (builds bin/donico first), 600s bound
mise dev:spec-mt         # same with -Dpreview_mt and CRYSTAL_WORKERS=4
mise dev:ameba           # lint, 180s bound
mise dev:format          # crystal tool format src/ spec/
mise dev:format-check
mise dev:coverage        # kcov report in coverage/ (read as an upper bound)
mise dev:docs
mise release:static      # static Linux binaries and packages in dist/ (needs docker)
```

CI runs `dev:format-check`, `dev:ameba`, `dev:docs`, `dev:spec`, `dev:spec-mt`
and `release:static`.

A single spec file or example: there is no mise task for it, so make sure the
generated inputs exist (`mise dev:build`, which also runs `dev:licenses`), then:

```sh
crystal spec spec/donico/config_spec.cr        # one file
crystal spec spec/donico/config_spec.cr:42     # one example, by line
```

`licenses/` is generated and gitignored; `src/donico/licenses.cr` embeds it
with macros and **fails compilation when it is missing or empty**.
`spec/donico/binary_spec.cr` runs the compiled `bin/donico`, so a stale binary
gives stale results there.

## Architecture

The flow is `donico.yml` → `Config` → `Image` (one per matrix row) → a task.

- `src/donico.cr` is the only file that calls `exit`. `CLI#run` returns an exit
  code and writes to injected streams; `dir`, `vars`, `now` and the runner
  factory are injected too. Specs therefore drive the CLI in-process
  (`run_cli_in`, `with_project`) with no `Dir.cd`, no real environment and a
  fixed clock. Keep it that way: no global `STDOUT`/`ENV`/`Time.local` outside
  the CLI defaults.
- `Env` (vars, dir, stdout, stderr, now) is what every task receives. `vars` is
  the process environment completed by the project's `.env` (`Dotenv`, plain
  `KEY=VALUE`, never interpolated, error messages never quote a line).
- `Config` + `MatrixEntry` parse and validate `donico.yml` (unknown keys are
  ignored; `version` must be a quoted string). `Image` derives everything from
  a row: build tag, production tags, injected build args, InSpec inputs, bake
  target names. The timestamp is computed lazily and memoized on `Config`.
- Tasks: built-ins are the `CLI::Builtin` enum, dispatched by an exhaustive
  `case ... in` (adding a member forces a branch). Row tasks are named
  `<distro>:<version>:<action>`, split on the first and last colon, and live in
  `src/donico/tasks/`.
- `Runner` is the single door to external processes (`exec`, `system`,
  `capture`, `output`, `forward`). `Runner::Real` runs children with exactly
  `env.vars` (`clear_env: true`), resolves the executable in the *child's*
  `PATH`, and logs the command line only, never the environment. Task specs use
  `RecordingRunner` (`spec/support/`); no spec starts a real docker.
- `build` and `push` check declared secrets (`Tasks::Secrets`) then replace the
  process with `docker buildx bake <target>`, with `BUILD_DATE` alone added to
  the environment (the other build args are in the bakefile).
- `Inspec` is the test harness: start a container (or `bin/inspec-container-up`),
  run InSpec from the tool image, always remove the container. It traps
  INT/TERM, forwards them to the running child and returns 128 + signal; the
  exit-status precedence is documented in the README.
- Generated files: `Bakefile` (ECR template `bakefile.ecr`, kept byte-compatible
  with the gem's ERB output; `RubyList` reproduces Ruby's `Array#inspect`, `Hcl`
  escapes values but leaves `$` alone) and `MatrixFile` (GitLab CI matrix,
  emitting YAML the way Ruby's Psych does). `GenerateFiles` renders both before
  writing either, through temporary files and renames.
- `ToolImages` resolves the hadolint and InSpec images from configuration. No
  registry host is ever built into the binary.
- Errors raised on purpose inherit `Donico::Error`; the CLI prints
  `donico: <message>` and returns 1. Anything else is a bug and keeps its
  backtrace.

## Constraints that are easy to break

- **Zero dependencies.** `shard.yml` has no `dependencies:`; ameba and
  crystalreleaser are mise tools. Adding a shard must be discussed first.
- **Thread safety.** The specs also run under `-Dpreview_mt`; signal handlers
  may run on another thread (see the `Mutex`/`Atomic` uses in `Runner::Real`
  and `Inspec`, and why `Subprocess.run` uses a single pipe).
- **The README is tested.** `spec/donico/readme_spec.cr` loads every fenced
  block preceded by a marker comment (`<!-- donico.yml -->`, `<!-- .env -->`,
  `<!-- help -->`, `<!-- matrix.json -->`, `<!-- .matrix.yml -->`,
  `<!-- docker-bake.hcl -->`) and compares it with what the code produces.
  A behaviour change means updating the README in the same change.
- **Fixtures come from the gem.** `spec/fixtures/generated/` holds the gem's
  output, not this binary's (see `spec/fixtures/generated/matrix/README.md`).
  Never regenerate them from `bin/donico`.
- **Oracle scripts** (`scripts/oracle/`, see its README) compare the binary
  with the gem on local clones of private image repositories; they only run on
  the owner's machine. Never add a normalisation filter there to hide a
  difference: fix `src/` with a failing spec first. Run
  `scripts/oracle/self-test.sh` after touching `lib.sh` or the scripts.
- **Version** comes from `shard.yml`, or from `DONICO_VERSION` at compile time
  in a release build (`src/donico/version.cr`). `shard.lock` is tracked on
  purpose so the release build sees a clean tree (no `-dirty`).
- `mise.toml`, the CI workflows, `.crystalreleaser.yml` and
  `scripts/harvest-licenses.sh` are copies of shared templates whose comments
  document their invariants; read them before editing.
