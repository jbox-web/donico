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
#     on "0 compared, 0 different";
#   - on a copy of the fixture fleet of the specs (spec/fixtures/fleet, its
#     workspace moved outside the configuration repository, `../docker-images`),
#     fleet.sh reports the unmutated donico-manager identical, and reports
#     different a binary that drops one line of the root README, one whose
#     `repos status` skips a repository, one that writes a different heritage
#     file, one that writes a different image README, one whose `repos gc`
#     exits 0 instead of 1, one that appends to the root README instead of
#     rewriting it, one that touches the README of a repository the
#     generator skips and one that writes an image README the gem does not
#     write; a configuration repository without
#     donico-manager.yml makes it fail on "nothing was compared".
#
# Its runs go under a root of its own, so it never wipes the records of a run
# over the fleets.
#
#   self-test.sh <donico gem checkout> <bin/donico> <donico-manager gem checkout> <bin/donico-manager>
#
# Exits 1 if any assertion fails. See README.md.

set -o nounset
set -o pipefail

HERE="$(cd "${BASH_SOURCE[0]%/*}" && pwd -P)"
ROOT="${HOME}/.local/tmp/claude-jbox-donico-oracle/self-test"

if [[ $# -ne 4 ]]; then
  echo 'usage: self-test.sh <donico gem checkout> <bin/donico> <donico-manager gem checkout> <bin/donico-manager>' >&2
  exit 2
fi
GEM_DIR=$1
REAL="$(cd "${2%/*}" && pwd -P)/${2##*/}"
if [[ ! -x ${REAL} ]]; then
  echo "not an executable: ${REAL}" >&2
  exit 2
fi
FLEET_GEM_DIR=$3
# Only the directory is resolved: the binary must keep its name, donico-manager.
FLEET_REAL="$(cd "$(dirname "$4")" && pwd -P)/${4##*/}"
if [[ ! -x ${FLEET_REAL} || ${FLEET_REAL##*/} != donico-manager ]]; then
  echo "not an executable named donico-manager: ${FLEET_REAL}" >&2
  exit 2
fi

case "${ROOT}" in
  "${HOME}/.local/tmp/claude-jbox-donico-oracle/"?*) ;;
  *) exit 2 ;;
esac
rm -rf "${ROOT}"
mkdir -p "${ROOT}/fleet/tiny/bin" "${ROOT}/empty-fleet/not-a-project" "${ROOT}/wrappers" "${ROOT}/shim" "${ROOT}/out" \
  "${ROOT}/fleets/tiny" "${ROOT}/fleets/no-manifest/ci-config" "${ROOT}/fleet-wrappers"

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

# The fleet of fleet.sh: the fixture fleet of the specs, whose expected files
# were produced by the gem, with its workspace moved beside the configuration
# repository (`../docker-images`) so that the side-by-side
# copy is exercised too.
FIXTURE="$(cd "${HERE}/../../spec/fixtures/fleet" && pwd -P)"
cp -R "${FIXTURE}" "${ROOT}/fleets/tiny/ci-config"
rm -rf "${ROOT}/fleets/tiny/ci-config/expected" "${ROOT}/fleets/tiny/ci-config/README.md"
mv "${ROOT}/fleets/tiny/ci-config/docker-images" "${ROOT}/fleets/tiny/docker-images"
sed -i 's#^workspace: .*#workspace: ../docker-images#' "${ROOT}/fleets/tiny/ci-config/donico-manager.yml"
grep -qx 'workspace: ../docker-images' "${ROOT}/fleets/tiny/ci-config/donico-manager.yml" || {
  echo 'self-test: the workspace of the fixture fleet was not rewritten' >&2
  exit 2
}
# A directory the manifest does not declare, with a README: every generator
# skips it, so both sides must leave its README as they found it.
mkdir -p "${ROOT}/fleets/tiny/docker-images/undeclared"
printf '# undeclared\n' >"${ROOT}/fleets/tiny/docker-images/undeclared/README.md"
# And a README already there for a declared image, as on a real fleet: the
# generator must rewrite it.
printf '# old ruby README\n' >"${ROOT}/fleets/tiny/docker-images/ruby/README.md"

# Fleet mutation 1: one line of the root README dropped. The wrappers run in
# the children's environment (no Homebrew on PATH): awk, not GNU sed.
cat >"${ROOT}/fleet-wrappers/root-readme" <<WRAPPER
#!/bin/bash
"${FLEET_REAL}" "\$@"
status=\$?
if [ "\$*" = update-readme ]; then
  awk 'NR != 2' README.md >README.md.mutated && mv README.md.mutated README.md
fi
exit "\${status}"
WRAPPER

# Fleet mutation 2: `repos status` skips the ruby repository, every other
# repository of the fixture fleet being swept one by one.
cat >"${ROOT}/fleet-wrappers/sweep-skip" <<WRAPPER
#!/bin/bash
if [ "\$*" = 'repos status' ]; then
  status=0
  for repo in absent alloy debian-base debuerreotype nocategory traefik; do
    "${FLEET_REAL}" repos status "\${repo}" || status=1
  done
  exit "\${status}"
fi
exec "${FLEET_REAL}" "\$@"
WRAPPER

# Fleet mutation 3: one more line in the heritage file.
cat >"${ROOT}/fleet-wrappers/heritage" <<WRAPPER
#!/bin/bash
"${FLEET_REAL}" "\$@"
status=\$?
if [ "\$*" = heritage ]; then
  printf 'mutated\n' >>doc/heritage/image-heritage.md
fi
exit "\${status}"
WRAPPER

# Fleet mutation 4: one more line in the README of one image.
cat >"${ROOT}/fleet-wrappers/image-readme" <<WRAPPER
#!/bin/bash
"${FLEET_REAL}" "\$@"
status=\$?
if [ "\$*" = 'repos update-readme' ]; then
  printf 'mutated\n' >>../docker-images/ruby/README.md
fi
exit "\${status}"
WRAPPER

# Fleet mutation 5: `repos gc` prints what the real one prints, and exits 0
# where it exits 1 (the fake git fails in one repository).
cat >"${ROOT}/fleet-wrappers/exit-status" <<WRAPPER
#!/bin/bash
"${FLEET_REAL}" "\$@"
status=\$?
[ "\$*" = 'repos gc' ] && exit 0
exit "\${status}"
WRAPPER

# Fleet mutation 6: the root README is appended to instead of rewritten (what
# was there before the run stays in front of the generated text).
cat >"${ROOT}/fleet-wrappers/append" <<WRAPPER
#!/bin/bash
if [ "\$*" = update-readme ]; then
  cp README.md README.md.before
  "${FLEET_REAL}" "\$@"
  status=\$?
  cat README.md.before README.md >README.md.mutated && mv README.md.mutated README.md
  rm -f README.md.before
  exit "\${status}"
fi
exec "${FLEET_REAL}" "\$@"
WRAPPER

# Fleet mutation 7: the README of a repository the generator skips is touched.
cat >"${ROOT}/fleet-wrappers/skipped-readme" <<WRAPPER
#!/bin/bash
"${FLEET_REAL}" "\$@"
status=\$?
if [ "\$*" = 'repos update-readme' ]; then
  printf 'touched\n' >>../docker-images/undeclared/README.md
fi
exit "\${status}"
WRAPPER

# Fleet mutation 8: an image README the gem never writes, written by the
# binary alone: a difference, not a gem failure.
cat >"${ROOT}/fleet-wrappers/extra-readme" <<WRAPPER
#!/bin/bash
"${FLEET_REAL}" "\$@"
status=\$?
if [ "\$*" = 'repos update-readme' ]; then
  mkdir -p ../docker-images/extra && printf '# extra\n' >../docker-images/extra/README.md
fi
exit "\${status}"
WRAPPER
chmod +x "${ROOT}"/fleet-wrappers/*

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

# check_fleet <label> <binary> <expected exit> <expected different: zero|some> [<what must differ>]
check_fleet() {
  local label=$1 binary=$2 want_exit=$3 want_different=$4 what=${5:-}
  local out="${ROOT}/out/${label}.fleet" status last compared different ok=1
  "${HERE}/fleet.sh" "${FLEET_GEM_DIR}" "${binary}" "${ROOT}/fleets/tiny/ci-config" >"${out}" 2>&1
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
    # The difference is the one the mutation makes, not another.
    grep -q "^--- tiny/.* \[${what}\] " "${out}" || ok=0
  fi
  if [[ ${ok} -eq 1 ]]; then
    printf 'PASS %-12s %-16s exit %d, %s\n' "${label}" fleet "${status}" "${last}"
  else
    printf 'FAIL %-12s %-16s exit %d (wanted %d), %s (different: wanted %s %s)\n' "${label}" fleet "${status}" "${want_exit}" "${last}" "${want_different}" "${what}"
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
check_fleet unmutated "${FLEET_REAL}" 0 zero
# The unmutated fleet run must have exercised the failing repository of the
# fake git, the side-by-side workspace and the normalisation of difference 2.
# Read now: the next run of fleet.sh recreates its records.
unmutated="${ROOT}/runs/fleet/work/tiny"
if ! grep -qx '1 repository/repositories failed.' "${unmutated}/bin.repos-status.out"; then
  printf 'FAIL the unmutated fleet run never shows a failing repository\n'
  failures=$((failures + 1))
fi
if ! grep -q '/repos/tiny/work/docker-images/' "${unmutated}/bin.image-readmes.out"; then
  printf 'FAIL the unmutated fleet run did not use a workspace beside the configuration repository\n'
  failures=$((failures + 1))
fi
if ! grep -qr 'bin/rake help' "${unmutated}/gem.files/images"; then
  printf 'FAIL the unmutated fleet run never normalised bin/rake help\n'
  failures=$((failures + 1))
fi
if ! grep -qP '^SAME\timage-readme\ttiny\tundeclared\t' "${ROOT}/runs/fleet/all.tsv"; then
  printf 'FAIL the unmutated fleet run never compared the README of a skipped repository\n'
  failures=$((failures + 1))
fi
check_fleet root-readme "${ROOT}/fleet-wrappers/root-readme" 1 some root-readme
check_fleet sweep-skip "${ROOT}/fleet-wrappers/sweep-skip" 1 some repos-status
check_fleet heritage "${ROOT}/fleet-wrappers/heritage" 1 some heritage-file
check_fleet image-readme "${ROOT}/fleet-wrappers/image-readme" 1 some image-readme
check_fleet exit-status "${ROOT}/fleet-wrappers/exit-status" 1 some repos-gc
check_fleet append "${ROOT}/fleet-wrappers/append" 1 some root-readme
check_fleet skipped-readme "${ROOT}/fleet-wrappers/skipped-readme" 1 some image-readme
check_fleet extra-readme "${ROOT}/fleet-wrappers/extra-readme" 1 some image-readme

# A configuration repository without donico-manager.yml compares nothing.
out="${ROOT}/out/empty.fleet"
"${HERE}/fleet.sh" "${FLEET_GEM_DIR}" "${FLEET_REAL}" "${ROOT}/fleets/no-manifest/ci-config" >"${out}" 2>&1
status=$?
last="$(tail -n 1 "${out}")"
if [[ ${status} -ne 0 && ${last} == '0 compared, 0 different' ]] && grep -q '^nothing was compared' "${out}"; then
  printf 'PASS %-12s %-16s exit %d, %s\n' empty fleet "${status}" "${last}"
else
  printf 'FAIL %-12s %-16s exit %d (wanted a failure saying that nothing was compared), %s\n' empty fleet "${status}" "${last}"
  failures=$((failures + 1))
fi

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
