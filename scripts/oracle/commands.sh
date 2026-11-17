#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2031 # ORACLE_VARS and EXTRA_ENV are read by lib.sh; the workers are subshells on purpose
#
# Design 8, second check: for every matrix row of every repository and every
# action of build test push clean login, plus lint-dockerfile, runs the Ruby gem
# then the binary on a copy of the repository, and compares the docker calls
# they make (a fake docker records them), the exit status and stdout.
#
#   commands.sh <gem checkout> <bin/donico> <fleet>...
#
# Ends with `N compared, M different`; exits 1 if M > 0. See README.md.

set -o nounset
set -o pipefail

# shellcheck source=scripts/oracle/lib.sh
source "$(cd "${BASH_SOURCE[0]%/*}" && pwd -P)/lib.sh"

# commands_pair <pass> <task> <action> <gem exit> [<hook> [<no kill> [<suffix>]]]
#
# Runs both sides and compares them. The gem is the reference, so it has to
# behave as the pass says before the pair means anything: it must exit with
# <gem exit> and make at least one docker call, else the pair is a GEMFAIL
# (not compared, and a failure of the run unless allow-listed). A timeout of the
# binary, or any other deviation, is a difference. <hook> = 1: both sides must
# have run bin/inspec-container-up. <no kill> = 1: neither side may call kill.
# Every file of the pair is kept: ${WORK}/<pass>.<task><suffix>.{g,b}.*
commands_pair() {
  local pass=$1 task=$2 action=$3 expected=$4 hook=${5:-0} nokill=${6:-0} suffix=${7:-}
  local key="${pass}.${task}${suffix}" what
  local g="${WORK}/${key}.g" b="${WORK}/${key}.b" problems=''

  oracle_run gem "${DEST}" "${g}" "${task}"
  oracle_run bin "${DEST}" "${b}" "${task}"

  local gs bs
  gs="$(<"${g}.exit")"
  bs="$(<"${b}.exit")"
  what="${task}${suffix} gem=${gs} bin=${bs}"

  # The gem must have run what the pass is about.
  local why=''
  if [[ ${gs} == 124 ]]; then
    why='the gem timed out'
  elif [[ ${gs} != "${expected}" ]]; then
    why="the gem exited ${gs}, expected ${expected}: $(oracle_first_error "${g}.err" "${g}.out")"
  elif [[ ! -s ${g}.calls ]]; then
    why='the gem made no docker call'
  elif [[ ${hook} -eq 1 ]] && ! grep -q 'inspec-container-up' "${g}.callers"; then
    why='the hook bin/inspec-container-up made no call on the gem side'
  elif [[ ${nokill} -eq 1 ]] && grep -qx kill "${g}.calls"; then
    why='the gem called kill'
  fi
  if [[ -n ${why} ]]; then
    oracle_record GEMFAIL "${pass}" "${what}: ${why}"
    return
  fi

  oracle_norm_calls "${g}.calls" "${action}" >"${g}.calls.n"
  oracle_norm_calls "${b}.calls" "${action}" >"${b}.calls.n"
  # Every normalised call log of the repository, for the host inventory.
  cat "${g}.calls.n" "${b}.calls.n" >>"${WORK}.corpus"
  oracle_norm_stdout gem "${action}" "${g}.out" >"${g}.out.n"
  oracle_norm_stdout bin "${action}" "${b}.out" >"${b}.out.n"

  [[ ${bs} != 124 ]] || problems+="the binary timed out"$'\n'
  [[ ${gs} == "${bs}" ]] || problems+="exit status: gem ${gs}, binary ${bs}"$'\n'
  if ! cmp -s "${g}.calls.n" "${b}.calls.n"; then
    problems+="call log (< gem, > binary):"$'\n'"$(diff "${g}.calls.n" "${b}.calls.n" | head -40)"$'\n'
  fi
  if ! cmp -s "${g}.out.n" "${b}.out.n"; then
    problems+="stdout (< gem, > binary):"$'\n'"$(diff "${g}.out.n" "${b}.out.n" | head -40)"$'\n'
  fi
  if [[ ${hook} -eq 1 ]] && ! grep -q 'inspec-container-up' "${b}.callers"; then
    problems+="the hook bin/inspec-container-up made no call on the binary side"$'\n'
  fi
  if [[ ${nokill} -eq 1 ]] && grep -qx kill "${b}.calls"; then
    problems+="the binary called kill after a start that gave no container id"$'\n'
  fi

  if [[ -z ${problems} ]]; then
    oracle_record SAME "${pass}" "${what}"
  else
    oracle_record DIFF "${pass}" "${what}"
    oracle_detail "--- ${REC_LABEL}/${REC_REPO} ${task}${suffix} [${pass}] gem=${gs} bin=${bs}" "${problems}"
  fi
}

# commands_expect_failure <pass> <task> : a declared secret is missing. Both
# sides must exit 1, make no docker call and name the declaration. Stdout is not
# compared: the messages differ by design (item 9). A gem that does not do this
# is a GEMFAIL.
commands_expect_failure() {
  local pass=$1 task=$2
  local g="${WORK}/${pass}.${task}.g" b="${WORK}/${pass}.${task}.b" problems='' what

  oracle_run gem "${DEST}" "${g}" "${task}"
  oracle_run bin "${DEST}" "${b}" "${task}"
  what="${task} gem=$(<"${g}.exit") bin=$(<"${b}.exit")"

  local gs
  gs="$(<"${g}.exit")"
  # The files are grep's own arguments: `cat ... | grep -q` fails by SIGPIPE
  # under pipefail when grep stops at an early match in a large output.
  if [[ ${gs} != 1 || -s ${g}.calls ]] || ! grep -q 'is declared in secret_' "${g}.err" "${g}.out"; then
    oracle_record GEMFAIL "${pass}" "${what}: the gem did not stop on the missing secret"
    return
  fi

  [[ "$(<"${b}.exit")" == 1 ]] || problems+="binary: exit status $(<"${b}.exit"), expected 1"$'\n'
  [[ ! -s "${b}.calls" ]] || problems+="binary: docker was called: $(tr '\n' ' ' <"${b}.calls" | cut -c1-200)"$'\n'
  grep -q 'is declared in secret_' "${b}.err" "${b}.out" || problems+="binary: no message naming the secret declaration"$'\n'

  if [[ -z ${problems} ]]; then
    oracle_record SAME "${pass}" "${what}"
  else
    oracle_record DIFF "${pass}" "${what}"
    oracle_detail "--- ${REC_LABEL}/${REC_REPO} ${task} [${pass}]" "${problems}"
  fi
}

commands_repo() {
  local label=$1 name=$2 src=$3 tag="$1/$2"
  WORK="${RUN_DIR}/work/${label}.${name}"
  mkdir -p "${WORK}"

  DEST="$(oracle_copy_repo "${label}" "${name}" "${src}")" || {
    oracle_record GEMFAIL copy 'cannot copy the repository'
    return
  }
  oracle_prepare_copy "${DEST}"

  # The matrix, the build arg names and the Inspec input names, from the gem.
  ORACLE_VARS=''
  EXTRA_ENV=()
  oracle_run gem "${DEST}" "${WORK}/info" info "${ORACLE_INFO_RB}"
  if [[ "$(<"${WORK}/info.exit")" != 0 ]]; then
    oracle_record GEMFAIL load "$(oracle_first_error "${WORK}/info.err" "${WORK}/info.out")"
    return
  fi

  local -a rows=() row_secrets=()
  local kind a b c d
  while IFS=$'\x1f' read -r kind a b c d; do
    case "${kind}" in
      ROW)
        rows+=("${a}:${b}")
        row_secrets+=("${c}")
        ;;
      VARS) ORACLE_VARS="${a}" ;;
    esac
  done <"${WORK}/info.out"
  : "${d:-}"

  # A gem that lists no row leaves nothing to compare but the lint: say so
  # rather than count the repository as covered.
  if [[ ${#rows[@]} -eq 0 ]]; then
    oracle_record GEMFAIL load 'the gem listed no matrix row'
    return
  fi

  oracle_scan_hooks "${DEST}" "${tag}"
  local test_ok=1
  if [[ -n ${HOOK_UNKNOWN} ]]; then
    test_ok=0
    oracle_record SKIP test "hook command not classified: ${HOOK_UNKNOWN}"
  fi

  local index row id action v suffix other
  local -a secret_env ids secrets hook_env
  for index in "${!rows[@]}"; do
    row="${rows[index]}"
    read -r -a ids <<<"${row_secrets[index]}"
    secret_env=()
    for id in ${ids[@]+"${ids[@]}"}; do
      secret_env+=("${id}=${ORACLE_SECRET_VALUE}")
    done

    # Pass 1: success, every declared secret present. The gem must exit 0 and
    # make docker calls. `test` runs once per variant of the hook's dummy values.
    for action in build push clean login; do
      EXTRA_ENV=(${secret_env[@]+"${secret_env[@]}"})
      commands_pair success "${row}:${action}" "${action}" 0
    done
    if [[ ${test_ok} -eq 1 ]]; then
      for v in "${!HOOK_VARIANTS[@]}"; do
        read -r -a hook_env <<<"${HOOK_VARIANTS[v]}"
        EXTRA_ENV=(${secret_env[@]+"${secret_env[@]}"} ${hook_env[@]+"${hook_env[@]}"})
        suffix=''
        [[ ${#HOOK_VARIANTS[@]} -gt 1 ]] && suffix=".v${v}"
        commands_pair success "${row}:test" test 0 "${HAS_UP}" 0 "${suffix}"
      done
    fi

    # Pass 2: each declared secret missing in turn.
    for id in ${ids[@]+"${ids[@]}"}; do
      secrets=()
      for other in "${ids[@]}"; do
        [[ ${other} == "${id}" ]] || secrets+=("${other}=${ORACLE_SECRET_VALUE}")
      done
      for action in build push; do
        EXTRA_ENV=(${secrets[@]+"${secrets[@]}"})
        commands_expect_failure missing-secret "${row}:${action}"
      done
    done

    # Pass 3: docker failures. The expected exit code is the gem's own, stated
    # per sub-pass:
    #  - clean: Tasks::Bake#clean exits with `results.include?(false) ? 1 : 0`
    #    (lib/donico/tasks/bake.rb), so the 7 of docker becomes 1.
    #  - test, start: `container_id=$(container_up ...)` fails under errexit in
    #    exe/inspec, which exits with the status of the substitution, 125.
    #  - test, Inspec: run_spec (bash/donico.lib.sh) ends on the docker run of
    #    Inspec, whose 100 is the status of exe/inspec; container_down returns 0
    #    from the EXIT trap so it does not override it.
    #  - test, cleanup: `docker kill` is the last command of the EXIT trap under
    #    errexit, so its 7 becomes the status of exe/inspec.
    EXTRA_ENV=(${secret_env[@]+"${secret_env[@]}"} 'ORACLE_FAIL_MATCH=^rmi ' ORACLE_FAIL_STATUS=7)
    commands_pair fail-clean "${row}:clean" clean 1

    if [[ ${test_ok} -eq 1 ]]; then
      if [[ ${HAS_UP} -eq 0 ]]; then
        EXTRA_ENV=(${secret_env[@]+"${secret_env[@]}"} ${HOOK_EXPORTS[@]+"${HOOK_EXPORTS[@]}"} 'ORACLE_FAIL_MATCH=^run --rm -d ' ORACLE_FAIL_STATUS=125)
        commands_pair fail-test-start "${row}:test" test 125
        # The start fails and prints no container id: nothing to kill.
        EXTRA_ENV=(${secret_env[@]+"${secret_env[@]}"} ${HOOK_EXPORTS[@]+"${HOOK_EXPORTS[@]}"} 'ORACLE_FAIL_MATCH=^run --rm -d ' ORACLE_FAIL_STATUS=125 ORACLE_FAIL_SILENT=1)
        commands_pair fail-test-start-silent "${row}:test" test 125 0 1
      else
        oracle_record SKIP fail-test-start "${row}:test the hook, not the fake docker, starts the container"
        oracle_record SKIP fail-test-start-silent "${row}:test the hook, not the fake docker, starts the container"
      fi
      EXTRA_ENV=(${secret_env[@]+"${secret_env[@]}"} ${HOOK_EXPORTS[@]+"${HOOK_EXPORTS[@]}"} 'ORACLE_FAIL_MATCH= inspec exec ' ORACLE_FAIL_STATUS=100)
      commands_pair fail-test-inspec "${row}:test" test 100
      EXTRA_ENV=(${secret_env[@]+"${secret_env[@]}"} ${HOOK_EXPORTS[@]+"${HOOK_EXPORTS[@]}"} 'ORACLE_FAIL_MATCH=^kill ' ORACLE_FAIL_STATUS=7)
      commands_pair fail-test-cleanup "${row}:test" test 7
    fi
  done

  # lint-dockerfile concerns the repository, not a row. Common.rake exits with
  # `Kernel.exit(1)` when a run failed, so the 7 of docker becomes 1.
  EXTRA_ENV=()
  commands_pair success lint-dockerfile lint-dockerfile 0
  EXTRA_ENV=('ORACLE_FAIL_MATCH= hadolint ' ORACLE_FAIL_STATUS=7)
  commands_pair fail-lint lint-dockerfile lint-dockerfile 1
}

main() {
  local started=$SECONDS
  oracle_init commands "$@"
  oracle_for_each_repo commands_repo
  oracle_summary "${started}"
}

main "$@"
