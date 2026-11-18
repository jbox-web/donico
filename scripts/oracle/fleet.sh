#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2031 # REC_* are read by lib.sh; the workers are subshells on purpose
#
# Design 12, the fleet side: on a copy of each fleet's configuration repository
# and of its workspace, runs the donico-manager gem, then the binary, in the
# same directory, and compares what each leaves and prints: the root README,
# every image README (after the one normalisation of difference 2), the
# heritage file, and the stdout and status of `repos list` and of the four
# sweeps under a fake git. The command names differ by design (difference 1):
# each side is called by its own name, nothing is filtered for that.
#
#   fleet.sh <gem checkout> <bin/donico-manager> <configuration repository>...
#
# Ends with `N compared, M different`; exits 1 if M > 0, when nothing was
# compared, when the gem misbehaves, or when a worker died. See README.md.

set -o nounset
set -o pipefail

# shellcheck source=scripts/oracle/lib.sh
source "$(cd "${BASH_SOURCE[0]%/*}" && pwd -P)/lib.sh"

FAKE_GIT_DIR="${ORACLE_DIR}/fake-git"

# The four sweeps, by the name both sides give them.
FLEET_SWEEPS=(status diff pull gc)

fleet_usage() {
  oracle_die "usage: fleet.sh <gem checkout> <bin/donico-manager> <configuration repository>..."
}

# The label of a configuration repository, without its trailing /ci-config:
# its path under PROJECTS, or its basename outside PROJECTS.
fleet_label() {
  local label=${1%/ci-config}
  if [[ ${label} == */PROJECTS/* ]]; then
    label="${label#*/PROJECTS/}"
  else
    label="${label##*/}"
  fi
  printf '%s' "${label//\//_}"
}

# fleet_init <gem dir> <binary> <configuration repository>...
fleet_init() {
  [[ $# -ge 3 ]] || fleet_usage
  local gem=$1 bin=$2
  shift 2

  [[ -f "${gem}/lib/donico_manager.rb" && -f "${gem}/exe/donico-manager" ]] || oracle_die "not the donico-manager gem checkout: ${gem}"
  [[ -f ${bin} && -x ${bin} ]] || oracle_die "not an executable: ${bin}"
  GEM="$(cd "${gem}" && pwd -P)"
  # Only the directory is resolved: the binary must keep the name it is
  # called by, donico-manager, which is how it knows to be the fleet tool.
  BIN="$(cd "$(dirname "${bin}")" && pwd -P)/${bin##*/}"
  [[ -x ${BIN} ]] || oracle_die "not an executable: ${BIN}"

  CONFIGS=()
  local config label labels=' '
  for config in "$@"; do
    [[ -d ${config} ]] || oracle_die "not a directory: ${config}"
    config="$(cd "${config}" && pwd -P)"
    label="$(fleet_label "${config}")"
    [[ ${labels} != *" ${label} "* ]] || oracle_die "two configuration repositories are labelled ${label}: give each once"
    labels+="${label} "
    CONFIGS+=("${config}")
  done

  RUBY="$(cd "${GEM}" && mise which ruby)" || oracle_die "mise cannot find ruby for ${GEM}"
  BUNDLE="$(cd "${GEM}" && mise which bundle)" || oracle_die "mise cannot find bundle for ${GEM}"
  [[ -x ${RUBY} && -x ${BUNDLE} ]] || oracle_die "ruby or bundle is not executable"

  CHILD_PATH="${FAKE_GIT_DIR}:${FAKE_DIR}:${RUBY%/*}:/usr/bin:/bin"
  oracle_make_run_dir fleet
  CHILD_HOME="${RUN_DIR}/home"
  mkdir -p "${CHILD_HOME}"

  fleet_self_check
}

# The same proof as lib.sh's, plus git: inside the exact environment of the
# children, every command able to reach a network, a container or a forge is a
# fake, and the fakes log and behave as described.
fleet_self_check() {
  local name resolved log="${RUN_DIR}/selfcheck.log" gitlog="${RUN_DIR}/selfcheck.git" status

  printf 'self-check (PATH=%s)\n' "${CHILD_PATH}"
  for name in git "${FAKE_NAMES[@]}"; do
    resolved="$(env -i PATH="${CHILD_PATH}" /bin/bash -c "command -v ${name}")" || resolved=''
    if [[ ${name} == git ]]; then
      [[ ${resolved} == "${FAKE_GIT_DIR}/git" ]] || oracle_die "self-check failed: command -v git gives '${resolved}', expected ${FAKE_GIT_DIR}/git"
    elif [[ ${resolved} != "${FAKE_DIR}/${name}" ]]; then
      oracle_die "self-check failed: command -v ${name} gives '${resolved}', expected ${FAKE_DIR}/${name}"
    fi
    printf '  command -v %-7s -> %s\n' "${name}" "${resolved}"
  done

  : >"${log}"
  : >"${gitlog}"
  env -i PATH="${CHILD_PATH}" ORACLE_LOG="${log}" /bin/bash -c 'docker self check; curl https://example.invalid' >/dev/null
  status=$?
  [[ ${status} -eq 0 ]] || oracle_die "self-check failed: the fakes exited ${status}"
  [[ "$(tr '\n' '|' <"${log}")" == '--- call|self|check|--- call curl|https://example.invalid|' ]] ||
    oracle_die "self-check failed: unexpected fake log"

  mkdir -p "${RUN_DIR}/selfcheck/chosen" "${RUN_DIR}/selfcheck/other"
  (cd "${RUN_DIR}/selfcheck/other" && env -i PATH="${CHILD_PATH}" ORACLE_GIT_LOG="${gitlog}" ORACLE_GIT_FAIL=chosen git pull >/dev/null)
  status=$?
  [[ ${status} -eq 0 ]] || oracle_die "self-check failed: the fake git exited ${status} outside the chosen repository"
  (cd "${RUN_DIR}/selfcheck/chosen" && env -i PATH="${CHILD_PATH}" ORACLE_GIT_LOG="${gitlog}" ORACLE_GIT_FAIL=chosen git pull >/dev/null 2>&1)
  status=$?
  [[ ${status} -eq 1 ]] || oracle_die "self-check failed: the fake git exited ${status} in the chosen repository, expected 1"
  [[ "$(tr '\n' '|' <"${gitlog}")" == "${RUN_DIR}/selfcheck/other"$'\t''pull|'"${RUN_DIR}/selfcheck/chosen"$'\t''pull|' ]] ||
    oracle_die "self-check failed: unexpected fake git log"

  resolved="$(env -i PATH="${CHILD_PATH}" /bin/bash -c 'command -v ruby')"
  [[ ${resolved} == "${RUBY}" ]] || oracle_die "self-check failed: ruby resolves to '${resolved}'"
  printf '  command -v ruby    -> %s\n  fakes log and exit as told: ok\n' "${resolved}"
}

# fleet_run <side: gem|bin> <out prefix> <args>... : one child, bounded by
# timeout 60, from the configuration repository of the work copy, in an
# environment built from scratch. Writes <out>.out, .err, .exit, .calls (the
# fakes of lib.sh), .callers and .git (the fake git's log).
fleet_run() {
  local side=$1 out=$2
  shift 2
  local -a base cmd
  base=(
    "PATH=${CHILD_PATH}" "LANG=en_US.UTF-8" "LC_ALL=en_US.UTF-8" "HOME=${CHILD_HOME}"
    "ORACLE_LOG=${out}.calls" "ORACLE_CALLERS=${out}.callers"
    "ORACLE_GIT_LOG=${out}.git" "ORACLE_GIT_FAIL=${FAIL_REPO}"
  )
  if [[ ${side} == gem ]]; then
    cmd=("BUNDLE_GEMFILE=${GEM}/Gemfile" "${RUBY}" "${BUNDLE}" exec "${RUBY}" "-I${GEM}/lib" "${GEM}/exe/donico-manager" "$@")
  else
    cmd=("${BIN}" "$@")
  fi
  : >"${out}.calls"
  : >"${out}.callers"
  : >"${out}.git"
  (cd "${CFG}" && timeout 60 env -i "${base[@]}" "${cmd[@]}" >"${out}.out" 2>"${out}.err")
  printf '%s\n' "$?" >"${out}.exit"
}

# The line every file a generator may write holds before each side runs. On a
# real fleet those files always exist beforehand: the generators must rewrite
# them, not append, and leave alone those they skip. A sentinel rather than
# the committed text, so that a side that writes nothing never passes on what
# was already there.
FLEET_SENTINEL='oracle sentinel: this file was not rewritten'

# Overwrites with the sentinel the root README, the heritage file and every
# image README already in the workspace.
fleet_plant_sentinels() {
  local file
  mkdir -p "$(dirname "${CFG}/${HERITAGE}")" || return 1
  for file in "${CFG}/README.md" "${CFG}/${HERITAGE}" "${WS}"/*/README.md; do
    # An empty workspace leaves the pattern itself.
    [[ ${file} == "${WS}/*/README.md" ]] && continue
    printf '%s\n' "${FLEET_SENTINEL}" >"${file}" || return 1
  done
}

# fleet_side <side> : recreates the work copy from the pristine one, plants the
# sentinels, runs the commands and keeps every file a generator may have
# written or left.
fleet_side() {
  local side=$1 gen image_readmes
  rsync -a --delete "${PRISTINE}/" "${WORK_COPY}/" || return 1
  fleet_plant_sentinels || return 1

  if [[ ${side} == gem ]]; then
    image_readmes=(update-image-readmes)
  else
    image_readmes=(repos update-readme)
  fi

  fleet_run "${side}" "${WORK}/${side}.repos-list" repos list
  if [[ ${side} == gem ]]; then
    # The repository where the fake git fails: the first one the gem lists as
    # cloned (the reference chooses, never the binary).
    FAIL_REPO="$(sed -nE 's/^Repository exists: (.*)$/\1/p' "${WORK}/gem.repos-list.out" | head -n 1)"
    printf '%s\n' "${FAIL_REPO}" >"${WORK}/fail-repo"
  fi
  local sweep
  for sweep in "${FLEET_SWEEPS[@]}"; do
    fleet_run "${side}" "${WORK}/${side}.repos-${sweep}" repos "${sweep}"
  done
  fleet_run "${side}" "${WORK}/${side}.update-readme" update-readme
  fleet_run "${side}" "${WORK}/${side}.image-readmes" "${image_readmes[@]}"
  fleet_run "${side}" "${WORK}/${side}.heritage" heritage

  local files="${WORK}/${side}.files" readme
  mkdir -p "${files}/images"
  [[ -f ${CFG}/README.md ]] && cp "${CFG}/README.md" "${files}/README.md"
  [[ -f ${CFG}/${HERITAGE} ]] && cp "${CFG}/${HERITAGE}" "${files}/heritage"
  for readme in "${WS}"/*/README.md; do
    [[ -f ${readme} ]] || continue
    gen="${readme%/README.md}"
    cp "${readme}" "${files}/images/${gen##*/}"
  done
  return 0
}

# fleet_pair <what> <gem exit wanted> : stdout, status and the fakes' logs of
# one command, gem against binary.
fleet_pair() {
  local what=$1 want=$2 g="${WORK}/gem.$1" b="${WORK}/bin.$1"
  local gs bs problems='' log
  gs="$(<"${g}.exit")"
  bs="$(<"${b}.exit")"
  if [[ ${gs} != "${want}" ]]; then
    oracle_record GEMFAIL "${what}" "gem exited ${gs}, expected ${want}: $(oracle_first_error "${g}.err" "${g}.out")"
    return
  fi
  if [[ ${what} == repos-* && ${what} != repos-list && -n ${FAIL_REPO} && ! -s ${g}.git ]]; then
    oracle_record GEMFAIL "${what}" "the gem never ran git"
    return
  fi

  [[ ${gs} == "${bs}" ]] || problems+="exit status: gem ${gs}, binary ${bs}"$'\n'
  if ! cmp -s "${g}.out" "${b}.out"; then
    problems+="stdout (< gem, > binary):"$'\n'"$(diff "${g}.out" "${b}.out" | head -40)"$'\n'
  fi
  for log in git calls; do
    if ! cmp -s "${g}.${log}" "${b}.${log}"; then
      problems+="${log} log (< gem, > binary):"$'\n'"$(diff "${g}.${log}" "${b}.${log}" | head -40)"$'\n'
    fi
  done
  fleet_verdict "${what}" "gem=${gs} bin=${bs}" "${problems}"
}

# fleet_file <what> <gem file> <binary file> [normalise] : one generated file.
# The gem must have written it; the binary must have written the same.
fleet_file() {
  local what=$1 g=$2 b=$3 normalise=${4:-} problems='' n
  # The gem's file as compared, kept apart from the files each side wrote.
  n="${WORK}/compared/${what}.${REC_REPO}"
  mkdir -p "${WORK}/compared"
  # The root README and the heritage file are always written by the gem: one
  # that is missing or still holds the sentinel means the gem misbehaved, and
  # the comparison would prove nothing.
  if [[ ${what} != image-readme ]] && { [[ ! -f ${g} ]] || [[ "$(<"${g}")" == "${FLEET_SENTINEL}" ]]; }; then
    oracle_record GEMFAIL "${what}" "the gem did not rewrite the ${what}"
    return
  fi
  # An image README only one side has is a difference, whichever side it is.
  if [[ ! -f ${g} ]]; then
    problems="only the binary has it"
  elif [[ ! -f ${b} ]]; then
    problems="only the gem has it"
  else
    if [[ -n ${normalise} ]]; then
      # Difference 2: the image README says `donico help` where the gem
      # wrote `bin/rake help`. Gem side only, and nothing else.
      sed 's#bin/rake help#donico help#g' "${g}" >"${n}"
    else
      cp "${g}" "${n}"
    fi
    if ! cmp -s "${n}" "${b}"; then
      problems="(< gem, > binary):"$'\n'"$(diff "${n}" "${b}" | head -40)"
    fi
  fi
  fleet_verdict "${what}" "file" "${problems}"
}

fleet_verdict() {
  local what=$1 summary=$2 problems=$3
  if [[ -z ${problems} ]]; then
    oracle_record SAME "${what}" "same ${summary}"
  else
    oracle_record DIFF "${what}" "DIFFERENT ${summary}"
    oracle_detail "--- ${REC_LABEL}/${REC_REPO} [${what}] ${summary}" "${problems}"
  fi
}

# The workspace and the heritage output of a manifest, read with the gem's
# Ruby: one per line.
fleet_manifest() {
  env -i LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 "${RUBY}" -ryaml -e '
    data = YAML.safe_load_file(ARGV[0])
    puts data["workspace"].to_s
    puts (data["heritage_output"] || "doc/image-heritage.md").to_s
  ' "$1"
}

# fleet_worker <label> <configuration repository>
fleet_worker() {
  local label=$1 config=$2 base workspace ws_abs ws_copy cfg_name
  base="${RUN_DIR}/repos/${label}"
  WORK="${RUN_DIR}/work/${label}"
  mkdir -p "${WORK}" "${base}/pristine"

  local -a manifest=()
  mapfile -t manifest < <(fleet_manifest "${config}/donico-manager.yml")
  if [[ ${#manifest[@]} -ne 2 || -z ${manifest[0]} ]]; then
    oracle_record GEMFAIL setup "cannot read workspace and heritage_output from donico-manager.yml"
    return
  fi
  workspace=${manifest[0]}
  HERITAGE=${manifest[1]}
  if [[ ${workspace} == /* ]]; then
    oracle_record GEMFAIL setup "absolute workspace ${workspace}: no copy can stand beside it"
    return
  fi
  if ! ws_abs="$(cd "${config}" && cd "${workspace}" 2>/dev/null && pwd -P)"; then
    oracle_record GEMFAIL setup "workspace ${workspace} does not exist"
    return
  fi

  cfg_name="${config##*/}"
  PRISTINE="${base}/pristine"
  WORK_COPY="${base}/work"
  rsync -a "${ORACLE_COPY_EXCLUDES[@]}" "${config}/" "${PRISTINE}/${cfg_name}/" || {
    oracle_record GEMFAIL setup 'cannot copy the configuration repository'
    return
  }
  # A workspace outside the configuration repository (`../docker-images`)
  # is copied beside it, at the same relative place.
  if [[ ${ws_abs} != "${config}" && ${ws_abs} != "${config}/"* ]]; then
    ws_copy="$(realpath -m "${PRISTINE}/${cfg_name}/${workspace}")"
    if [[ ${ws_copy} != "${PRISTINE}/"?* || ${ws_copy} == "${PRISTINE}/${cfg_name}" ]]; then
      oracle_record GEMFAIL setup "workspace ${workspace} would be copied outside the copy"
      return
    fi
    mkdir -p "${ws_copy}"
    rsync -a "${ORACLE_COPY_EXCLUDES[@]}" "${ws_abs}/" "${ws_copy}/" || {
      oracle_record GEMFAIL setup 'cannot copy the workspace'
      return
    }
  fi
  mkdir -p "${WORK_COPY}"
  CFG="${WORK_COPY}/${cfg_name}"
  WS="$(realpath -m "${CFG}/${workspace}")"

  FAIL_REPO=''
  fleet_side gem || {
    oracle_record GEMFAIL setup 'cannot prepare the copy for the gem'
    return
  }
  fleet_side bin || {
    oracle_record GEMFAIL setup 'cannot prepare the copy for the binary'
    return
  }

  local sweep want=0
  fleet_pair repos-list 0
  [[ -n ${FAIL_REPO} ]] && want=1
  for sweep in "${FLEET_SWEEPS[@]}"; do
    fleet_pair "repos-${sweep}" "${want}"
  done
  fleet_pair update-readme 0
  fleet_pair image-readmes 0
  fleet_pair heritage 0

  fleet_file root-readme "${WORK}/gem.files/README.md" "${WORK}/bin.files/README.md"
  fleet_file heritage-file "${WORK}/gem.files/heritage" "${WORK}/bin.files/heritage"
  local name
  local -a names=()
  mapfile -t names < <( (ls -A "${WORK}/gem.files/images" && ls -A "${WORK}/bin.files/images") | LC_ALL=C sort -u)
  # The gem must have rewritten at least one image README, or the image
  # README comparisons only compare sentinels. Captured, not piped into
  # `grep -q`: under pipefail, a reader that stops at its first line kills a
  # long listing with SIGPIPE, and the pipeline then reads as a failure.
  local rewritten
  rewritten="$(grep -L -x -F "${FLEET_SENTINEL}" "${WORK}/gem.files/images"/* 2>/dev/null)" || true
  if [[ -z ${rewritten} ]]; then
    oracle_record GEMFAIL image-readme "the gem rewrote no image README"
  fi
  for name in ${names[@]+"${names[@]}"}; do
    REC_REPO=${name}
    fleet_file image-readme "${WORK}/gem.files/images/${name}" "${WORK}/bin.files/images/${name}" normalise
  done
  REC_REPO=-
}

# One worker per configuration repository, at most ORACLE_PARALLEL at a time.
fleet_for_each() {
  local config label
  for config in "${CONFIGS[@]}"; do
    label="$(fleet_label "${config}")"
    if [[ ! -f ${config}/donico-manager.yml ]]; then
      printf 'NOCFG\t-\t%s\t-\t%s\n' "${label}" 'no donico-manager.yml' >"${RUN_DIR}/rec/${label}.tsv"
      continue
    fi
    while [[ $(jobs -pr | wc -l) -ge ${ORACLE_PARALLEL} ]]; do
      sleep 0.2
    done
    (
      REC_LABEL=${label}
      REC_REPO=-
      REC_FILE="${RUN_DIR}/rec/${label}.tsv"
      : >"${REC_FILE}"
      fleet_worker "${label}" "${config}"
      printf 'DONE\t-\t%s\t-\t-\n' "${label}" >>"${REC_FILE}"
      printf 'done %s\n' "${label}" >&2
    ) &
  done
  wait
}

# The report, from the records; `N compared, M different` last. Returns 1
# unless something was compared, nothing differs, the gem never misbehaved and
# every worker reached its end.
fleet_summary() {
  local started=$1 rec_dir="${RUN_DIR}/rec" all="${RUN_DIR}/all.tsv"
  cat "${rec_dir}"/*.tsv >"${all}" 2>/dev/null || : >"${all}"

  printf '\nSkipped and failing configuration repositories\n'
  awk -F'\t' '$1 == "NOCFG" { printf "  no donico-manager.yml: %s\n", $3 } $1 == "GEMFAIL" { printf "  gem failure  %s [%s] %s: %s\n", $3, $2, $4, $5 }' "${all}" | sort

  if compgen -G "${rec_dir}/*.diff" >/dev/null && [[ -n "$(cat "${rec_dir}"/*.diff)" ]]; then
    printf '\nDifferences\n'
    cat "${rec_dir}"/*.diff
  fi

  printf '\nPer fleet and comparison (same / different / gem failure)\n'
  awk -F'\t' '$1 == "SAME" || $1 == "DIFF" || $1 == "GEMFAIL" { key = $3 "\t" $2; n[key] = 1; c[key "\t" $1]++ }
    END { for (k in n) { split(k, p, "\t"); printf "  %-34s %-16s %5d / %d / %d\n", p[1], p[2], c[k "\tSAME"], c[k "\tDIFF"], c[k "\tGEMFAIL"] } }' "${all}" | sort

  printf '\nPer fleet (same / different / gem failure)\n'
  awk -F'\t' '$1 == "SAME" || $1 == "DIFF" || $1 == "GEMFAIL" { n[$3] = 1; c[$3 "\t" $1]++ }
    END { for (k in n) printf "  %-34s %5d / %d / %d\n", k, c[k "\tSAME"], c[k "\tDIFF"], c[k "\tGEMFAIL"] }' "${all}" | sort

  local file unfinished=0
  for file in "${rec_dir}"/*.tsv; do
    [[ -f ${file} ]] || continue
    grep -qE '^(DONE|NOCFG)'$'\t' "${file}" && continue
    [[ ${unfinished} -eq 0 ]] && printf '\nUnfinished fleets (the worker died: nothing after its last record was compared)\n'
    printf '  %s\n' "$(basename "${file}" .tsv)"
    unfinished=$((unfinished + 1))
  done

  local compared different gemfail
  compared="$(awk -F'\t' '$1 == "SAME" || $1 == "DIFF" { n++ } END { print n + 0 }' "${all}")"
  different="$(awk -F'\t' '$1 == "DIFF" { n++ } END { print n + 0 }' "${all}")"
  gemfail="$(awk -F'\t' '$1 == "GEMFAIL" { n++ } END { print n + 0 }' "${all}")"
  printf '\nelapsed: %d s\n' "$((SECONDS - started))"
  printf '%d gem failure(s) (the comparisons on which the gem itself misbehaved)\n' "${gemfail}"
  [[ ${unfinished} -eq 0 ]] || printf '%d unfinished fleet(s)\n' "${unfinished}"
  [[ ${compared} -gt 0 ]] || printf 'nothing was compared: check the configuration repositories\n'
  printf '%d compared, %d different\n' "${compared}" "${different}"
  [[ ${compared} -gt 0 && ${different} -eq 0 && ${gemfail} -eq 0 && ${unfinished} -eq 0 ]]
}

main() {
  local started=$SECONDS
  fleet_init "$@"
  fleet_for_each
  fleet_summary "${started}"
}

main "$@"
