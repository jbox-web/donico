#!/usr/bin/env bash
# shellcheck shell=bash
#
# Proves that the static Linux binary does what the native one does, beyond
# `--version`: the specs only ever run the native binary. The same fixed list of commands runs once with the native binary on
# the host and once with the Linux binary inside a throwaway alpine:3.24
# container of the given platform; exit statuses, stdout, stderr, the calls
# the fake docker received and the generated files are then compared. One
# command of the list is a fleet command, run through a symbolic link named
# `donico-manager`, the second name the binary answers to.
#
#   static-smoke.sh <native bin/donico> <linux binary> <platform>
#
# <platform> is `linux/amd64` or `linux/arm64`. This is the one place that
# calls the real docker: to start that container. Nothing else is mounted
# writable than the project copy, the fake docker is a shell script that logs
# its arguments, there is no network use (the image must already be local or
# pullable once), and the container is removed (`--rm`). Every command runs
# under `env -i`: nothing of the caller's environment reaches the binaries.
#
# The project is one of the script's own (two rows, a `.inspecrc`,
# `test_variants`, `login_env`, build args, no secret, no `.env`), which is
# also the configuration repository of a two-image fleet. The list: `help`,
# `generate-files`, `matrix`, `image-builder`, the `build`, `push`, `test`,
# `clean` and `login` tasks of the rows, an unknown task, `lint-dockerfile`, a
# `test` where the fake docker fails the Inspec call with status 100, and
# `donico-manager repos list`.
#
# Compared per command: exit status, stdout, stderr and the fake's call log,
# then the two generated files, after replacing the project path by
# `<project>` (the only normalisation). The report is one `same` or
# `DIFFERENT` line per command and file, then `N compared, M different`.
#
# Exits 1 on any difference, and when a side did not produce what the
# comparison needs (an equal pair of empty results proves nothing): the build
# made no `buildx` call, the failing run did not exit 100, `generate-files`
# wrote nothing, `repos list` did not list the fleet.
#
# The binaries come from `mise dev:build` and `mise release:static`:
#
#   scripts/static-smoke.sh bin/donico dist/<linux binary> linux/amd64

set -o nounset
set -o pipefail

IMAGE='alpine:3.24'
ROOT="${HOME}/.local/tmp/claude-jbox-donico-smoke"

if [[ $# -ne 3 ]]; then
  echo 'usage: static-smoke.sh <native bin/donico> <linux binary> <platform>' >&2
  exit 2
fi
for path in "$1" "$2"; do
  [[ -x ${path} ]] || {
    echo "not an executable: ${path}" >&2
    exit 2
  }
done
NATIVE="$(cd "${1%/*}" && pwd -P)/${1##*/}"
LINUX="$(cd "${2%/*}" && pwd -P)/${2##*/}"
PLATFORM=$3
case "${PLATFORM}" in
  linux/amd64 | linux/arm64) ;;
  *)
    echo "platform must be linux/amd64 or linux/arm64: ${PLATFORM}" >&2
    exit 2
    ;;
esac

WORK="${ROOT}/${PLATFORM//\//-}"
case "${WORK}" in
  "${ROOT}/"?*) ;;
  *) exit 2 ;;
esac
rm -rf "${WORK}"
mkdir -p "${WORK}/fake" "${WORK}/home" "${WORK}/host" "${WORK}/linux" "${WORK}/host-alias" "${WORK}/linux-alias"

# The second name, as the packages install it: a symbolic link to the binary.
# On the host it points at the native binary; the Linux side's points at the
# path the container mounts the binary at, and is mounted read-only at /alias.
ln -s "${NATIVE}" "${WORK}/host-alias/donico-manager"
ln -s /usr/local/bin/donico "${WORK}/linux-alias/donico-manager"

# The fake docker: logs one `--- call` line then one line per argument, prints
# a container id for the start, and fails the Inspec call (the one started
# with `--entrypoint inspec`) with the status in FAKE_FAIL_INSPEC when it is set. /bin/sh only: busybox runs it too.
cat >"${WORK}/fake/docker" <<'FAKE'
#!/bin/sh
{
  echo '--- call'
  for arg in "$@"; do
    printf '%s\n' "$arg"
  done
} >>"$FAKE_LOG"
case "$*" in
  "run --rm -d "*)
    echo fakecontainer0001
    exit 0
    ;;
  *"--entrypoint inspec "*)
    if [ -n "${FAKE_FAIL_INSPEC:-}" ]; then
      exit "$FAKE_FAIL_INSPEC"
    fi
    ;;
esac
exit 0
FAKE
chmod 755 "${WORK}/fake/docker"

# The driver runs the fixed list of commands in the current directory, each
# under `env -i`, and writes under <results>/NN.{name,out,err,exit,calls}.
# One line per command: name|VAR=value ...|program|arguments, where program is
# `donico` or `donico-manager` (the link to the same binary). POSIX sh, so the
# host and the Alpine container run the very same file.
cat >"${WORK}/fake/driver.sh" <<'DRIVER'
#!/bin/sh
donico=$1
results=$2
manager=$3
mkdir -p "$results" "$results/home"
index=0
while IFS='|' read -r name extra program args; do
  [ -n "$name" ] || continue
  case "$program" in
    donico-manager) binary=$manager ;;
    *) binary=$donico ;;
  esac
  index=$((index + 1))
  number=$(printf '%02d' "$index")
  : >"$results/fake.log"
  # The words of $extra and $args are plain: no spaces inside a value.
  # shellcheck disable=SC2086
  env -i PATH="$PATH" HOME="$results/home" LANG=C \
    CI_COMMIT_TIMESTAMP='2026-07-31T10:20:30+02:00' \
    FAKE_LOG="$results/fake.log" $extra \
    "$binary" $args >"$results/$number.out" 2>"$results/$number.err"
  echo $? >"$results/$number.exit"
  echo "$name" >"$results/$number.name"
  cp "$results/fake.log" "$results/$number.calls"
done <<'COMMANDS'
help||donico|help
generate-files||donico|generate-files
matrix||donico|matrix
image-builder||donico|image-builder
build||donico|bookworm:1.0:build
build-second-row||donico|trixie:2.0:build
push||donico|bookworm:1.0:push
test-variants||donico|bookworm:1.0:test
test-plain||donico|trixie:2.0:test
clean||donico|bookworm:1.0:clean
login||donico|bookworm:1.0:login
lint-dockerfile||donico|lint-dockerfile
unknown-task||donico|nosuch:1.0:build
test-inspec-fails|FAKE_FAIL_INSPEC=100|donico|trixie:2.0:test
fleet-repos-list||donico-manager|repos list
COMMANDS
DRIVER
chmod 755 "${WORK}/fake/driver.sh"

# A small project: two rows, a .inspecrc, test_variants, login_env, build args,
# no secret and no .env. The same directory is also the configuration
# repository of a two-image fleet for the fleet command: `ruby` is cloned in
# its workspace, `traefik` is not.
make_project() {
  local dir=$1
  mkdir -p "${dir}"
  cat >"${dir}/donico.yml" <<'YAML'
registry: registry.example.com/base
image_name: myapp
matrix:
  - version: "1.0"
    distro: bookworm
    archs: [linux/amd64, linux/arm64]
    build_args:
      - APP_USER=app
    test_args:
      - mode=smoke
    tags:
      - "%<version>s-%<distro>s"
      - latest
    test_variants:
      - ["run_mode=default"]
      - ["run_mode=dind"]
    login_env: [SSH_KEY, HOST_KEYSCAN]
  - version: "2.0"
    distro: trixie
YAML
  printf -- '--reporter cli\n--no-color\n' >"${dir}/.inspecrc"
  printf 'FROM scratch\n' >"${dir}/Dockerfile"
  cat >"${dir}/donico-manager.yml" <<'YAML'
registry:  registry.example.org/base
group:     git@git.example.org:images
workspace: images
images:
  - traefik
  - ruby
YAML
  mkdir -p "${dir}/images/ruby"
}
make_project "${WORK}/host/project"
make_project "${WORK}/linux/project"
HOST_PROJECT="$(cd "${WORK}/host/project" && pwd -P)"
LINUX_PROJECT="$(cd "${WORK}/linux/project" && pwd -P)"

# The native binary, on the host, with the fake docker first on a minimal PATH.
mkdir -p "${HOST_PROJECT}/.smoke"
# Both runs are bounded: a binary that hangs (or a docker daemon that never
# answers) would otherwise hold the script forever. The driver itself cannot
# carry the bound: its PATH has no `timeout` on macOS.
(
  cd "${HOST_PROJECT}" &&
    timeout -k 10 300 env -i PATH="${WORK}/fake:/usr/bin:/bin" HOME="${WORK}/home" LANG=C \
      /bin/sh "${WORK}/fake/driver.sh" "${NATIVE}" "${HOST_PROJECT}/.smoke" "${WORK}/host-alias/donico-manager"
) >"${WORK}/host.log" 2>&1
echo "host run: exit $?"

# The Linux binary, in a throwaway container of the requested platform. The
# project copy is the one writable mount.
mkdir -p "${LINUX_PROJECT}/.smoke"
CONTAINER="donico-static-smoke-$$"
timeout -k 10 900 docker run --rm --name "${CONTAINER}" --platform "${PLATFORM}" --user "$(id -u):$(id -g)" \
  -v "${LINUX_PROJECT}:/work" \
  -v "${LINUX}:/usr/local/bin/donico:ro" \
  -v "${WORK}/fake:/fake:ro" \
  -v "${WORK}/linux-alias:/alias:ro" \
  -w /work -e PATH=/fake:/usr/bin:/bin \
  "${IMAGE}" /bin/sh /fake/driver.sh /usr/local/bin/donico /work/.smoke /alias/donico-manager \
  >"${WORK}/linux.log" 2>&1
container_status=$?
echo "container run (${PLATFORM}): exit ${container_status}"
# A run that timed out leaves its container behind: `--rm` only removes it
# once it stops.
if [[ ${container_status} -ge 124 ]]; then
  docker rm -f "${CONTAINER}" >/dev/null 2>&1
fi

# Paths differ between the two sides by construction: the project directory
# becomes <project>, in every stream and in the fake's calls: the host path on the
# host side, /work (where the container sees it) on the Linux side.
# Only where the path ends: `/work` must not match inside `/workdir`.
normalise() {
  local project=$1 file=$2
  sed -E "s|${project}([^A-Za-z0-9_.-]\|\$)|<project>\1|g" "${file}"
}

compared=0
different=0
problems=0

# A side that produced nothing would make every comparison pass.
for side in host linux; do
  results="${WORK}/${side}/project/.smoke"
  count=$(find "${results}" -maxdepth 1 -name '*.exit' 2>/dev/null | wc -l)
  if [[ ${count} -ne 15 ]]; then
    echo "SIDE ${side}: ${count} results instead of 15 (see ${WORK}/${side}.log)"
    problems=$((problems + 1))
  fi
done

if [[ ${problems} -eq 0 ]]; then
  for exit_file in "${WORK}/host/project/.smoke/"*.exit; do
    number=${exit_file##*/}
    number=${number%.exit}
    name=$(cat "${WORK}/host/project/.smoke/${number}.name")
    ok=1
    detail=''
    for part in exit out err calls; do
      host_file="${WORK}/host/project/.smoke/${number}.${part}"
      linux_file="${WORK}/linux/project/.smoke/${number}.${part}"
      if ! delta=$(diff -u <(normalise "${HOST_PROJECT}" "${host_file}") <(normalise /work "${linux_file}") 2>&1); then
        ok=0
        detail+=$'\n'"  ${part}:"$'\n'"${delta}"
      fi
    done
    compared=$((compared + 1))
    if [[ ${ok} -eq 1 ]]; then
      echo "same       ${number} ${name}"
    else
      different=$((different + 1))
      echo "DIFFERENT  ${number} ${name}${detail}"
    fi
  done

  # The files generate-files wrote.
  for generated in .gitlab-ci/extends/.matrix.yml docker-bake.hcl; do
    compared=$((compared + 1))
    if delta=$(diff -u "${HOST_PROJECT}/${generated}" "${LINUX_PROJECT}/${generated}" 2>&1); then
      echo "same       file ${generated}"
    else
      different=$((different + 1))
      echo "DIFFERENT  file ${generated}"$'\n'"${delta}"
    fi
  done

  # What an equal pair must also show, or the comparison was empty: the
  # build reached docker, the failing InSpec status came through, the
  # generated files exist and are not empty, and the second name answered
  # as the fleet tool (a `donico` would refuse `repos` as an unknown task).
  smoke="${WORK}/host/project/.smoke"
  grep -q '^buildx$' "${smoke}/05.calls" || {
    echo 'EMPTY: the build made no buildx call'
    problems=$((problems + 1))
  }
  [[ "$(cat "${smoke}/14.exit")" == 100 ]] || {
    echo 'EMPTY: the failing InSpec run did not exit 100'
    problems=$((problems + 1))
  }
  [[ -s "${HOST_PROJECT}/docker-bake.hcl" && -s "${HOST_PROJECT}/.gitlab-ci/extends/.matrix.yml" ]] || {
    echo 'EMPTY: generate-files wrote nothing'
    problems=$((problems + 1))
  }
  [[ "$(cat "${smoke}/15.out")" == $'Repository exists: ruby\nRepository missing: traefik' ]] || {
    echo 'EMPTY: donico-manager repos list did not list the fleet'
    problems=$((problems + 1))
  }
fi

echo "${compared} compared, ${different} different"
if [[ ${different} -gt 0 || ${problems} -gt 0 ]]; then
  exit 1
fi
