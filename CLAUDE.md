# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

donico is a Crystal CLI (single binary, two direct dependencies, five shards
linked) that builds, tests, pushes and cleans Docker images described by a
`donico.yml` matrix. It is a rewrite of a Ruby gem, and **the gem is the
contract**: for the same `donico.yml`, the generated files, the docker command
lines and the exit statuses must be identical. The deliberate differences are
listed in the README ("Coming from the Ruby gem") and in `CHANGELOG.md`;
anything else that differs is a bug.

The same binary, started as `donico-manager` (a symlink; `mise dev:build`
writes `bin/donico-manager`), is the fleet tool: it rewrites the
`donico-manager` Ruby gem, which works on a whole fleet of image repositories
described by a `donico-manager.yml`. That gem is the contract of the fleet
side in the same way; its deliberate differences are listed in `CHANGELOG.md`
(3.2.0, "Differences from the `donico-manager` gem").

A second backend, `image_builder: debuerreotype`, builds Debian base images
from nothing. It was never part of the gem: its contract is "danico", the
Rakefile of the `debian-base` image repositories (build script and docker
command lines identical; differences in `CHANGELOG.md`, 3.1.0).

## Commands

Always go through `mise`, never `crystal`/`ameba` directly: the compiling
tasks generate `licenses/` first, and the spec, coverage, lint and release
tasks carry a timeout (ameba and the multi-threaded specs can spin at 100% CPU
forever). `dev:build`, `dev:docs` and the format tasks are not bounded.

```sh
mise dev:deps            # shards install
mise dev:build           # bin/donico, and the link bin/donico-manager
mise dev:spec            # all specs (builds bin/donico first), 600s bound
mise dev:spec-mt         # same with -Dpreview_mt and CRYSTAL_WORKERS=4
mise dev:ameba           # lint, 180s bound
mise dev:format          # crystal tool format src/ spec/
mise dev:format-check
mise dev:coverage        # kcov report in coverage/ (read as an upper bound)
mise dev:docs            # crystal doc: refuses some code the compiler accepts
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
Under `image_builder: debuerreotype` the row object is a `Rootfs` instead, with
tasks of its own; everything below about `Image`, bake and InSpec is the `bake`
backend.

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
- `ToolImages` resolves the hadolint, InSpec and debuerreotype images from
  configuration. No registry host is ever built into the binary.
- The debuerreotype backend: `Config#debuerreotype?` switches the validation
  (each backend reads its own keys and ignores the other's; `MatrixEntry` is
  built with `rootfs: true`). `Rootfs` derives the timestamp (the day before
  the run, or before `CI_PIPELINE_CREATED_AT`; never `CI_COMMIT_TIMESTAMP`), the build directory and tarball of
  each arch, the tags and the build script, rendered from `rootfs_script.ecr`.
  `Tasks::RootfsBuild` runs one `docker run` per arch through `Runner#system`
  and, like `Inspec`, traps INT/TERM to forward them and return 128 + signal,
  `Tasks::RootfsPush` reads `etc/debian_version` from a tarball then replaces
  the process with `docker buildx build`, `Tasks::RootfsClean` removes the
  leftovers of `build/` through `sudo` unless root. A row has no `test` and no
  `login`; `generate-files` writes the CI matrix alone.
- Errors raised on purpose inherit `Donico::Error`; the CLI prints
  `donico: <message>` and returns 1. Anything else is a bug and keeps its
  backtrace.

### The fleet side (`Donico::Fleet`, `src/donico/fleet/`)

`src/donico.cr` picks the program on the basename of `argv[0]`
(`Donico.fleet_program?`): `Fleet::CLI` for `donico-manager`, `CLI` otherwise.
The flow is `donico-manager.yml` → `Manifest` → `Repos` → a command.

- `Fleet::CLI` is built like `CLI` (injected streams, dir, vars, clock, runner
  factory; plus the GitHub transport, the terminal predicate and the screen
  for `repos update`), with its own `Command`/`Repo` enums and exhaustive
  `case ... in`. Errors are `donico-manager: <message>`, status 1. Its `Env`
  is the variables completed by the `.env` of the configuration repository.
  The processes it starts (git, the opener) run on an `Env` with
  `DONICO_QUIET` set: no `run_cmd:` line may write over the text interface.
- `Manifest` parses and validates `donico-manager.yml` (policies per image;
  images always sorted); `Repos` answers which images are cloned in the
  workspace and where. `Sweep` runs one command per cloned repository between
  the gem's separators; `Color` paints only on a terminal, never with
  `NO_COLOR` or `TERM=dumb` in the fleet's variables.
- Generators: `Readme` (root README, from `templates/README.md`),
  `ImageReadme`, `Heritage`. They read each image's `donico.yml` as plain
  YAML, never through `Config.load`, so an image donico refuses still gets its
  line. `Regenerate` runs `GenerateFiles` inside the binary.
- `DonicoPin` (`bump-donico`) and `Versions::Bumper` (`repos update`) rewrite
  one file, regenerate, and put the file back when the regeneration fails;
  `Versions::Committer` commits and pushes. An `Outcome` (`:ok`, `:skip`,
  `:fail` and a message) is per repository: one bad repository never aborts a
  batch; a broken machine (`git` absent) raises.
- `repos update`: `Versions::Github` (crest, HTTPS to the GitHub API; its
  client context adds `SSL_CERT_FILE`/`SSL_CERT_DIR` of the fleet's variables,
  and on darwin the system bundle when the statically linked OpenSSL's
  built-in default file is missing, `Github.ca_locations`) and
  `Versions::Scanner` (fibers, five lookups at a time) produce `Row`s,
  classified by `Versions::Policy`; `Versions::Updater` holds the order of the
  apply phase; `Versions::Screen` is the state without a terminal, and
  `Versions::Terminal` draws it with Termisu and traps TERM, HUP and INT to
  give the terminal back.

## Constraints that are easy to break

- **Two dependencies, no more without discussion.** `shard.yml` lists crest
  (the HTTPS client of `repos update`, which brings http_proxy,
  http-client-digest_auth and cookie_jar, and makes every build link OpenSSL
  and zlib) and Termisu (the text interface of `repos update`, MIT, no
  dependency of its own). Adding another shard must be discussed first;
  ameba and crystalreleaser are mise tools. The binary embeds the notices of
  what it links (`licenses.manifest`), so a new shard or a new static library
  goes there too.
- **Thread safety.** The specs also run under `-Dpreview_mt`; signal handlers
  may run on another thread (see the `Mutex`/`Atomic` uses in `Runner::Real`
  and `Inspec`, and why `Subprocess.run` uses a single pipe). A spec keeps a
  socket on one thread (`spawn(same_thread: true)`, asked under
  `-Dpreview_mt` only: the nightly's scheduler refuses it): no `HTTP::Server`
  in a spec. Under `-Dpreview_mt` it hands each accepted socket to a fiber on any
  worker thread, and the suite then hung about one run in twenty (Crystal
  1.20.3); the GitHub specs serve one connection from a `TCPServer` instead.
- **The README is tested.** `spec/donico/readme_spec.cr` loads every fenced
  block preceded by a marker comment (`<!-- donico.yml -->`, `<!-- .env -->`,
  `<!-- help -->`, `<!-- matrix.json -->`, `<!-- .matrix.yml -->`,
  `<!-- docker-bake.hcl -->`, and the same names followed by ` debuerreotype`,
  plus `<!-- script debuerreotype -->`, for the section on that backend, and
  `<!-- donico-manager.yml -->` and `<!-- donico-manager help -->` for the
  fleet section) and compares it with what the code produces. A behaviour change means updating
  the README in the same change.
- **Fixtures come from the gem.** `spec/fixtures/generated/` holds the gem's
  output, not this binary's (see `spec/fixtures/generated/matrix/README.md`).
  Never regenerate them from `bin/donico`. Likewise `spec/fixtures/debuerreotype/`
  holds the build scripts Ruby rendered from danico's ERB template (see its
  README): `rootfs_script.ecr` follows that template line for line, and a
  change to the recipe is a deliberate break of that equality.
- **The fixture fleet comes from the donico-manager gem.**
  `spec/fixtures/fleet/` is a small fleet whose `expected/` files (READMEs,
  heritage tree) were produced by running the gem on it. Never regenerate
  them from `bin/donico-manager`: a change to the fixture fleet means running
  the gem again on a copy of it and copying its output.
- **The debuerreotype build script is shell.** Every value written into it is
  checked when `donico.yml` loads (`MatrixEntry::SCRIPT_WORD`, and the patterns
  of `distro`, `version`, `timestamp` and the `DEBIAN_ARCHS` list). A new value in
  `rootfs_script.ecr` needs the same check.
- **Oracle scripts** (`scripts/oracle/`, see its README) compare the binary
  with the gems on local copies of private repositories; they only run on the
  owner's machine. Three of them: `generated-files.sh` and `commands.sh`
  (donico gem, image repositories) and `fleet.sh` (donico-manager gem, the
  fleets' configuration repositories). Never add a normalisation filter there
  to hide a difference: fix `src/` with a failing spec first. Run
  `scripts/oracle/self-test.sh <donico gem checkout> <bin/donico>
  <donico-manager gem checkout> <bin/donico-manager>` after touching `lib.sh`
  or the scripts. `static-smoke.sh` runs a fixed list of commands, one of them
  through `donico-manager`, with a static Linux binary of `mise release:static`.
- **Version** comes from `shard.yml`, or from `DONICO_VERSION` at compile time
  in a release build (`src/donico/version.cr`). `shard.lock` is tracked on
  purpose so the release build sees a clean tree (no `-dirty`).
- `mise.toml`, the CI workflows, `.crystalreleaser.yml` and
  `scripts/harvest-licenses.sh` are copies of shared templates whose comments
  document their invariants; read them before editing.
