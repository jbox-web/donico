# donico

[![CI](https://github.com/jbox-web/donico/actions/workflows/ci.yml/badge.svg)](https://github.com/jbox-web/donico/actions/workflows/ci.yml)

donico builds, tests, pushes and cleans Docker images from one
`donico.yml` file, locally and in CI. You describe the images of a repository as
a matrix (a version and a distribution per row); donico turns it into
`docker buildx bake` targets and a set of named tasks:

```
donico bookworm:1.0:build
donico bookworm:1.0:test
donico bookworm:1.0:push
```

It is a single static binary with no runtime dependency. It reads `donico.yml`
in the current directory, needs `docker` (with buildx) on the `PATH`, and does
not know any registry host: every image it uses comes from your configuration.

What it does for a repository of images:

- **Generates** `docker-bake.hcl` and a GitLab CI job matrix from the
  `donico.yml`, so the committed files never drift from it.
- **Builds and pushes** one matrix row at a time with `docker buildx bake`,
  after checking that every declared secret is available.
- **Tests** the built image with [Chef InSpec](https://docs.chef.io/inspec/),
  in a throwaway container that is always removed.
- **Lints** the Dockerfiles with hadolint, **cleans** the local build tag and
  opens a **login** shell in an image.

## Installation

From a release (the Linux binaries are static):

- the `.tar.gz` archives, the `.deb` and the `.rpm` of the
  [GitHub release page](https://github.com/jbox-web/donico/releases), with
  `checksums.txt`;
- Homebrew: `brew install jbox-web/tap/donico`;
- [aqua](https://aquaproj.github.io), through [mise](https://mise.jdx.dev),
  with the jbox-web registry configured. In a `mise.toml`:

```toml
[settings]
aqua.registries = ["https://github.com/jbox-web/aqua-registry"]

[tools]
"aqua:jbox-web/donico" = "3.0.0"
```

From source (Crystal >= 1.20):

```sh
git clone https://github.com/jbox-web/donico && cd donico
mise dev:build          # bin/donico
```

Check the install with `donico --version`, which prints the version, the commit
and the platform: `donico 3.0.0 (<commit>, linux/amd64)`.

## Quick start

In a repository that holds a `Dockerfile`, write a `donico.yml`. The smallest
useful one is below; [donico.example.yml](donico.example.yml) shows every key,
commented, and is meant to be copied and trimmed.

<!-- donico.yml -->
```yaml
registry: registry.example.com/base
image_name: myapp
image_builder: bake
matrix:
  - version: "1.0"
    distro: bookworm
    archs: [linux/amd64, linux/arm64]
    build_args:
      - APP_USER=app
    tags:
      - "%<version>s-%<distro>s"
      - latest
```

`donico` alone (or `donico help`) lists the tasks of the project. The listing
below is the real output of the binary on that file:

<!-- help -->
```
Usage:

  donico bookworm:1.0:build  # Build docker image for bookworm/1.0 ["linux/amd64", "linux/arm64"]
  donico bookworm:1.0:clean  # Clean docker image for bookworm/1.0 ["linux/amd64", "linux/arm64"]
  donico bookworm:1.0:login  # Login into docker image for bookworm/1.0 ["linux/amd64", "linux/arm64"]
  donico bookworm:1.0:push   # Push docker image for bookworm/1.0 ["linux/amd64", "linux/arm64"]
  donico bookworm:1.0:test   # Test docker image for bookworm/1.0 ["linux/amd64", "linux/arm64"]
  donico generate-files      # Generate GitlabCI matrix and Bakefile
  donico image-builder       # Print the configured image builder
  donico inspec              # Run the Inspec harness on an image
  donico licenses            # Print the third-party notices embedded in this binary
  donico lint-dockerfile     # Lint Dockerfile
  donico matrix              # Print the resolved matrix as JSON
  donico version             # Version
```

Each row of the matrix gets five tasks named `<distro>:<version>:<action>`.
`generate-files` writes the two files CI and `docker buildx` read:

```sh
donico generate-files
```

```
GitlabCI Matrix file generated
Bakefile generated
```

`.gitlab-ci/extends/.matrix.yml` holds one entry per row:

<!-- .matrix.yml -->
```yaml
# !!! THIS IS A GENERATED FILE !!! DON'T EDIT ME MANUALLY !!!
# Instead edit donico.yml and run donico generate-files
---
".matrix":
  parallel:
    matrix:
    - VERSION: '1.0'
      DOCKER_DISTRO: bookworm
```

and `docker-bake.hcl` one build target and one push target per row. Targets
are named `<distro>-<version with dots as dashes>-build|push`:

<!-- docker-bake.hcl -->
```hcl
# !!! THIS IS A GENERATED FILE !!! DON'T EDIT ME MANUALLY !!!
# Instead edit donico.yml and run donico generate-files

variable "BUILD_DATE" {
  validation {
    condition = BUILD_DATE != ""
    error_message = "The variable 'BUILD_DATE' must not be empty."
  }
}

########################
# BOOKWORM - myapp 1.0 #
########################

target "bookworm-1-0-build" {
  dockerfile = "Dockerfile"
  args = {
    APP_USER = "app"
    BUILD_DATE = "${BUILD_DATE}"
    DISTRO_NAME = "bookworm"
    MYAPP_VERSION = "1.0"
  }
  platforms = ["linux/amd64", "linux/arm64"]
  output    = [{ type = "docker" }]
  tags      = ["myapp/1.0/bookworm:${BUILD_DATE}"]
}

target "bookworm-1-0-push" {
  dockerfile = "Dockerfile"
  args = {
    APP_USER = "app"
    BUILD_DATE = "${BUILD_DATE}"
    DISTRO_NAME = "bookworm"
    MYAPP_VERSION = "1.0"
  }
  platforms = ["linux/amd64", "linux/arm64"]
  output    = [{ type = "registry" }]
  tags      = [
    "registry.example.com/base/myapp:1.0-bookworm",
    "registry.example.com/base/myapp:latest",
  ]
}
```

Both files start with a "generated file" warning and are meant to be committed.
Then:

```sh
donico bookworm:1.0:build     # docker buildx bake bookworm-1-0-build
donico bookworm:1.0:test      # InSpec against the image just built
donico bookworm:1.0:push      # docker buildx bake bookworm-1-0-push
```

The image built locally is tagged `<name>/<version>/<distro>:<timestamp>`
(here `myapp/1.0/bookworm:20261117093000`); the pushed tags are
`<registry>/<name>:<tag>` for each entry of `tags`.

## Tasks

| Task | What it does |
|---|---|
| `help` | Lists the tasks with their description, one per line, sorted by name. Also what plain `donico` runs. It needs a `donico.yml`; `donico --help` does not. |
| `version` | Prints the bare version (`3.0.0`). `donico --version` prints the one-line form with the commit and the platform. |
| `licenses` | Prints the third-party notices embedded in the binary. |
| `image-builder` | Prints the image builder, `bake`, alone on one line. |
| `generate-files` | Writes `.gitlab-ci/extends/.matrix.yml` and `docker-bake.hcl` (both are rendered before either is written). |
| `matrix` | Prints the resolved matrix as JSON on stdout (see [donico matrix](#donico-matrix)). |
| `lint-dockerfile` | Runs hadolint, in the linter image, on every distinct Dockerfile of the matrix. Prints what hadolint printed (stdout and stderr, in the order written) and exits 1 if any run failed; prints `Dockerfile is OK!` and exits 0 otherwise. Every Dockerfile is linted even after a failure. |
| `<distro>:<version>:build` | Checks the secrets, then replaces itself with `docker buildx bake <distro>-<version>-build`. `BUILD_DATE` is added to the inherited environment, where the bakefile reads it; the other build args are written in the bakefile and are not exported. |
| `<distro>:<version>:test` | Runs the InSpec harness on the build tag, with the row's [inputs](#inspec-inputs). With `test_variants`, once per variant. |
| `<distro>:<version>:push` | Checks the secrets, then replaces itself with `docker buildx bake <distro>-<version>-push`. |
| `<distro>:<version>:clean` | Runs `docker rmi <build tag>`. On failure, prints what docker said and exits 1. |
| `<distro>:<version>:login` | Replaces itself with `docker run -it --rm <build tag> /bin/bash`, plus one `-e NAME` per `login_env` entry. |
| `inspec <mode> <image> [inputs...]` | The InSpec harness called directly (see [donico inspec](#donico-inspec)). |

An unknown task, or a `<distro>:<version>` pair that is not in the matrix, exits
1 with the name and the list of the valid tasks. A task name is split on its
first and its last colon; neither a distro nor a version can hold one.

Every external command is logged before it runs (`exec: docker buildx bake ...`,
`run_cmd: ...`, `with_exit_status: ...`), on stdout, with the command line only,
never the environment. Setting `DONICO_QUIET` (to any value, even empty) turns
the logging off.

`build` and `push` replace the donico process with `docker`: its exit status is
donico's, and Ctrl-C reaches docker directly.

## Configuration: `donico.yml`

Keys donico does not know are ignored without a warning (`category`,
`description`, `github_repo`, `commit_linter`... are free for other tools). YAML
anchors, aliases and the merge key `<<:` are accepted, so rows can share their
common part:

<!-- donico.yml -->
```yaml
registry: registry.example.com/base
image_name: myapp
image_builder: bake

x-common: &common
  archs: [linux/amd64, linux/arm64]
  build_args: [APP_USER=app]

matrix:
  - <<: *common
    version: "1.0"
    distro: bookworm
  - <<: *common
    version: "1.0"
    distro: trixie
```

### Top-level keys

| Key | Default | Meaning |
|---|---|---|
| `registry` | none, **required** | Registry path the production tags are prefixed with: `<registry>/<name>:<tag>`. |
| `image_name` | none | Image name: letters, digits, `.`, `_`, `-` and `/`. May be left out when every matrix row sets its own. |
| `image_builder` | `bake` | The only supported value is `bake`. `docker` is refused with a message of its own. |
| `matrix` | one row, every default | List of rows (below). |
| `tools_registry` | the value of `registry` | Where the tool images (hadolint, InSpec) are looked for. |
| `docker_linter` | `<tools_registry>/hadolint:latest` | The full image run by `lint-dockerfile`. |
| `inspec_image` | `<tools_registry>/inspec:latest` | The full image run by the InSpec harness. |

A key written with an empty string (`registry: ""`) counts as not set.

### Matrix row keys

| Key | Default | Meaning |
|---|---|---|
| `image_name` | the top-level `image_name` | Name of this row's image. |
| `version` | `latest` | A **quoted string** of letters, digits, `.`, `_` and `-`. Unquoted, YAML reads `3.10` as the number 3.1: the file is refused rather than tagging an image under a version nobody wrote. |
| `distro` | `buster` | The distribution: letters, digits, `_` and `-`. With `version`, it names the row (`<distro>:<version>`): two rows with the same pair are refused, and so are two rows that give the same bake target (`1.0` and `1-0`). |
| `archs` | `["linux/amd64"]` | Platforms passed to bake. |
| `dockerfile` | `Dockerfile` | Dockerfile of this row, relative to the project directory. |
| `build_args` | none | `KEY=VALUE` list. `KEY` is letters, digits and underscores, not starting with a digit, and is given once. An empty value is legal. The value is plain text: `${...}` and `%{...}` reach the Dockerfile as written. The names donico injects (below) are reserved. |
| `test_args` | none | Extra InSpec inputs, `key=value` (not passed to the build). |
| `tags` | `["%<version>s-%<distro>s"]` | Tag patterns for the pushed image: letters, digits, `.`, `_`, `-` and the macros `%<distro>s`, `%<timestamp>s`, `%<version>s`; a literal `%` is not supported. |
| `secret_envs` | none | List of `{id: ...}`: build secrets read from an environment variable named `id`. |
| `secret_files` | none | List of `{id: ..., src: ...}`: build secrets read from the file `src`. |
| `test_variants` | none | List of lists of InSpec inputs: `test` runs once per list. |
| `login_env` | none | Names of the environment variables `login` forwards into the container. |

A row with no key at all is valid. When `matrix` is absent, the project has one
row with every default.

### Derived values

- **Timestamp.** When `CI_COMMIT_TIMESTAMP` is set and not empty, it is parsed
  as ISO 8601 and written as `%Y%m%d%H%M%S` in its own offset
  (`2026-11-17T09:30:00+01:00` gives `20261117093000`). Otherwise it is the
  current local date, `%Y%m%d`. It is computed once per run, so every image of
  a run shares one build tag, even across midnight.
- **Build tag.** `<name>/<version>/<distro>:<timestamp>`.
- **Injected build args.** `DISTRO_NAME`, `BUILD_DATE` and `<NAME>_VERSION`,
  where `<NAME>` is the image name in upper snake case (`MyApp` gives
  `MY_APP`, `docker-in-docker` gives `DOCKER_IN_DOCKER`, `team/node.js` gives
  `TEAM_NODE_JS`). Declared and injected args are merged and sorted (byte
  order: upper case before lower case). A row cannot declare a build arg of one
  of these three names: the file is refused.
- **Production tags.** Each tag pattern expanded, prefixed with
  `<registry>/<name>:`, sorted.
- <a id="inspec-inputs"></a>**InSpec inputs.** Build args, test args and
  injected args, sorted, with the name lower-cased and the value untouched
  (`APP_USER=Bob` becomes `app_user=Bob`).

### Tool images

Two images are run besides your own: the Dockerfile linter and InSpec. For each,
the first match wins:

1. the explicit key: `docker_linter`, `inspec_image`;
2. `<tools_registry>/hadolint:latest`, `<tools_registry>/inspec:latest`, where
   `tools_registry` defaults to `registry`.

No host is built into donico. A project whose tool images live elsewhere than
under its own `registry` sets one key:

<!-- donico.yml -->
```yaml
registry: registry.example.com/images
tools_registry: registry.example.com/tools
image_name: myapp
image_builder: bake
matrix:
  - version: "1.0"
    distro: bookworm
```

and a project that needs one image of its own names it in full:

<!-- donico.yml -->
```yaml
registry: registry.example.com/base
inspec_image: registry.example.com/ci/inspec:6
docker_linter: registry.example.com/ci/hadolint:2.12
image_name: myapp
image_builder: bake
matrix:
  - version: "1.0"
    distro: bookworm
```

The InSpec image runs with the docker socket of the host mounted, which gives
it the control of that docker daemon. `latest` follows whatever is pushed
under that name: on a shared registry, name the image by its digest
(`inspec_image: registry.example.com/ci/inspec@sha256:...`) so that the one
that runs is the one that was reviewed.

`lint-dockerfile` runs, for each Dockerfile:

```sh
docker run --pull always --rm -e MISE_IGNORED_CONFIG_PATHS=/app/mise.toml \
  -v <project>:/app <docker_linter> hadolint /app/<dockerfile>
```

The project is mounted at `/app` and the working directory stays inside it, so
hadolint finds the project's own `.hadolint.yaml`.

### Several InSpec runs: `test_variants`

By default `test` runs InSpec once. With `test_variants`, it runs once per
variant, with the variant's inputs appended to the row's:

<!-- donico.yml -->
```yaml
registry: registry.example.com/base
image_name: myapp
image_builder: bake
matrix:
  - version: "1.0"
    distro: bookworm
    test_variants:
      - ["run_mode=default"]
      - ["run_mode=dind"]
```

All variants run even after one failed, so a single run reports every failure,
and `test` exits 1 if any of them failed. An interrupt ends the whole task
(see [Ctrl-C](#interrupting-test)).

### Environment for `login`: `login_env`

`login_env` lists variable names. `login` adds a bare `-e NAME` for each, so
docker copies the value from the environment of the call and it never appears in
an argument list:

<!-- donico.yml -->
```yaml
registry: registry.example.com/base
image_name: myapp
image_builder: bake
matrix:
  - version: "1.0"
    distro: bookworm
    login_env: [SSH_PRIVATE_KEY, HOST_KEYSCAN]
```

gives `docker run -it --rm -e SSH_PRIVATE_KEY -e HOST_KEYSCAN <build tag> /bin/bash`.

## The `.env` file

If the project directory holds a `.env`, donico loads it at start-up, for every
task. A variable already set in the process environment is not overridden. The
variables are visible to the tasks, to the secret check, and to every command
and hook donico starts.

<!-- .env -->
```sh
# Comments and blank lines are ignored.
HOST_KEYSCAN=github.com ssh-rsa AAAA
export SSH_PRIVATE_KEY="line one # not a comment"
REGISTRY_USER='bob'
TOKEN=a=b=c
EMPTY=
```

The syntax is deliberately plain:

- one `KEY=VALUE` per line; `KEY` is letters, digits and underscores, not
  starting with a digit; an optional `export ` prefix; spaces around the `=`
  are ignored;
- the value is optionally wrapped in single or double quotes. Quotes are
  removed and nothing inside them is interpreted: no escape sequences, and a
  `#` inside quotes is part of the value. Only the first `=` splits the line;
- an unquoted value ends at a ` #` (whitespace, then `#`) which starts a
  comment; `a#b` stays whole;
- Windows line endings and a leading byte order mark are accepted;
- **no interpolation and no command substitution**: `$VAR`, `${VAR}` and
  `$(cmd)` are plain text. donico never executes anything found in that file.

A bad line is an error that names the line number and never its content, since
the content may be a secret: `.env: line 3 is not KEY=VALUE`,
`.env: line 3 has an unterminated quote` or `.env: line 3 holds a NUL character`.

## Secrets

Declare build secrets per row:

<!-- donico.yml -->
```yaml
registry: registry.example.com/base
image_name: myapp
image_builder: bake
matrix:
  - version: "1.0"
    distro: bookworm
    secret_envs:
      - id: GITHUB_TOKEN
    secret_files:
      - id: aws
        src: "${HOME}/.aws/credentials"
      - id: netrc
        src: .netrc
```

They become `secret` entries of the bake targets: `type = "env"` with the `id`
for `secret_envs` (the secret is the environment variable of that name), and
`type = "file"` with `id` and `src` for `secret_files`.

Before `build` and `push` start docker, donico checks that every declared secret
is available, and fails with every problem at once, one per line:

```
donico: secret "GITHUB_TOKEN" is declared in secret_envs but the variable GITHUB_TOKEN is not set
```

```
donico: secret "netrc" is declared in secret_files but its src ".netrc" does not exist
```

Without this check, buildx falls back to reading a file named after the missing
variable and reports `failed to stat GITHUB_TOKEN`, which hides the cause. The
variables are looked up in the process environment completed by `.env` (a
variable set to the empty string counts as set). A relative `src` is relative
to the project directory; a `src` that contains `${` is an HCL reference that
bake resolves itself, so donico does not check it.

## The InSpec harness

`<distro>:<version>:test` runs a built-in harness on the build tag:

1. **Inputs.** Every `key=value` input is exported as an environment variable
   (split on the first `=` only), so the scripts below can read them.
2. **Start a container** from the image: `docker run --rm -d <image> /bin/bash
   -c "while true; do sleep 1; done"`, or `bin/inspec-container-up` when the
   project provides it. Its standard output is the container id.
3. **Run InSpec**, from the InSpec image, against `docker://<container id>`: the
   project mounted at `/app`, the docker socket mounted, on `/app/test/`, with
   `--chef-license accept-silent --no-create-lockfile --show-progress`, the
   words of `.inspecrc` when it exists, and `--input ...` when there are inputs
   (each input is one argument, even if its value holds spaces).
4. **Remove the container**, always, including after a failure or an interrupt:
   `bin/inspec-container-down` when the project provides it, `docker kill <id>`
   otherwise (the container was started with `--rm`).

The tests live in the project's `test/` directory; the only mode is `donico`.

### Extension points

All three are optional files of the project directory.

| File | Role |
|---|---|
| `bin/inspec-container-up` | Replaces step 2. It must be executable. Run from the project directory with three arguments: the mode (`donico`), the image, and the inputs joined by single spaces (one argument, possibly empty). Its environment is the process environment completed by `.env`, plus one variable per input. **Its standard output, trimmed, is the container id**; its standard error goes to your terminal. |
| `bin/inspec-container-down` | Replaces the removal in step 4. Executable. One argument: the container id (empty when the start printed nothing). Same environment, same working directory. |
| `.inspecrc` | Extra arguments for `inspec exec`: the file is split on whitespace, lines included, and the words are inserted before `--input`. |

A file that exists but is not executable is an error
(`<path> is not executable`), not a silent fallback.

### Exit status of `test`

The status is the first that applies:

1. **128 + n** when the harness received signal `n` (see below);
2. otherwise the status of the cleanup, when it is not 0: `bin/inspec-container-down`
   when the project has one, the built-in `docker kill` otherwise. A failed
   cleanup wins over the status of InSpec and over a failed start;
3. otherwise the status of the container start (the docker call or
   `bin/inspec-container-up`), when it is not 0 (InSpec is not run then);
4. otherwise InSpec's own status.

With `test_variants` the task exits 0 when every variant passed and 1 as soon as
one did not (an interrupt returns its own code instead).

### Interrupting `test`

<a id="interrupting-test"></a>On Ctrl-C (SIGINT) or SIGTERM, donico passes the
signal on to the child it is running (InSpec, or `bin/inspec-container-up`),
waits for it, removes the test container, and exits with 128 + the signal
number: **130** for Ctrl-C, 143 for SIGTERM. With `test_variants`, the variants
that had not started are skipped. A signal donico receives during the removal
itself is recorded but not forwarded, so a cancelled CI job, which signals
donico alone, never kills its own cleanup.

One case is not covered. In a terminal, Ctrl-C goes to every process of the
foreground group, the removal command included: a second Ctrl-C typed while
the container is being removed can stop that command, and the container, which
runs until it is killed, is then left behind. `docker ps` shows it; `docker
kill <id>` removes it.

## `donico matrix`

Prints the resolved matrix as JSON: one object per row, with everything donico
derived from it, for scripts that need to iterate the matrix. For the quick
start (with `CI_COMMIT_TIMESTAMP=2026-11-17T09:30:00+01:00`):

<!-- matrix.json -->
```json
[
  {
    "name": "myapp",
    "version": "1.0",
    "distro": "bookworm",
    "archs": [
      "linux/amd64",
      "linux/arm64"
    ],
    "dockerfile": "Dockerfile",
    "build_args": [
      "APP_USER=app",
      "BUILD_DATE=20261117093000",
      "DISTRO_NAME=bookworm",
      "MYAPP_VERSION=1.0"
    ],
    "test_args": [],
    "tags": [
      "%<version>s-%<distro>s",
      "latest"
    ],
    "secret_envs": [],
    "secret_files": [],
    "test_variants": [],
    "login_env": [],
    "build_tag": "myapp/1.0/bookworm:20261117093000",
    "prod_tags": [
      "registry.example.com/base/myapp:1.0-bookworm",
      "registry.example.com/base/myapp:latest"
    ],
    "build_target": "bookworm-1-0-build",
    "push_target": "bookworm-1-0-push"
  }
]
```

`build_args` holds the declared and injected args, sorted; `build_tag` and
`prod_tags` are the values described in [Derived values](#derived-values);
`build_target` and `push_target` are the bake targets.

## `donico inspec`

```
donico inspec <mode> <image> [inputs...]
```

Runs the harness directly on an image, with the InSpec image of the project. It
is what `<distro>:<version>:test` calls internally. `mode` must be `donico`
(anything else fails with `unknown inspec mode: <mode> (supported: donico)`
before any container starts). Inputs are `key=value` words.

An input that starts with a dash would be read as an option: it goes after a
`--`, which ends the options.

```sh
donico inspec donico myapp/1.0/bookworm:20261117093000 run_mode=dind
donico inspec donico myapp/1.0/bookworm:20261117093000 -- -odd=value
```

## Environment variables read

| Variable | Effect |
|---|---|
| `CI_COMMIT_TIMESTAMP` | ISO 8601 timestamp that replaces the current date in the build tag and the `BUILD_DATE` arg (see [Derived values](#derived-values)). Unset or empty counts as unset; anything else that is not ISO 8601 is an error. |
| `DONICO_QUIET` | When set, to any value, the `exec: ...` log lines are not printed. |

`.env` can set both. Variables named by `secret_envs` and `login_env` are read
from the environment of the docker call, and `BUILD_DATE` is written to it by
`build` and `push`: none of them is put on a command line.

## Errors and exit codes

Every error donico raises on purpose is one line on stderr, `donico: <message>`,
with exit status 1: a missing or invalid `donico.yml` (the message names the key
and the offending value, for example `donico.yml: matrix[0].version must be a
quoted string (YAML read it as 3.1; quote it as written in the file)`), a bad `.env`, an unknown task or option,
an unset secret, an executable not found in the `PATH` (`docker not found in
PATH`), a file that is executable but cannot be started (`<path> cannot be
executed: <reason>`), a generated file that cannot be written (`cannot write
docker-bake.hcl: <reason>`). Every failure donico foresees ends this way, with
no stack trace; a Crystal backtrace can only come from a bug in donico, which
is worth reporting.
Otherwise the exit status is that of the command donico ran: docker's for
`build`, `push` and `login` (donico is replaced by it), 1 for `clean` and
`lint-dockerfile` when docker failed, and the status of the
[harness](#exit-status-of-test) for `test`.

## Coming from the Ruby gem

donico 3 is a rewrite of the Ruby gem. Same `donico.yml`, same task names, same
generated files, same docker commands, same exit statuses; the 94 `donico.yml`
files of the fleets it was written for produce byte-identical generated files
and identical docker commands (the checks are in `scripts/oracle/`). What
changes, and what to do in a repository:

1. **The `docker` backend is gone.** `image_builder: docker` is refused with a
   message saying so; the default is now `bake`. Set `image_builder: bake`
   (or leave it out). A missing `registry` now gets a message that names the key.
2. **No ERB in `donico.yml`.** The file is plain YAML; nothing in it is
   evaluated.
3. **No Rake hooks.** `before`, `after` and `redefine` in a `Rakefile` have no
   equivalent; the three uses found in practice have keys instead:
   `test_variants` (run the InSpec suite several times) and `login_env` (pass
   variables to `login`); downloading the gem before a build is no longer needed.
   There is no `Rakefile`, `Gemfile`, Bundler binstub or Ruby toolchain in an
   image repository any more: delete `Rakefile`, `Gemfile`, `Gemfile.lock`,
   `bin/rake`, `bin/inspec` and the other binstubs, and the `watch_files` entry
   that ran `bin/rake generate-files`; call `donico <task>` instead of
   `bin/rake <task>`. `bin/inspec-container-up` and `bin/inspec-container-down`
   stay: they are the extension points above.
4. **Tool images from configuration.** The linter and InSpec image hosts were
   constants of each fleet's fork. They now come from `tools_registry`,
   `docker_linter` and `inspec_image` (see [Tool images](#tool-images)); with none
   set they are `<registry>/hadolint:latest` and `<registry>/inspec:latest`, so a
   repository whose `registry` is that path needs no edit. One that keeps its
   tools elsewhere sets `tools_registry`.
5. **`.env` is loaded at start-up** by donico itself, for every task, without
   overriding variables already set. The `dotenv` gem and the hooks that called
   it are no longer needed. Plain syntax only (see [The `.env` file](#the-env-file)).
6. **`donico` instead of `bin/rake`.** `help` and the generated-file warning
   (`Instead edit donico.yml and run donico generate-files`) say `donico`. The
   first `generate-files` therefore changes that one line in the committed files.
7. **Two new commands**, `matrix` and `inspec`, and a `licenses` command.
8. **Version numbering restarts at 3.0.0**, so it cannot be confused with the
   `2.0.x` gems. `donico version` prints the version of the binary.
9. **Error messages are rewritten**: one line, prefixed `donico: `, no Ruby
   class name (`3.1 (Float)`, `got NilClass`). They carry the same information:
   the key, the value, what to write instead. A script that matched the old
   wording must be updated.
10. **An empty `CI_COMMIT_TIMESTAMP` counts as unset.** The gem failed on it.
11. **The InSpec harness is part of the binary**, and logs the docker calls it
    makes (`exec: bin/inspec ...` is gone). The gem executed the repository's
    `bin/inspec`, in all cases the unmodified binstub of the gem's own harness;
    it can be deleted.
12. **`lint-commits` is gone**, and the `commit_linter` key with it (ignored
    when present). donico deals with images, not commit messages: remove the CI
    job that runs `lint-commits` and use a commit linter of your own.
13. **The `exec: ...` log line is always printed**, even when stdout is not a
    terminal. The gem lost it there, because Ruby did not flush its buffer
    before replacing the process.
14. **Captured output is in order**: for `clean` and `lint-dockerfile`, stdout
    and stderr come out interleaved in the order they were written. The gem
    returned stdout alone on success and stdout then stderr on failure.
15. **An InSpec input whose value holds spaces is one argument.** The gem's
    shell split it into several. None of the known repositories has one.
16. **`version` is typed by Crystal's YAML parser**, which differs from Ruby's on
    a few unquoted forms: `1e3` and `0o17` are numbers for Crystal (so refused)
    and strings for Ruby. Quote the version, which the error message asks for,
    and the difference disappears.
17. **Two rows with the same `distro` and `version` are refused** when the file
    loads. Rake silently merged their tasks.
18. **Names are checked when the file loads**, where the gem wrote a
    `docker-bake.hcl` that bake then refused: a `distro` holds letters, digits,
    `_` and `-`; a `version` the same and `.`; an `image_name` those and `/`;
    a tag what docker accepts; a build arg name is an identifier. Two rows
    whose targets collide (`1.0` and `1-0`) are refused, and an empty string
    counts as a missing value.
19. **A build arg is declared once, and never under a name donico injects**
    (`DISTRO_NAME`, `BUILD_DATE`, `<NAME>_VERSION`). The gem wrote both lines
    and bake kept the last one in alphabetical order of the values.
20. **A build arg value and a Dockerfile path are plain text**: `${...}` and
    `%{...}` in them are written so that bake leaves them alone. The gem let
    bake interpolate them, which failed on a name it did not know. The `src` of
    a secret file is unchanged: `${HOME}` there is still resolved by bake.
21. **`<NAME>_VERSION` only holds letters, digits and underscores**: an image
    named `team/node.js` gets `TEAM_NODE_JS_VERSION`.
22. **`build` and `push` export `BUILD_DATE` only.** The gem exported every
    build arg into the environment of docker, where one named `PATH`,
    `DOCKER_HOST` or `BUILDX_BUILDER` reconfigured the docker client. The
    values are in `docker-bake.hcl` either way: the build gets the same args.

Anything else that differs from the gem is a bug: please report it.

## Development

```sh
mise dev:deps && mise dev:spec        # specs, in process, no docker
mise dev:spec-mt                      # the same, multi-threaded
mise dev:ameba && mise dev:format-check
mise dev:build                        # bin/donico
mise release:static                   # static Linux binaries and packages, in dist/ (docker)
```

Always go through `mise`: the compiling tasks generate `licenses/` first, and
the spec, coverage, lint and release tasks carry a timeout (`dev:build`,
`dev:docs` and the format tasks do not). On macOS, `brew bundle` installs what
mise cannot; the Crystal language server that `mise.toml` lists needs
Homebrew libraries of its own, or `MISE_DISABLE_TOOLS=aqua:elbywan/crystalline`
to be skipped (see the Brewfile). The specs check this README: each
`donico.yml` example marked `<!-- donico.yml -->` is loaded through
`Config.load` and checked against what the text around it announces, each `.env`
example is parsed, and the listing, the `.matrix.yml`, the `docker-bake.hcl` and
the JSON of the quick start are compared with what the binary generates from
the quick-start `donico.yml`.

The comparison with the Ruby gem is done by two scripts that run both on local
clones of the image repositories; see [scripts/oracle/README.md](scripts/oracle/README.md).

Releases are built by [crystalreleaser](https://github.com/jbox-web/crystalreleaser)
from `.crystalreleaser.yml`: static linux/amd64 and linux/arm64 binaries built
in an Alpine image with Alpine's own Crystal, darwin binaries, archives,
checksums, `.deb` and `.rpm` packages, a Homebrew formula and an aqua registry
entry.

## License

MIT, see [LICENSE](LICENSE). `donico licenses` prints the notices of what the
binary embeds.
