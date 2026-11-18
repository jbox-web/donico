# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [3.1.0] - 2026-11-18

### Added

- `image_builder: debuerreotype`, a second backend that builds Debian base
  images from nothing: a root filesystem made by debuerreotype once per
  architecture, packed as a tarball, the tarballs assembled into one multi-arch
  image `<registry>/<distro>`. It replaces "danico" (a Rakefile, `danico.yml`,
  an ERB template and three shell scripts) in the `debian-base` repositories,
  which no longer need Ruby.
  - Tasks `<distro>:<version>:build`, `:push` and `:clean` for each row;
    neither `test` nor `login`.
  - The recipe is part of the binary. For the same row and arch, the build
    script is the one danico rendered from its template, byte for byte, and
    the `docker run` and `docker buildx build` command lines are those of its
    scripts.
  - Top-level keys `apt_proxy` and `debuerreotype_image` (default
    `<tools_registry>/debuerreotype:latest`); row keys `eol`,
    `debootstrap_url`, `debootstrap_opts` and `timestamp`.
  - `ENABLE_APT_PROXY=false` (process environment or `.env`) builds without
    the configured proxy.
  - The default timestamp is the day before the run, or before
    `CI_PIPELINE_CREATED_AT` under GitLab CI, so that the `build` and `push`
    jobs of one pipeline agree on the tarballs across midnight.
  - `generate-files` writes the CI matrix alone, `matrix` prints the rows of
    this backend, `image-builder` prints `debuerreotype`.
  - Differences from danico, listed in the README ("Coming from danico"):
    `donico.yml` instead of `danico.yml`, a quoted `version`, `archs` written
    as platforms (`linux/amd64`), donico's task names, the proxy used whenever
    `apt_proxy` is set, no Docker Hub default for the debuerreotype image,
    every tarball checked before a push, a fixed list of platforms, and for
    `build` the exit status of the failed `docker run`, a refusal to start
    over a leftover build directory and the container stopped on INT or TERM.

## [3.0.0] - 2026-11-18

First release of the Crystal rewrite of the Ruby gem. The numbering restarts at
3.0.0 so that it cannot be confused with the `2.0.x` gems. Same contract as the
gem: for the same `donico.yml`, the same generated files, the same docker
commands and the same exit statuses, checked on 94 image repositories.

### Added

- A single static binary, `donico`, with no runtime dependency: static
  linux/amd64 and linux/arm64, darwin/arm64 and darwin/amd64, `.tar.gz`
  archives with checksums, `.deb` and `.rpm` packages, a Homebrew formula and
  an aqua registry entry.
- `donico matrix`, which prints the resolved matrix as JSON.
- `donico inspec <mode> <image> [inputs...]`, the InSpec harness called
  directly; the harness itself is part of the binary, with the extension points
  `bin/inspec-container-up`, `bin/inspec-container-down` and `.inspecrc`.
- `donico licenses`, which prints the third-party notices embedded in the
  binary.
- `tools_registry`, `docker_linter` and `inspec_image`: the Dockerfile linter
  and the InSpec image are resolved from configuration, `<tools_registry>/hadolint:latest`
  and `<tools_registry>/inspec:latest` by default, with `tools_registry`
  defaulting to `registry`. No host is built into the binary.
- `test_variants`: `test` runs the InSpec suite once per variant, all of them
  even after a failure.
- `login_env`: names of the environment variables `login` forwards into the
  container, as `-e NAME`.
- A `.env` file of the project directory is loaded at start-up, for every task,
  without overriding variables already set. Plain `KEY=VALUE` syntax: no
  interpolation, no command substitution, never printed.
- The README documents every task, every key, the `.env` syntax, the InSpec
  harness and the migration from the gem; its `donico.yml` examples are loaded
  by the specs.
- `donico.example.yml`, a commented `donico.yml` showing every key, loaded by
  the specs as well.

### Changed

- Differences from the gem (anything else is a bug):
  - `image_builder` defaults to `bake`; `image_builder: docker` is refused with
    a message saying so, and a missing `registry` gets a message that names the
    key.
  - `donico.yml` is no longer run through ERB.
  - No Rake hooks: `test_variants` and `login_env` replace the three uses found
    in practice. No `Rakefile`, `Gemfile`, Bundler binstub or Ruby toolchain is
    needed in an image repository.
  - `help` and the generated-file warning say `donico` instead of `bin/rake`.
  - Error messages are written for the binary: one line, prefixed `donico: `,
    no Ruby class name.
  - An empty `CI_COMMIT_TIMESTAMP` counts as unset.
  - The harness logs the docker calls it makes instead of `exec: bin/inspec`.
  - The `exec: ...` log line is printed even when stdout is not a terminal.
  - Captured output (`clean`, `lint-dockerfile`) keeps the order stdout and
    stderr were written in.
  - An InSpec input whose value contains whitespace is passed as one argument.
  - `version` is typed by Crystal's YAML parser, which differs from Ruby's on
    `1e3` and `0o17`; quote the version.
  - Two matrix rows with the same `distro` and `version` are rejected when the
    file loads, and so are two rows that give the same bake target.
  - `distro`, `version`, `image_name`, tags and build arg names are checked
    when the file loads against what bake and docker accept; an empty string
    counts as a missing value.
  - A build arg is declared once, and never under a name donico injects
    (`DISTRO_NAME`, `BUILD_DATE`, `<NAME>_VERSION`).
  - `${...}` and `%{...}` in a build arg value or a Dockerfile path are written
    literally; the `src` of a secret file is still resolved by bake.
  - `<NAME>_VERSION` only holds letters, digits and underscores.
  - `build` and `push` add `BUILD_DATE` alone to the environment of docker,
    instead of every build arg.

### Removed

- The `docker` image builder.
- `lint-commits` and the `commit_linter` key (ignored when present).
