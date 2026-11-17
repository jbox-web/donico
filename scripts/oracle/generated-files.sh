#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2031 # REC_* are read by lib.sh; the workers are subshells on purpose
#
# Design 8, first check: in a copy of each repository, generates the two files
# with the Ruby gem, then with the binary, and compares them once the warning
# line is normalised (difference 6). Reports per repository `identical` or
# `DIFFERENT` (the binary against the gem: a bug), and separately `stale` when
# the files committed in the repository differ from the gem's output (not a
# bug of the binary).
#
#   generated-files.sh <gem checkout> <bin/donico> <fleet>...
#
# Ends with `N compared, M different`; exits 1 if M > 0. See README.md.

set -o nounset
set -o pipefail

# shellcheck source=scripts/oracle/lib.sh
source "$(cd "${BASH_SOURCE[0]%/*}" && pwd -P)/lib.sh"

GENERATED_FILES=(.gitlab-ci/extends/.matrix.yml docker-bake.hcl)

# Difference 6: the warning line names the command that regenerates the file.
generated_normalise() {
  sed -E 's/^(# Instead edit donico.yml and run )(bin\/rake|donico)( generate-files)$/\1<command>\3/' "$1"
}

# generated_snapshot <dir> : copies the generated files out of the copy.
generated_snapshot() {
  local target=$1 file
  mkdir -p "${target}"
  for file in "${GENERATED_FILES[@]}"; do
    if [[ -f ${DEST}/${file} ]]; then
      mkdir -p "$(dirname "${target}/${file}")"
      cp "${DEST}/${file}" "${target}/${file}"
    fi
  done
}

# The generated files are removed from the copy before each side runs, so that
# what a side leaves behind is what that side wrote: a binary that writes
# nothing cannot pass on the gem's leftovers.
generated_remove() {
  local file
  for file in "${GENERATED_FILES[@]}"; do
    rm -f "${DEST}/${file}"
  done
}

# Every file of the copy outside .git, sorted: taken before and after the
# binary runs.
generated_listing() {
  (cd "${DEST}" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort)
}

generated_repo() {
  local label=$1 name=$2 src=$3
  WORK="${RUN_DIR}/work/${label}.${name}"
  mkdir -p "${WORK}"

  DEST="$(oracle_copy_repo "${label}" "${name}" "${src}")" || {
    oracle_record GEMFAIL generated 'cannot copy the repository'
    return
  }

  ORACLE_VARS=''
  EXTRA_ENV=()

  generated_snapshot "${WORK}/committed"

  generated_remove
  oracle_run gem "${DEST}" "${WORK}/generated.generate-files.g" generate-files
  local gs bs
  gs="$(<"${WORK}/generated.generate-files.g.exit")"
  if [[ ${gs} != 0 ]]; then
    oracle_record GEMFAIL generated "gem exited ${gs}: $(oracle_first_error "${WORK}/generated.generate-files.g.err" "${WORK}/generated.generate-files.g.out")"
    return
  fi
  generated_snapshot "${WORK}/gem"

  local problems='' file
  # The gem is the reference: it must have written every file.
  for file in "${GENERATED_FILES[@]}"; do
    if [[ ! -f ${WORK}/gem/${file} ]]; then
      problems+="${file} "
    fi
  done
  if [[ -n ${problems} ]]; then
    oracle_record GEMFAIL generated "the gem wrote no ${problems}"
    return
  fi

  generated_remove
  generated_listing >"${WORK}/files.before"
  oracle_run bin "${DEST}" "${WORK}/generated.generate-files.b" generate-files
  bs="$(<"${WORK}/generated.generate-files.b.exit")"
  generated_snapshot "${WORK}/bin"
  generated_listing >"${WORK}/files.after"

  if [[ ${bs} != 0 ]]; then
    problems+="the binary exited ${bs}: $(oracle_first_error "${WORK}/generated.generate-files.b.err" "${WORK}/generated.generate-files.b.out")"$'\n'
  fi
  # Anything else the binary left in the copy (a temporary file it did not
  # rename, for one) is a difference too: the gem leaves the two files only.
  local extra
  extra="$(comm -13 "${WORK}/files.before" "${WORK}/files.after" | grep -vxF -e './.gitlab-ci/extends/.matrix.yml' -e './docker-bake.hcl' | head -20)"
  if [[ -n ${extra} ]]; then
    problems+="the binary left other files behind:"$'\n'"${extra}"$'\n'
  fi
  for file in "${GENERATED_FILES[@]}"; do
    if [[ ! -f ${WORK}/bin/${file} ]]; then
      problems+="${file}: the binary did not write it"$'\n'
    else
      generated_normalise "${WORK}/gem/${file}" >"${WORK}/gem.norm"
      generated_normalise "${WORK}/bin/${file}" >"${WORK}/bin.norm"
      if ! cmp -s "${WORK}/gem.norm" "${WORK}/bin.norm"; then
        problems+="${file} (< gem, > binary):"$'\n'"$(diff "${WORK}/gem.norm" "${WORK}/bin.norm" | head -40)"$'\n'
      fi
    fi
  done

  if [[ -z ${problems} ]]; then
    oracle_record SAME generated "identical gem=${gs} bin=${bs}"
  else
    oracle_record DIFF generated "DIFFERENT gem=${gs} bin=${bs}"
    oracle_detail "--- ${label}/${name} [generated]" "${problems}"
  fi

  # Stale: what is committed is not what the gem generates today.
  local stale=''
  for file in "${GENERATED_FILES[@]}"; do
    if [[ ! -f ${WORK}/committed/${file} ]]; then
      stale+="${file} not committed; "
    elif ! cmp -s "${WORK}/committed/${file}" "${WORK}/gem/${file}"; then
      stale+="${file} differs from the gem's output; "
    fi
  done
  if [[ -n ${stale} ]]; then
    oracle_record STALE generated "${stale}"
  fi
}

main() {
  local started=$SECONDS
  oracle_init generated-files "$@"
  oracle_for_each_repo generated_repo
  oracle_summary "${started}"
}

main "$@"
