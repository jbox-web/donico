#!/usr/bin/env bash
# shellcheck shell=bash
#
# Proves that the oracle scripts can fail: runs them on a tiny project of their
# own (never the fleets) with the real binary, then with mutated copies of it,
# and checks that
#
#   - the unmutated binary is reported identical (exit 0, 0 different);
#   - a binary whose `docker buildx bake` call carries an extra argument is
#     reported different by commands.sh (call log);
#   - a binary whose `clean` exits 3 instead of 0 is reported different by
#     commands.sh (exit status);
#   - a binary that prints one more line on `login` is reported different by
#     commands.sh (stdout);
#   - a binary that builds although a declared secret is missing is reported
#     different by commands.sh (missing-secret pass);
#   - a binary whose `generate-files` writes nothing, or leaves one more file
#     behind, is reported different by generated-files.sh;
#   - a fleet that holds no project makes both scripts fail instead of ending
#     on "0 compared, 0 different".
#
# Its runs go under a root of its own, so it never wipes the records of a run
# over the fleets.
#
#   self-test.sh <gem checkout> <bin/donico>
#
# Exits 1 if any assertion fails. See README.md.

set -o nounset
set -o pipefail

HERE="$(cd "${BASH_SOURCE[0]%/*}" && pwd -P)"
ROOT="${HOME}/.local/tmp/claude-jbox-donico-oracle/self-test"

if [[ $# -ne 2 ]]; then
  echo 'usage: self-test.sh <gem checkout> <bin/donico>' >&2
  exit 2
fi
GEM_DIR=$1
REAL="$(cd "${2%/*}" && pwd -P)/${2##*/}"
if [[ ! -x ${REAL} ]]; then
  echo "not an executable: ${REAL}" >&2
  exit 2
fi

case "${ROOT}" in
  "${HOME}/.local/tmp/claude-jbox-donico-oracle/"?*) ;;
  *) exit 2 ;;
esac
rm -rf "${ROOT}"
mkdir -p "${ROOT}/fleet/tiny/bin" "${ROOT}/empty-fleet/not-a-project" "${ROOT}/wrappers" "${ROOT}/shim" "${ROOT}/out"

# lib.sh keeps the records of each script under ORACLE_ROOT.
export ORACLE_ROOT="${ROOT}/runs"

# The tiny project: one row, one secret and a start hook, so that the
# missing-secret pass and the hook assertion of commands.sh have something to
# run on.
cat >"${ROOT}/fleet/tiny/donico.yml" <<'YAML'
registry: registry.example.net/images
image_builder: bake
image_name: tiny
matrix:
  - version: "1.0"
    distro: buster
    secret_envs:
      - id: TINY_TOKEN
YAML
printf 'FROM scratch\n' >"${ROOT}/fleet/tiny/Dockerfile"
cat >"${ROOT}/fleet/tiny/bin/inspec-container-up" <<'HOOK'
#!/bin/sh
docker run --rm -d "$2" /bin/sh
HOOK
chmod +x "${ROOT}/fleet/tiny/bin/inspec-container-up"

# Mutation 1: a docker shim in front of the fake appends an argument to the
# `buildx bake` call, for the build task only.
cat >"${ROOT}/shim/docker" <<SHIM
#!/bin/bash
exec "${HERE}/fake/docker" "\$@" --mutated
SHIM
chmod +x "${ROOT}/shim/docker"
cat >"${ROOT}/wrappers/call-log" <<WRAPPER
#!/bin/bash
case "\$1" in
  *:build) PATH="${ROOT}/shim:\${PATH}" ;;
esac
exec "${REAL}" "\$@"
WRAPPER

# Mutation 2: the clean task exits 3 when the real one succeeds.
cat >"${ROOT}/wrappers/exit-code" <<WRAPPER
#!/bin/bash
"${REAL}" "\$@"
status=\$?
case "\$1" in
  *:clean) [ "\${status}" -eq 0 ] && exit 3 ;;
esac
exit "\${status}"
WRAPPER

# Mutation 3: one more line on stdout for the login task.
cat >"${ROOT}/wrappers/stdout" <<WRAPPER
#!/bin/bash
case "\$1" in
  *:login) echo 'one more line' ;;
esac
exec "${REAL}" "\$@"
WRAPPER

# Mutation 4: the declared secret is always there, so a build that should
# stop on the missing secret goes on to docker.
cat >"${ROOT}/wrappers/secret" <<WRAPPER
#!/bin/bash
export TINY_TOKEN=always
exec "${REAL}" "\$@"
WRAPPER

# Mutation 5: generate-files leaves one more file in the project.
cat >"${ROOT}/wrappers/leftover" <<WRAPPER
#!/bin/bash
case "\$1" in
  generate-files) : >.docker-bake.hcl.donico-0.tmp ;;
esac
exec "${REAL}" "\$@"
WRAPPER

# Mutation 6: generate-files succeeds and writes nothing.
cat >"${ROOT}/wrappers/no-write" <<WRAPPER
#!/bin/bash
case "\$1" in
  generate-files) exit 0 ;;
esac
exec "${REAL}" "\$@"
WRAPPER
chmod +x "${ROOT}"/wrappers/*

failures=0

# check <label> <script> <binary> <expected exit> <expected different: zero|some>
check() {
  local label=$1 script=$2 binary=$3 want_exit=$4 want_different=$5
  local out="${ROOT}/out/${label}.${script}" status last compared different ok=1
  "${HERE}/${script}.sh" "${GEM_DIR}" "${binary}" "${ROOT}/fleet" >"${out}" 2>&1
  status=$?
  last="$(tail -n 1 "${out}")"
  if [[ ${last} =~ ^([0-9]+)\ compared,\ ([0-9]+)\ different$ ]]; then
    compared=${BASH_REMATCH[1]}
    different=${BASH_REMATCH[2]}
  else
    compared=-1
    different=-1
    ok=0
  fi
  [[ ${status} -eq ${want_exit} ]] || ok=0
  [[ ${compared} -gt 0 ]] || ok=0
  if [[ ${want_different} == zero ]]; then
    [[ ${different} -eq 0 ]] || ok=0
  else
    [[ ${different} -gt 0 ]] || ok=0
  fi
  if [[ ${ok} -eq 1 ]]; then
    printf 'PASS %-10s %-16s exit %d, %s\n' "${label}" "${script}" "${status}" "${last}"
  else
    printf 'FAIL %-10s %-16s exit %d (wanted %d), %s (different: wanted %s)\n' "${label}" "${script}" "${status}" "${want_exit}" "${last}" "${want_different}"
    failures=$((failures + 1))
  fi
}

# check_empty <script> : a fleet without any project must fail the script.
check_empty() {
  local script=$1 out status last
  out="${ROOT}/out/empty.${script}"
  "${HERE}/${script}.sh" "${GEM_DIR}" "${REAL}" "${ROOT}/empty-fleet" >"${out}" 2>&1
  status=$?
  last="$(tail -n 1 "${out}")"
  if [[ ${status} -ne 0 && ${last} == '0 compared, 0 different' ]] && grep -q '^nothing was compared' "${out}"; then
    printf 'PASS %-10s %-16s exit %d, %s\n' empty "${script}" "${status}" "${last}"
  else
    printf 'FAIL %-10s %-16s exit %d (wanted a failure saying that nothing was compared), %s\n' empty "${script}" "${status}" "${last}"
    failures=$((failures + 1))
  fi
}

check unmutated generated-files "${REAL}" 0 zero
check unmutated commands "${REAL}" 0 zero
check call-log commands "${ROOT}/wrappers/call-log" 1 some
check exit-code commands "${ROOT}/wrappers/exit-code" 1 some
check stdout commands "${ROOT}/wrappers/stdout" 1 some
check secret commands "${ROOT}/wrappers/secret" 1 some
check no-write generated-files "${ROOT}/wrappers/no-write" 1 some
check leftover generated-files "${ROOT}/wrappers/leftover" 1 some
check_empty generated-files
check_empty commands

# The unmutated run must have exercised what the tiny project is there for.
unmutated="${ROOT}/out/unmutated.commands"
for needle in 'missing-secret' 'inspec-container-up'; do
  if ! grep -q "${needle}" "${unmutated}"; then
    printf 'FAIL the unmutated commands run never mentions %s\n' "${needle}"
    failures=$((failures + 1))
  fi
done

if [[ ${failures} -eq 0 ]]; then
  echo 'self-test: all assertions hold'
else
  echo "self-test: ${failures} assertion(s) failed"
  exit 1
fi
