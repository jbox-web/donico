# donico

[![CI](https://github.com/jbox-web/donico/actions/workflows/ci.yml/badge.svg)](https://github.com/jbox-web/donico/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/jbox-web/donico?sort=semver)](https://github.com/jbox-web/donico/releases/latest)
[![License: MIT](https://img.shields.io/github/license/jbox-web/donico)](LICENSE)

donico builds, tests, pushes and cleans Docker images from one
`donico.yml` file, locally and in CI. You describe the images of a repository as
a matrix (a version and a distribution per row); donico turns it into
`docker buildx bake` targets and a set of named tasks:

```
donico bookworm:1.0:build
donico bookworm:1.0:test
donico bookworm:1.0:push
```

It is a single binary: static on Linux; on macOS it loads only libraries every
Mac has (libSystem, libiconv, libz), OpenSSL being linked in. It reads
`donico.yml` in the current directory, needs `docker` (with buildx) on the
`PATH`, and does not know any registry host: every image it uses comes from
your configuration. The fleet commands also need CA certificates for their
HTTPS requests (see [`repos update`](#repos-update)): the .deb and .rpm
packages depend on `ca-certificates` for that.

The binary answers to two names. As `donico` it works inside one image
repository, as described below. As `donico-manager`, a symbolic link to it that
the archives, the packages, the Homebrew formula and the aqua entry install, it
works on a whole fleet of image repositories: clone them, run git in each, pin
them to a donico version, follow the upstream versions of the images and
regenerate the fleet's documentation (see
[Fleet commands](#fleet-commands-donico-manager)).

What it does for a repository of images:

- **Generates** `docker-bake.hcl` and a GitLab CI job matrix from the
  `donico.yml`, so the committed files never drift from it.
- **Builds and pushes** one matrix row at a time with `docker buildx bake`,
  after checking that every declared secret is available.
- **Tests** the built image with [Chef InSpec](https://docs.chef.io/inspec/),
  in a throwaway container that is always removed.
- **Lints** the Dockerfiles with hadolint, **cleans** the local build tag and
  opens a **login** shell in an image.

A second backend, `image_builder: debuerreotype`, builds the Debian base images
themselves, from nothing: see
[Debian root filesystems](#debian-root-filesystems-image_builder-debuerreotype).

## Installation

From a release (the Linux binaries are static). The archives, the packages,
the Homebrew formula and the aqua entry hold `donico` and, beside it,
`donico-manager`, a symbolic link to the same binary:

- the `.tar.gz` archives, the `.deb` and the `.rpm` of the
  [GitHub release page](https://github.com/jbox-web/donico/releases), with
  `checksums.txt` (the packages depend on `ca-certificates`: the fleet
  commands ask the GitHub API over HTTPS);
- Homebrew: `brew install jbox-web/tap/donico`;
- [mise](https://mise.jdx.dev), in either of two ways.

Straight from the GitHub release, with nothing to configure: mise picks the
archive of the platform itself. In a `mise.toml`:

```toml
[tools]
"github:jbox-web/donico" = "3.2.0"
```

Or through [aqua](https://aquaproj.github.io), with the jbox-web registry
configured:

```toml
[settings]
aqua.registries = ["https://github.com/jbox-web/aqua-registry"]

[tools]
"aqua:jbox-web/donico" = "3.2.0"
```

From source (Crystal >= 1.20):

```sh
git clone https://github.com/jbox-web/donico && cd donico
mise dev:build          # bin/donico
```

Check the install with `donico --version`, which prints the version, the commit
and the platform: `donico 3.2.0 (<commit>, linux/amd64)`. `donico-manager
--version` prints the same under its second name. A build from source has the
link too: `mise dev:build` writes `bin/donico-manager` beside `bin/donico`.

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
| `version` | Prints the bare version (`3.2.0`). `donico --version` prints the one-line form with the commit and the platform. |
| `licenses` | Prints the third-party notices embedded in the binary. |
| `image-builder` | Prints the image builder, `bake` or `debuerreotype`, alone on one line. |
| `generate-files` | Writes `.gitlab-ci/extends/.matrix.yml` and `docker-bake.hcl` (both are rendered before either is written). With `image_builder: debuerreotype`, the matrix file alone. |
| `matrix` | Prints the resolved matrix as JSON on stdout (see [donico matrix](#donico-matrix)). |
| `lint-dockerfile` | Runs hadolint, in the linter image, on every distinct Dockerfile of the matrix. Prints what hadolint printed (stdout and stderr, in the order written) and exits 1 if any run failed; prints `Dockerfile is OK!` and exits 0 otherwise. Every Dockerfile is linted even after a failure. |
| `<distro>:<version>:build` | Checks the secrets, then replaces itself with `docker buildx bake <distro>-<version>-build`. `BUILD_DATE` is added to the inherited environment, where the bakefile reads it; the other build args are written in the bakefile and are not exported. |
| `<distro>:<version>:test` | Runs the InSpec harness on the build tag, with the row's [inputs](#inspec-inputs). With `test_variants`, once per variant. |
| `<distro>:<version>:push` | Checks the secrets, then replaces itself with `docker buildx bake <distro>-<version>-push`. |
| `<distro>:<version>:clean` | Runs `docker rmi <build tag>`. On failure, prints what docker said and exits 1. |
| `<distro>:<version>:login` | Replaces itself with `docker run -it --rm <build tag> /bin/bash`, plus one `-e NAME` per `login_env` entry. |
| `inspec <mode> <image> [inputs...]` | The InSpec harness called directly (see [donico inspec](#donico-inspec)). |

The five row tasks above are those of the `bake` backend. With
`image_builder: debuerreotype` a row has three, `build`, `push` and `clean`,
which do something else under the same names: see
[Debian root filesystems](#debian-root-filesystems-image_builder-debuerreotype).

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
| `image_builder` | `bake` | `bake`, or `debuerreotype` for [Debian root filesystems](#debian-root-filesystems-image_builder-debuerreotype), which has its own keys and ignores `image_name` and the bake row keys. `docker` is refused with a message of its own. |
| `matrix` | one row, every default | List of rows (below). |
| `tools_registry` | the value of `registry` | Where the tool images (hadolint, InSpec, and debuerreotype for that backend) are looked for. |
| `docker_linter` | `<tools_registry>/hadolint:latest` | The full image run by `lint-dockerfile`. |
| `inspec_image` | `<tools_registry>/inspec:latest` | The full image run by the InSpec harness. |

A key written with an empty string (`registry: ""`) counts as not set.

### Matrix row keys

These are the row keys of the `bake` backend.

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

Two images are run besides your own: the Dockerfile linter and InSpec (the
debuerreotype backend has a third one, resolved the same way from
`debuerreotype_image`). For each, the first match wins:

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

## Debian root filesystems: `image_builder: debuerreotype`

The `bake` backend builds images *from* a base image. This one builds the base
images themselves: a Debian root filesystem made by
[debuerreotype](https://github.com/debuerreotype/debuerreotype), once per
architecture, each one packed as a tarball; the tarballs are then assembled into
one multi-arch image, `<registry>/<distro>`, and pushed. It replaces "danico",
the Rakefile that used to do this (see [Coming from danico](#coming-from-danico)).

The recipe, that is the list of debuerreotype commands, is part of the binary:
the repository holds no script. It holds:

- `donico.yml`;
- `config/apt/<version>-<distro>.list`, the `sources.list` of the image, one per
  row (`config/apt/13-trixie.list`), and `config/apt/apt-no-check` when a row
  is `eol`;
- an empty `build/` directory, where the tarballs are written (ignore its
  content in git; donico creates it when it is missing);
- the `Dockerfile` that turns the tarballs into an image:

```dockerfile
FROM scratch
ARG DISTRO
ARG TARGETARCH
ARG BUILD_TIMESTAMP
ADD build/${DISTRO}-${TARGETARCH}-${BUILD_TIMESTAMP}.tar /
CMD ["bash"]
```

<!-- donico.yml debuerreotype -->
```yaml
registry: registry.example.com/debian
image_builder: debuerreotype
tools_registry: registry.example.com/tools
apt_proxy: http://apt-proxy.example.com:3142
matrix:
  - distro: trixie
    version: "13"
    archs: [linux/amd64, linux/arm64]
  - distro: bookworm
    version: "12"
    archs: [linux/amd64, linux/arm64]
```

`donico help` lists three tasks per row:

<!-- help debuerreotype -->
```
Usage:

  donico bookworm:12:build  # Build root filesystem for bookworm/12 ["linux/amd64", "linux/arm64"]
  donico bookworm:12:clean  # Clean root filesystem for bookworm/12 ["linux/amd64", "linux/arm64"]
  donico bookworm:12:push   # Push docker image for bookworm/12 ["linux/amd64", "linux/arm64"]
  donico generate-files     # Generate GitlabCI matrix
  donico image-builder      # Print the configured image builder
  donico inspec             # Run the Inspec harness on an image
  donico licenses           # Print the third-party notices embedded in this binary
  donico lint-dockerfile    # Lint Dockerfile
  donico matrix             # Print the resolved matrix as JSON
  donico trixie:13:build    # Build root filesystem for trixie/13 ["linux/amd64", "linux/arm64"]
  donico trixie:13:clean    # Clean root filesystem for trixie/13 ["linux/amd64", "linux/arm64"]
  donico trixie:13:push     # Push docker image for trixie/13 ["linux/amd64", "linux/arm64"]
  donico version            # Version
```

There is no `test` and no `login`: the image is pushed straight from the
tarballs and never exists in the local docker.

### The three tasks

| Task | What it does |
|---|---|
| `<distro>:<version>:build` | For each arch, in the order of `archs`, runs the build script in a container of the debuerreotype image (the command is below). The first arch that fails ends the task with the exit status of its `docker run`. Before any container starts, it checks that the files the script copies exist (`config/apt/<version>-<distro>.list`, and `config/apt/apt-no-check` for an `eol` row), that no build directory of the row and the timestamp is left from an earlier build (debuerreotype refuses one: run `clean` first), and creates `build/` if needed. INT and TERM are passed on to the running `docker run`, no further arch is started and the task exits with 128 + the signal number. |
| `<distro>:<version>:push` | Checks that the tarball of every arch is there, reads `etc/debian_version` from the tarball of the first arch (`tar -O -xf`), then replaces itself with `docker buildx build`, which pushes the image under four tags (below). A missing tarball is a one-line error naming the file and the `build` task; a tarball whose `etc/debian_version` is not a release number (`trixie/sid` on testing) is refused. |
| `<distro>:<version>:clean` | Removes from `build/` every directory and tarball named `<distro>-<arch>-*`, for each arch of the row, whatever the timestamp. The files belong to root (they were written in the build container), so it runs `sudo rm -rf <paths>`, or `rm -rf <paths>` when donico itself runs as root. |

`build` runs, for each arch:

```sh
docker run --hostname debuerreotype --init --interactive --rm --pull always \
  --cap-add SYS_ADMIN --cap-drop SETFCAP --security-opt apparmor=unconfined \
  --tmpfs /tmp:dev,exec,suid,noatime --env TMPDIR=/tmp --workdir /workdir \
  --mount type=bind,src=<project>/build,dst=/workdir \
  --mount type=bind,src=<project>/config,dst=/config \
  <debuerreotype image> bash -euc '<script>'
```

where `<script>` is the recipe rendered for the row and the arch, its commands
joined by `;`. For `trixie` on `linux/amd64` in the example above, run on
2026-11-18, these are the commands, one per line here:

<!-- script debuerreotype -->
```sh
export http_proxy=http://apt-proxy.example.com:3142
debuerreotype-init --arch=amd64 --debian --non-debian trixie-amd64-20261117 trixie http://deb.debian.org/debian
debuerreotype-chroot trixie-amd64-20261117 groupadd --gid 65532 nonroot
debuerreotype-chroot trixie-amd64-20261117 useradd --uid 65532 --gid 65532 --home-dir /home/nonroot --shell /bin/bash --create-home nonroot
debuerreotype-chroot trixie-amd64-20261117 mkdir /app
debuerreotype-chroot trixie-amd64-20261117 chown -R nonroot.nonroot /app
debuerreotype-minimizing-config trixie-amd64-20261117
cp --verbose /config/apt/13-trixie.list trixie-amd64-20261117/etc/apt/sources.list
debuerreotype-apt-get trixie-amd64-20261117 -o Acquire::http::Proxy=http://apt-proxy.example.com:3142 update
debuerreotype-apt-get trixie-amd64-20261117 -o Acquire::http::Proxy=http://apt-proxy.example.com:3142 dist-upgrade -y
rm -f trixie-amd64-20261117/etc/apt/sources.list.d/*
debuerreotype-slimify trixie-amd64-20261117
debuerreotype-chroot trixie-amd64-20261117 find /var/log -type f -delete
debuerreotype-tar trixie-amd64-20261117 trixie-amd64-20261117.tar
sha256sum trixie-amd64-20261117.tar
ls -hal
```

The image gets a `nonroot` user and group (65532) and an `/app` directory owned
by it. Without a proxy in use, the `export` line is absent and the two
`debuerreotype-apt-get` lines lose their `-o` option. An `eol` row adds, after
the `chown`:

```sh
debuerreotype-gpgv-ignore-expiration-config <build dir>
cp --verbose /config/apt/apt-no-check <build dir>/etc/apt/apt.conf.d/
```

`push` runs, with `13.2` read from the tarball:

```sh
docker buildx build --no-cache --platform linux/amd64,linux/arm64 \
  --build-arg DISTRO=trixie --build-arg BUILD_TIMESTAMP=20261117 \
  -t registry.example.com/debian/trixie:latest \
  -t registry.example.com/debian/trixie:13 \
  -t registry.example.com/debian/trixie:13.2 \
  -t registry.example.com/debian/trixie:20261117 \
  -o type=registry .
```

The tags are `latest`, the Debian major, the full Debian version and the
timestamp. The major is the one of the tarball, not the row's `version`. The
builder must be able to build every platform of the row (QEMU, a
`docker buildx create` builder): donico does not set it up.

### Keys of this backend

At the top level, besides `registry` (required) and `tools_registry`:

| Key | Default | Meaning |
|---|---|---|
| `apt_proxy` | none | HTTP proxy the build goes through, for debootstrap and for apt. Used when set, unless `ENABLE_APT_PROXY` is `false` (process environment or `.env`). |
| `debuerreotype_image` | `<tools_registry>/debuerreotype:latest` | The full image the build runs in. It holds the debuerreotype scripts. |

In a matrix row:

| Key | Default | Meaning |
|---|---|---|
| `distro` | none, **required** | The Debian codename (`trixie`): lower-case letters and digits. It names the image, the build directories and the tarballs, so a distro is given once: two rows of one distro are refused. |
| `version` | none, **required** | The Debian major, as a **quoted string** (`"13"`). It names the row with `distro` (`trixie:13`) and the APT sources file, `config/apt/<version>-<distro>.list`. |
| `archs` | `["linux/amd64"]` | Platforms, each one once, among `linux/amd64`, `linux/arm64`, `linux/386`, `linux/ppc64le`, `linux/s390x`, `linux/riscv64` and `linux/mips64le`. The part after the slash names the build directory and the tarball; debootstrap is given the Debian name of the architecture (`i386` for `386`, `ppc64el` for `ppc64le`, `mips64el` for `mips64le`). `linux/arm` is not supported. |
| `eol` | `false` | `true` for a distribution that left the mirrors: expired signatures are accepted (see the two commands above). |
| `debootstrap_url` | `http://deb.debian.org/debian` | The mirror debootstrap installs from (`http://archive.debian.org/debian` for an `eol` row). |
| `debootstrap_opts` | `["--debian"]` | Options of `debuerreotype-init`, a list of strings. |
| `timestamp` | the day before the run (under GitLab CI, before the creation of the pipeline), `%Y%m%d` | A **quoted string** that is a valid docker tag: letters, digits, `.`, `_` and `-`, not starting with `.` or `-`, 128 characters at most. It is a tag of the image and a part of the name of the tarballs. |

`matrix` is required. `image_name` and the row keys of the `bake` backend
(`tags`, `build_args`, `dockerfile`...) are ignored, like any key donico does not
know; so are the keys above under `bake`.

`apt_proxy`, `debootstrap_url` and each item of `debootstrap_opts` are written
into the script bash runs, so they only hold letters, digits and
`_ @ % + = : , . / -`: a space, a quote, a `;` or a `$` is refused when the file
loads. `build` logs the command it runs, script included: a proxy or a mirror
URL that carries credentials shows in the build log and in the process list of
the host.

The default timestamp is the day before the task runs: `build` and `push` agree
on the tarballs as long as they run on the same day. Under GitLab CI they are
two jobs, which midnight may separate: when `CI_PIPELINE_CREATED_AT` is set and
not empty, the day is the one the pipeline was created on, in the offset of
that value (`2026-11-17T23:50:00+01:00` gives `20261116`), so every job of a
pipeline uses the same timestamp. `CI_COMMIT_TIMESTAMP` is not read by this
backend.

### Generated file and `matrix`

`generate-files` writes `.gitlab-ci/extends/.matrix.yml` and nothing else:

<!-- .matrix.yml debuerreotype -->
```yaml
# !!! THIS IS A GENERATED FILE !!! DON'T EDIT ME MANUALLY !!!
# Instead edit donico.yml and run donico generate-files
---
".matrix":
  parallel:
    matrix:
    - VERSION: '13'
      DOCKER_DISTRO: trixie
    - VERSION: '12'
      DOCKER_DISTRO: bookworm
```

so a CI job calls `donico "$DOCKER_DISTRO:$VERSION:build"`, as for any other
image repository. `donico matrix` prints, for the same example on 2026-11-18:

<!-- matrix.json debuerreotype -->
```json
[
  {
    "distro": "trixie",
    "version": "13",
    "archs": [
      "linux/amd64",
      "linux/arm64"
    ],
    "eol": false,
    "debootstrap_opts": [
      "--debian"
    ],
    "timestamp": "20261117",
    "image": "registry.example.com/debian/trixie",
    "tarballs": [
      "build/trixie-amd64-20261117.tar",
      "build/trixie-arm64-20261117.tar"
    ]
  },
  {
    "distro": "bookworm",
    "version": "12",
    "archs": [
      "linux/amd64",
      "linux/arm64"
    ],
    "eol": false,
    "debootstrap_opts": [
      "--debian"
    ],
    "timestamp": "20261117",
    "image": "registry.example.com/debian/bookworm",
    "tarballs": [
      "build/bookworm-amd64-20261117.tar",
      "build/bookworm-arm64-20261117.tar"
    ]
  }
]
```

Neither the proxy nor the debootstrap mirror is printed: either URL may carry
credentials.

### Coming from danico

For the same row and the same arch, the build script is the one danico rendered
from `templates/debian-build.erb`, byte for byte, and the `docker run` and
`docker buildx build` command lines are those of its `bin/build` and
`bin/push`. What changes in a repository:

1. **`danico.yml` becomes `donico.yml`**, with `image_builder: debuerreotype`
   added.
2. **`version` is quoted** (`"13"`), and **`archs` are platforms**
   (`linux/amd64` where danico had `amd64`). An explicit `timestamp` is quoted
   too.
3. **Task names are donico's**: `<distro>:<version>:build`, `:push` and
   `:clean`, where danico had `<distro>:build`. The per-arch tasks
   (`<distro>:<arch>:build`) are gone: `build` and `clean` always cover every
   arch of the row.
4. **`rake generate_matrix` becomes `donico generate-files`**, and the rows of
   `.matrix.yml` gain `VERSION`.
5. **The proxy follows `apt_proxy`.** It is used when the key is set, unless
   `ENABLE_APT_PROXY=false`. danico used it when `ENABLE_APT_PROXY` was
   `true`, which was the default in one fleet and not in the other, and with
   the variable `true` and no `apt_proxy` it exported an empty `http_proxy`. A
   repository that keeps `apt_proxy` and does not want the proxy sets
   `ENABLE_APT_PROXY=false`, or removes the key.
6. **`debuerreotype_image` defaults to `<tools_registry>/debuerreotype:latest`**
   instead of `debuerreotype/debuerreotype:0.12` on Docker Hub: no registry
   host is built into donico.
7. **The default timestamp follows the pipeline under GitLab CI**: the day
   before `CI_PIPELINE_CREATED_AT`, so that `build` and `push` agree when
   midnight falls between them. danico took the day before each job ran.
8. **`push` reads the Debian version from the tarball of the first arch** of
   the row, where danico read the `amd64` one whatever the row held, and it
   checks every tarball before starting.
9. **`build` returns the exit status of the failed `docker run`**, where rake
   returned 1. It refuses to start over a build directory left by an earlier
   build, where danico failed in the container, and it stops its container
   when it is interrupted.
10. **Only the platforms listed under `archs` are accepted**, each with its
    Debian name; danico took any name and translated `386` alone.
11. **Delete** `Rakefile`, `Gemfile`, `Gemfile.lock`, `bin/rake`, `bin/build`,
    `bin/push`, `bin/clean` and `templates/debian-build.erb`. Keep the
    `Dockerfile`, `config/apt/` and `build/.gitkeep`.

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

With `image_builder: debuerreotype` the rows have other fields: see
[Generated file and `matrix`](#generated-file-and-matrix).

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

## GitHub Actions

[donico-action](https://github.com/jbox-web/donico-action) is the GitHub Action
of donico: everything a job needs before it runs a task. It installs donico (at
the version the repository pins in its `mise.toml`, the archive checked against
the `checksums.txt` of the release), gives the matrix of `donico.yml` in the
form of `strategy.matrix.include`, and prepares Docker: the daemon to talk to,
the registry credentials, the binfmt handlers of a multi-platform build and a
buildx builder. The tasks stay plain `run:` steps:

```yaml
jobs:
  matrix:
    runs-on: ubuntu-24.04
    outputs:
      include: ${{ steps.donico.outputs.matrix }}
    steps:
      - uses: actions/checkout@v7
      - uses: jbox-web/donico-action@<ref>
        id: donico
        with:
          setup-docker: false

  images:
    needs: matrix
    runs-on: ubuntu-24.04
    strategy:
      fail-fast: false
      matrix:
        include: ${{ fromJSON(needs.matrix.outputs.include) }}
    steps:
      - uses: actions/checkout@v7
      - uses: jbox-web/donico-action@<ref>
        with:
          registry-auth: ${{ secrets.REGISTRY_DOCKER_CONFIG }}
      - run: donico ${{ matrix.task }}:build
      - run: donico ${{ matrix.task }}:test
      - run: donico ${{ matrix.task }}:push
        if: github.ref_name == 'master'
```

`<ref>` is a tag or a commit of the action. Each entry of the matrix holds
`distro`, `version` and `task`, the prefix of the row's task names
(`bookworm:1.0`).

GitHub Actions sets none of the variables donico reads under GitLab CI, so the
action sets them for the rest of the job: `CI_COMMIT_TIMESTAMP` to the date of
the commit being built, so that `build`, `test` and `push` agree on the build
tag whatever the time they run at, and `CI_PIPELINE_CREATED_AT` for the
`debuerreotype` backend. Its README lists its inputs, its outputs and what a
runner must provide.

## Environment variables read

| Variable | Effect |
|---|---|
| `CI_COMMIT_TIMESTAMP` | ISO 8601 timestamp that replaces the current date in the build tag and the `BUILD_DATE` arg (see [Derived values](#derived-values)). Unset or empty counts as unset; anything else that is not ISO 8601 is an error. |
| `DONICO_QUIET` | When set, to any value, the `exec: ...` log lines are not printed. |
| `ENABLE_APT_PROXY` | With `image_builder: debuerreotype`, `false` builds without the `apt_proxy` of `donico.yml`. Any other value, or none, leaves the proxy in use. |
| `CI_PIPELINE_CREATED_AT` | With `image_builder: debuerreotype`, the ISO 8601 time the default `timestamp` of a row is the day before, instead of the current date. Unset or empty counts as unset; anything else that is not ISO 8601 is an error. |

`.env` can set all four. Variables named by `secret_envs` and `login_env` are read
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
[harness](#exit-status-of-test) for `test`. With `image_builder: debuerreotype`:
the status of the first `docker run` that failed for `build` (128 + the signal
number when it was interrupted), docker's for `push` (donico is replaced by it), and that of `rm` or `sudo` for `clean`.

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

## Fleet commands: `donico-manager`

The same binary, called `donico-manager` (the name the packages, the archives,
Homebrew and aqua install beside `donico`, as a symbolic link), works on a whole
fleet of image repositories rather than inside one: clone them, run git in
each, pin them to a donico version, follow the upstream versions of the images
and regenerate the fleet's documentation. It replaces the `donico-manager` Ruby
gem, reads the same `donico-manager.yml`, and decides which program it is on the
name it was started under alone (`ln -s donico donico-manager` is a complete
installation).

It runs from the root of a fleet's configuration repository, the repository
that holds `donico-manager.yml` and, below its `workspace`, the clones of the
image repositories. It loads the `.env` of that repository the way donico loads
the one of an image repository (see [The `.env` file](#the-env-file)): the
process environment wins, so `GITHUB_TOKEN` can live there.

### The manifest: `donico-manager.yml`

Everything that tells one fleet from another is in this file, at the root of
the configuration repository:

<!-- donico-manager.yml -->
```yaml
registry:   registry.example.org/base
group:      git@git.example.org:images
workspace:  docker-images
browse_url: https://git.example.org/images
categories: [Base images, Web, Databases]

images:
  - ruby
  - grafana
  - postgres: { constrain: "17" }
  - traefik:  { pinned: true }
  - base:     { check_versions: false, bump_donico: false }
```

`repos clone` clones `ruby` from `git@git.example.org:images/ruby.git` into
`docker-images/ruby`. Images are always walked in sorted order (`base`,
`grafana`, `postgres`, `ruby`, `traefik`), whatever the order of the file.

| Key | Required | Default | What it is for |
|---|---|---|---|
| `registry` | yes | | Prefix of the published images, for the tags in the READMEs |
| `group` | yes | | Remote of the group: `repos clone` takes `<group>/<image>.git` |
| `workspace` | yes | | Directory of the clones, relative to the configuration repository (`../docker-images` and an absolute path work too) |
| `images` | yes | | The fleet: a bare name, or a name with its policies (below) |
| `browse_url` | for `update-readme` | | Web address of the group, for the links and badges of the root README |
| `ci_config_url` | for `repos update-readme` | | Link to the CI variables, quoted in each image README |
| `categories` | for `update-readme` | `[]` | Sections of the root README, in the order they are rendered |
| `registries` | for `heritage` | `{}` | `debian_jbox` and `debian_base`: the prefixes the heritage tree turns into virtual parents |
| `heritage_output` | no | `doc/image-heritage.md` | Where the heritage tree is written |
| `debian_images` | no | `[]` | Images whose tags take the `image_name` of each row, or its `distro`, rather than the image name |

Every missing required key is named at once. `commit_linter` is accepted and
ignored. Any other key is ignored.

| Policy | Default | Effect |
|---|---|---|
| `check_versions` | `true` | `false`: the image is not looked up at all (its version comes from its own tooling) |
| `bump_donico` | `true` | `false`: `bump-donico` leaves the repository alone |
| `constrain` | | `"17"`: the upstream lookup stays in that series (the greatest tag starting with `17.` or `v17.`) |
| `pinned` | `false` | The image is looked up and shown, but never offered as an update |

An unknown policy is refused, not ignored: read as "no policy", a typo would
treat the image like every other one, silently.

The fleet also provides, in the configuration repository, `templates/README.md`
(the head of the root README, which `update-readme` and `repos update` need;
the tables are appended to it) and, optionally, `todo.yml` (planned images, by
section: `images: { web: [caddy] }`).

### The commands

<!-- donico-manager help -->
```
Usage: donico-manager <command> [options]
donico-manager bump-donico VERSION          # Pin every image repo to a donico version
donico-manager update-readme                # Regenerate the root README from the donico.yml files
donico-manager heritage                     # Regenerate the image heritage tree from the Dockerfiles
donico-manager repos update                 # Interactive TUI: bump, regenerate, commit and push image versions
donico-manager repos list                   # List cloned repositories
donico-manager repos clone [REPO]           # Clone the image repositories into the workspace
donico-manager repos status [REPO]          # Run git status on the repositories
donico-manager repos diff [REPO]            # Run git diff on the repositories
donico-manager repos pull [REPO]            # Run git pull on the repositories
donico-manager repos gc [REPO]              # Run git gc on the repositories
donico-manager repos update-readme [REPO]   # Regenerate the README of each cloned image repo
donico-manager repos open-upstream [REPO]   # Open the upstream repository URLs in the browser
donico-manager repos check-hadolint [REPO]  # Run hadolint on the Dockerfiles
donico-manager repos check-security-spec    # Check that each cloned image has a security InSpec control
```

`[REPO]` restricts a command to one image of the manifest; an unknown name is
an error. `donico-manager` alone, and `--help` or `-h` anywhere on the line,
print this list (the `repos` part after `repos`). `--version` prints the
version of the binary.

- **The sweeps** (`repos status`, `diff`, `pull`, `gc`) run `git <command>` in
  each cloned repository, on the terminal, between separator lines
  (`---------------------`, `Enter in <name>`). A repository that is not cloned
  is said so (`<name>: not cloned, skipping`) and is not a failure. A failing
  repository does not stop the sweep: the last line says how many failed
  (`2 repository/repositories failed.`) and the status is 1. **`repos
  clone`** creates the workspace and clones each missing image from `group`
  (`Cloning <name>`), saying `<name>: already cloned, skipping` for the others.
- **`repos list`** prints `Repository exists: <name>` or `Repository missing:
  <name>` for every image; **`repos check-security-spec`** prints `OK: <name>`
  or `MISSING: <name>` for every cloned image, according to the presence of
  `test/default/controls/security_spec.rb`, with status 1 if one is missing.
  Names are coloured on a terminal only, and never when `NO_COLOR` holds a
  value or `TERM` is `dumb`.
- **`update-readme`** rewrites the root `README.md` from `templates/README.md`
  and the `donico.yml` of each cloned image; **`repos update-readme`**
  rewrites the `README.md` of each cloned image; **`heritage`** writes the
  tree of the images' `FROM` lines to `heritage_output`. The README generators
  read `donico.yml` as plain YAML, without donico's validation, so an image
  donico would refuse still gets its line.
- **`repos check-hadolint`** lints each image's Dockerfiles as
  `donico lint-dockerfile` does; **`repos open-upstream`** opens in the
  browser the upstream links found in the cloned image READMEs (with `open`,
  or `xdg-open` on Linux).
- **`bump-donico VERSION [--push]`** pins every image repository to a donico
  version: in its `mise.toml`, the version of the pin line is replaced, through
  either backend of [Installation](#installation),
  `"github:jbox-web/donico" = "<version>"` or
  `"aqua:jbox-web/donico" = "<version>"` (each line keeps its backend; a file
  that holds both has both replaced). Then `docker-bake.hcl` and the CI matrix
  are regenerated, and the change is committed (`build: bump to donico
  <version>`), then pushed with `--push`. `VERSION` must be the version of the
  binary that runs (`donico-manager --version`): the files it regenerates are
  this binary's output. Each repository gets one line: `  + <name>` (done),
  `  = <reason>` (skipped: `<name>: bump_donico is false`, `<name> is not
  cloned`, or `<name>: no donico pin in mise.toml` for a repository not
  migrated to the binary yet) or `  ! <name>: <reason>` (failed: uncommitted
  changes, not on `master`, a regeneration donico refuses, a refused commit).
  A failure does not stop the others; the status is 1 if one failed.

### `repos update`

The interactive screen of the fleet: it looks up the latest upstream version of
every image (GitHub releases, else tags; the series of `constrain`), shows
which ones are behind, and applies the chosen updates. Its labels are in
French, as in the gem. It needs:

- `GITHUB_TOKEN`, in the environment or the `.env` of the configuration
  repository: a full scan does not fit in GitHub's anonymous limit of 60
  requests an hour, and a truncated scan would show a half-wrong table without
  saying so;
- a terminal: a controlling terminal (`/dev/tty`) and `TERM`;
- CA certificates, to check GitHub's: on Linux the system store (the .deb and
  .rpm packages depend on `ca-certificates`); on macOS the store of Homebrew's
  `openssl@4` when it is installed, else the system bundle `/etc/ssl/cert.pem`.
  `SSL_CERT_FILE` and `SSL_CERT_DIR`, in the environment or the `.env` of the
  configuration repository, are always loaded, and on macOS in place of the
  system bundle (a company proxy whose root certificate lives in the Keychain
  needs it exported to a file named there);
- image repositories that are cloned, clean, on `master` and pinned to the
  version of the running binary through either backend (or not pinned at
  all), since it regenerates their files with this binary; one that is not is
  failed, with the reason, and the others go on;
- `templates/README.md`, for the root README.

Keys: arrows or `j`/`k` move, space or `x` selects, `a` selects (or clears) every update,
enter or `d` applies, `p` pushes, `o` opens the upstream repository, `q` or
Ctrl-C quits. Applying bumps the version in each chosen image's `donico.yml`
(the first matching line, quotes kept) and regenerates its files, then
regenerates the image READMEs and the root README once, commits each image,
then commits the root README in the configuration repository. Nothing is
pushed before `p`, which pushes each image, then the configuration repository.

A signal (TERM, HUP, or INT sent from outside) gives the terminal back and ends
with status 128 + the signal number. During the apply phase it stops between
two steps: a commit already started runs to its end, a push stops after the
repository in progress, and the images already bumped but not yet committed
stay modified, as may the root README of the configuration repository. Their
`donico.yml` already holds the new version, so the next scan no longer offers
them: nothing reports them. Find them with `donico-manager repos status` (and
`git status` in the configuration repository), then in each either commit the
change by hand or put it back with `git checkout -- .`.

### Coming from the `donico-manager` gem

Same `donico-manager.yml`, same lines, same generated READMEs and heritage tree
(the checks are in `scripts/oracle/fleet.sh`). What changes:

1. **Command names.** `clone` becomes `repos clone [REPO]`,
   `update-image-readmes` becomes `repos update-readme [REPO]`, and `repos
   open-upstream` takes `[REPO]`. `clean`, `lint-commits`, `completions`,
   `version` (use `--version`), `--tree`, `repos reconcile` and `repos
   check-versions` are gone.
2. **The image README says `donico help`** where the gem wrote `bin/rake help`.
3. **`bump-donico` edits `mise.toml`** instead of writing a `Gemfile`, and its
   commit body names `mise.toml`; `templates/donico/Gemfile` is no longer read.
   The pin is the `"github:jbox-web/donico"` or `"aqua:jbox-web/donico"` line;
   a repository without one is skipped (`= <name>: no donico pin in
   mise.toml`, where the gem said `no donico Gemfile`), and `VERSION` must be
   the version of the running binary.
4. **Regeneration and `check-hadolint` run inside the binary**, not through the
   repository's own tooling, so they also work on a repository that still has
   its `Rakefile`. `repos update` fails an image pinned to another donico
   version, whose files this binary would regenerate.
5. **Errors are one line**, `donico-manager: <message>`, status 1.
6. **The rewritten file is restored when a regeneration fails** (`mise.toml` in
   `bump-donico`, `donico.yml` in `repos update`): the repository is left as
   it was, where the gem left it modified, and refused on the next run.
7. **A refused `git add` or commit is a failure** (`! <name>: commit failed:
   <message>`), and that repository is not pushed. The gem dropped that result.
8. **`--help` anywhere on the line** prints the usage, where an unknown option
   is otherwise refused.
9. **The terminal check is the controlling terminal** (`/dev/tty`), not
   stdout: `donico-manager repos update > file` opens the interface where the
   gem refused. The refusal no longer mentions `repos check-versions`.
10. **In `repos update`**, a failed commit or push of the configuration
    repository stays on screen after the batch, where the gem showed it for
    an instant; the root README commit takes `README.md` only, never what was
    already staged there; after a second apply, `p` pushes every batch
    applied, not only the last; and an image whose commit is made can no
    longer be selected, where the gem applied it again and failed it.
11. **The `.env` of the configuration repository is read with donico's own
    parser**: plain `KEY=VALUE`, nothing interpolated (see
    [The `.env` file](#the-env-file)). The gem used the dotenv gem.
12. **`git` absent from the `PATH` is one error line**
    (`donico-manager: git not found in PATH`) that stops a sweep, where the
    gem counted every repository as failed.
13. **An invalid `todo.yml` is refused before anything is written**
    (`donico-manager: todo.yml: invalid YAML.`), where the gem truncated the
    root README, then crashed.

Anything else that differs from the gem is a bug: please report it.

## Development

```sh
mise dev:deps && mise dev:spec        # specs, in process, no docker
mise dev:spec-mt                      # the same, multi-threaded
mise dev:ameba && mise dev:format-check
mise dev:build                        # bin/donico, and the link bin/donico-manager
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
the quick-start `donico.yml`. The example of the debuerreotype section is
checked the same way, build script included, and so is the fleet section: its
`donico-manager.yml` is loaded through `Fleet::Manifest.load`, and its list of
commands is compared with what `donico-manager --help` prints.

The comparison with the Ruby gems is done by three scripts that run both on
local copies: two for donico on the clones of the image repositories, one for
`donico-manager` on the fleets' configuration repositories; see
[scripts/oracle/README.md](scripts/oracle/README.md).

Releases are built by [crystalreleaser](https://github.com/jbox-web/crystalreleaser)
from `.crystalreleaser.yml`: static linux/amd64 and linux/arm64 binaries built
in an Alpine image with Alpine's own Crystal, darwin binaries linking
Homebrew's OpenSSL 4 statically, archives, checksums, `.deb` and `.rpm`
packages, a Homebrew formula and an aqua registry entry, each with the
`donico-manager` link.

## License

MIT, see [LICENSE](LICENSE). `donico licenses` prints the notices of what the
binary embeds.
