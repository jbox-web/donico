#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034 # the variables are read by the scripts that source this file
#
# Shared by generated-files.sh and commands.sh: runs the Ruby gem (the oracle)
# and the binary on throwaway copies of image repositories, always inside an
# environment built from scratch whose PATH starts with the fake commands.
# fleet.sh uses its fakes, excludes, run directory and records only.
# Sourced, never executed. See README.md.

# One root, under the owner's scratch area, never the repositories. A caller
# may point ORACLE_ROOT at a subdirectory of it (self-test.sh does, so that it
# never wipes the records of a run over the fleets); anything else is refused
# by oracle_init.
ORACLE_BASE="${HOME}/.local/tmp/claude-jbox-donico-oracle"
ORACLE_ROOT="${ORACLE_ROOT:-${ORACLE_BASE}}"
ORACLE_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd -P)"
FAKE_DIR="${ORACLE_DIR}/fake"

# Every command that could reach a network or start a container, faked.
FAKE_NAMES=(docker curl wget ssh scp sftp nc ncat telnet ftp rsync)

# Words a hook script may use without anything to report: shell syntax and
# builtins. Anything else must be a fake, a function of the script itself or
# one of the local tools below, or the script is not run.
HOOK_SHELL_WORDS=' set shift echo exit return local export declare readonly if then else elif fi for while until do done case esac function in cd pwd test [ [[ true false unset read printf : { } ( ) ;; '
# The explicit allow-list of local tools that cannot reach a network nor start
# anything: they read or reshape text and files, or wait. A hook calling a
# command that is neither faked, nor defined by the script, nor a shell word
# above, nor in this list gets its repository's `test` skipped and reported.
# awk and sed are not in it: both can start a command (`system()`, the `e`
# flag), which the scan below cannot see inside their program text. `trap` is
# not a shell word here for the same reason: its argument is code.
HOOK_LOCAL_TOOLS=' cat grep cut head tail tr sort uniq wc date basename dirname sleep mkdir touch '

ORACLE_TIMESTAMP='2026-07-31T10:20:30+02:00'
ORACLE_SECRET_VALUE='oracle-secret'
ORACLE_PARALLEL=4

# GEMFAIL records that do not make a script fail: extended regular expressions
# matched against "<fleet>/<repository><TAB><pass><TAB><reason>". Empty on
# purpose: a pair on which the gem itself misbehaves means the comparison proved
# nothing, so by default it fails the run. Add an entry only with the reason in
# a comment above it.
ORACLE_GEMFAIL_ALLOWED=()

# The array of extra environment entries the next run adds (secrets, dummy
# variables of the hooks, failure injection).
EXTRA_ENV=()

oracle_die() {
  printf 'oracle: %s\n' "$*" >&2
  exit 2
}

# Names that the oracle itself sets in every child: never exported as dummies.
oracle_reserved_name() {
  case "$1" in
    PATH | HOME | LANG | LC_ALL | CI_* | DONICO_* | BUNDLE_GEMFILE | ORACLE_* | PWD | OLDPWD | IFS | RANDOM | LINENO | UID | EUID | USER | HOSTNAME | SHLVL | TERM | BASH_SOURCE | BASH_VERSION | FUNCNAME) return 0 ;;
  esac
  return 1
}

# oracle_init <script name> <gem dir> <binary> <fleet>...
# Validates the arguments, resolves ruby and bundle once, recreates the run
# directory and aborts unless the fakes win over the real commands.
oracle_init() {
  # Counted before anything is read: under nounset a missing argument would
  # otherwise end the script on "unbound variable" instead of the usage.
  [[ $# -ge 4 ]] || oracle_die "usage: ${1:-<script>}.sh <gem checkout> <bin/donico> <fleet>... (<fleet> = .../ci-config/docker-images)"
  local script=$1 gem=$2 bin=$3
  shift 3

  [[ -f "${gem}/lib/donico.rb" && -f "${gem}/exe/inspec" ]] || oracle_die "not the donico gem checkout: ${gem}"
  [[ -f ${bin} && -x ${bin} ]] || oracle_die "not an executable: ${bin}"

  GEM="$(cd "${gem}" && pwd -P)"
  # dirname, not ${bin%/*}: a binary named without a slash is in the current
  # directory, and the expansion alone would have given "/<name>".
  BIN="$(cd "$(dirname "${bin}")" && pwd -P)/${bin##*/}"
  [[ -x ${BIN} ]] || oracle_die "not an executable: ${BIN}"
  FLEETS=()
  local fleet label labels=' '
  for fleet in "$@"; do
    [[ -d ${fleet} ]] || oracle_die "not a directory: ${fleet}"
    fleet="$(cd "${fleet}" && pwd -P)"
    # Two fleets under one label would copy into the same directory and write
    # the same record files, from two workers at once.
    label="$(oracle_fleet_label "${fleet}")"
    [[ ${labels} != *" ${label} "* ]] || oracle_die "two fleets are labelled ${label}: give each fleet once"
    labels+="${label} "
    FLEETS+=("${fleet}")
  done

  RUBY="$(cd "${GEM}" && mise which ruby)" || oracle_die "mise cannot find ruby for ${GEM}"
  BUNDLE="$(cd "${GEM}" && mise which bundle)" || oracle_die "mise cannot find bundle for ${GEM}"
  [[ -x ${RUBY} && -x ${BUNDLE} ]] || oracle_die "ruby or bundle is not executable"

  # The PATH of every child, and nothing else.
  CHILD_PATH="${FAKE_DIR}:${RUBY%/*}:/usr/bin:/bin"
  CHILD_HOME="${ORACLE_ROOT}/home"

  oracle_make_run_dir "${script}"
  mkdir -p "${CHILD_HOME}"

  oracle_self_check
}

# oracle_make_run_dir <script name> : sets RUN_DIR to ORACLE_ROOT/<script>,
# takes its lock and recreates it empty, with its repos/, rec/ and work/.
# Shared by every script of this directory (fleet.sh included).
oracle_make_run_dir() {
  local script=$1
  RUN_DIR="${ORACLE_ROOT}/${script}"
  case "${RUN_DIR}" in
    *..*) oracle_die "refusing to recreate ${RUN_DIR}" ;;
    "${ORACLE_BASE}/"?*) ;;
    *) oracle_die "refusing to recreate ${RUN_DIR}" ;;
  esac
  # One run per directory at a time: a second one would wipe the records the
  # first is writing. mkdir is the lock (atomic); the EXIT trap releases it.
  mkdir -p "${ORACLE_ROOT}"
  if ! mkdir "${RUN_DIR}.lock" 2>/dev/null; then
    oracle_die "another ${script}.sh is running on ${RUN_DIR} (or was killed: remove ${RUN_DIR}.lock)"
  fi
  # shellcheck disable=SC2064 # expanded now on purpose: the path is known here
  trap "rmdir '${RUN_DIR}.lock' 2>/dev/null" EXIT
  rm -rf "${RUN_DIR}"
  mkdir -p "${RUN_DIR}/repos" "${RUN_DIR}/rec" "${RUN_DIR}/work"
}

# Proves, inside the exact environment the children get, that the commands
# able to reach a network or a container are the fakes, and that a fake works.
# Aborts the whole script otherwise: nothing runs before this passes.
oracle_self_check() {
  local name resolved log="${RUN_DIR}/selfcheck.log" status

  printf 'self-check (PATH=%s)\n' "${CHILD_PATH}"
  for name in "${FAKE_NAMES[@]}"; do
    resolved="$(env -i PATH="${CHILD_PATH}" /bin/bash -c "command -v ${name}")" || resolved=''
    if [[ ${resolved} != "${FAKE_DIR}/${name}" ]]; then
      oracle_die "self-check failed: command -v ${name} gives '${resolved}', expected ${FAKE_DIR}/${name}"
    fi
    printf '  command -v %-7s -> %s\n' "${name}" "${resolved}"
  done

  : >"${log}"
  env -i PATH="${CHILD_PATH}" ORACLE_LOG="${log}" /bin/bash -c 'docker self check; curl https://example.invalid' >/dev/null
  status=$?
  [[ ${status} -eq 0 ]] || oracle_die "self-check failed: the fakes exited ${status}"
  [[ "$(tr '\n' '|' <"${log}")" == '--- call|self|check|--- call curl|https://example.invalid|' ]] ||
    oracle_die "self-check failed: unexpected fake log"

  resolved="$(env -i PATH="${CHILD_PATH}" /bin/bash -c 'command -v ruby')"
  [[ ${resolved} == "${RUBY}" ]] || oracle_die "self-check failed: ruby resolves to '${resolved}'"
  printf '  command -v ruby    -> %s\n  fakes log and exit 0: ok\n' "${resolved}"
}

# Files that usually carry secrets and that neither side needs: never copied.
# `.git/config` is copied with the rest of .git (the gem reads the repository):
# a remote URL that embeds a token is therefore duplicated, see README.md.
ORACLE_COPY_EXCLUDES=(
  --exclude '.env*' --exclude '*.pem' --exclude '*.key' --exclude '*.p12' --exclude '*.pfx' --exclude '*.jks'
  --exclude 'id_rsa*' --exclude 'id_ed25519*' --exclude '.npmrc' --exclude '.netrc' --exclude 'auth.json'
  --exclude 'credentials*'
)

# oracle_copy_repo <label> <name> <source> : prints the physical path of the copy.
# The copy holds the .git directory and none of the files above; the clone is
# never written.
oracle_copy_repo() {
  local label=$1 name=$2 src=$3 dest
  dest="${RUN_DIR}/repos/${label}/${name}"
  mkdir -p "${dest}"
  rsync -a "${ORACLE_COPY_EXCLUDES[@]}" "${src}/" "${dest}/" || return 1
  (cd "${dest}" && pwd -P)
}

# The gem's Inspec harness locates its library from its own path, so bin/inspec
# of the copy is a two-line script and not a symlink.
oracle_prepare_copy() {
  local dest=$1
  mkdir -p "${dest}/bin"
  rm -f "${dest}/bin/inspec"
  printf '#!/usr/bin/env bash\nexec "%s/exe/inspec" "$@"\n' "${GEM}" >"${dest}/bin/inspec"
  chmod +x "${dest}/bin/inspec"
}

# The Ruby the gem runs for the matrix: one ROW line per matrix row (distro,
# version, secret_envs ids, secret_files ids) and one VARS line with the build
# arg names and the Inspec input names, both as the gem computes them.
read -r -d '' ORACLE_INFO_RB <<'RUBY' || true
Donico.load!
images = Donico.images_list
names = images.flat_map { |i| i.build_args_hash.keys } + images.flat_map { |i| i.test_args.map { |a| a.split("=", 2).first } }
images.each do |i|
  puts ["ROW", i.distro, i.version, i.secret_envs.map { |s| s["id"] }.join(" "), i.secret_files.map { |s| s["id"] }.join(" ")].join("\u001f")
end
puts ["VARS", names.uniq.sort.join(" ")].join("\u001f")
RUBY

# oracle_run <side: gem|bin> <dir> <out prefix> <task|-> [ruby code]
# Runs one child bounded by timeout 60, in an environment built from scratch.
# Writes <out>.out, <out>.err, <out>.exit, <out>.calls (the fake log) and
# <out>.callers (which process called each fake; used to prove a hook ran).
# EXTRA_ENV is appended to the environment.
oracle_run() {
  local side=$1 dir=$2 out=$3 task=$4 code=${5:-}
  local -a base cmd
  base=(
    "PATH=${CHILD_PATH}" "LANG=en_US.UTF-8" "LC_ALL=en_US.UTF-8" "HOME=${CHILD_HOME}"
    "CI_COMMIT_TIMESTAMP=${ORACLE_TIMESTAMP}"
    "ORACLE_LOG=${out}.calls" "ORACLE_CALLERS=${out}.callers" "ORACLE_VARS=${ORACLE_VARS:-}"
  )
  if [[ ${side} == gem ]]; then
    if [[ -z ${code} ]]; then
      code='Donico.load!; Rake::Task[ARGV[0]].invoke'
    fi
    cmd=("BUNDLE_GEMFILE=${GEM}/Gemfile" "${RUBY}" "${BUNDLE}" exec "${RUBY}" -rrake "-I${GEM}/lib" -rdonico -e "${code}" "${task}")
  else
    cmd=("${BIN}" "${task}")
  fi

  : >"${out}.calls"
  : >"${out}.callers"
  local status
  (cd "${dir}" && timeout 60 env -i "${base[@]}" ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} "${cmd[@]}" >"${out}.out" 2>"${out}.err")
  status=$?
  printf '%s\n' "${status}" >"${out}.exit"
}

# oracle_norm_calls <file> <action>
# The tool image differs by design (difference 4): in a `docker run` call only,
# the argument right before `hadolint` or `inspec`. So does the environment of
# `build` and `push` (difference 22): the gem exports every build arg to
# docker, the binary BUILD_DATE alone, so for these two actions the `env` lines
# of the other names are dropped on both sides. BUILD_DATE stays compared.
oracle_norm_calls() {
  local keep_env=1
  case "${2:-}" in
    build | push) keep_env=0 ;;
  esac
  awk -v keep_env="${keep_env}" '
    keep_env == 0 && /^env / && !/^env BUILD_DATE=/ { next }
    { print }
  ' "$1" | awk '
    $0 ~ /^--- call/ { n = 0 }
    { line[NR] = $0; n++; pos[NR] = n; if (n == 2) isrun[NR] = ($0 == "run"); else isrun[NR] = 0 }
    END {
      # isrun is only set on the first argument line: spread it over the call.
      call_is_run = 0
      for (i = 1; i <= NR; i++) {
        if (line[i] ~ /^--- call/) call_is_run = 0
        if (pos[i] == 2) call_is_run = isrun[i]
        run[i] = call_is_run
      }
      for (i = 1; i <= NR; i++) {
        if (i < NR && run[i + 1] && pos[i] > 2 && (line[i + 1] == "hadolint" || line[i + 1] == "inspec")) print "<tool-image>"
        else print line[i]
      }
    }
  '
}

# oracle_norm_stdout <side> <action> <file>: the rules of the brief, no other.
oracle_norm_stdout() {
  local side=$1 action=$2 file=$3
  local -a script=()

  if [[ ${side} == gem ]]; then
    # Difference 6: the gem says bin/rake where the binary says donico.
    script+=(-e 's#bin/rake#donico#g')
  fi
  case "${action}" in
    build | push | login)
      # Difference 13: the gem never prints exec: lines when stdout is redirected.
      script+=(-e '/^exec: /d')
      ;;
    test)
      if [[ ${side} == bin ]]; then
        # Difference 11: the binary logs the docker calls of its own harness.
        script+=(-e '/^(run_cmd|with_exit_status): /d')
      fi
      ;;
  esac
  # Difference 4: the tool image, in a logged docker run.
  script+=(-e '/^(run_cmd|exec|with_exit_status): docker run /s/ [^ ]+ (hadolint|inspec)( |$)/ <tool-image> \1\2/')

  sed -E "${script[@]}" "${file}"
}

# oracle_record <status> <pass> <what> : one TSV line in this worker's record.
oracle_record() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "${REC_LABEL}" "${REC_REPO}" "$3" >>"${REC_FILE}"
}

# oracle_detail <text...> : lines for the report of the differences.
oracle_detail() {
  printf '%s\n' "$@" >>"${REC_FILE%.tsv}.diff"
}

# oracle_first_error <stderr file> <stdout file> : the first non-empty line.
# The files are grep's own arguments, not a pipe: under pipefail, a grep that
# stops at its first match kills the `cat` feeding it with SIGPIPE once the
# output is larger than a pipe buffer, and the pipeline then reads as a failure.
oracle_first_error() {
  local line
  line="$(grep -h -m1 -v '^[[:space:]]*$' "$1" "$2" 2>/dev/null | head -n 1)" || line=''
  printf '%s' "${line:-(no output)}"
}

# oracle_scan_hooks <copy> <tag>
# Sets HOOK_EXPORTS (NAME=oracle entries), HOOK_UNKNOWN (words not classified),
# HAS_UP, and appends to the worker's hook inventory the commands each script calls.
oracle_scan_hooks() {
  local dest=$1 tag=$2 script word text
  HOOK_EXPORTS=()
  HOOK_VARIANTS=('')
  HOOK_UNKNOWN=''
  HAS_UP=0

  local -a names=()
  for script in "${dest}"/bin/inspec-container-*; do
    [[ -f ${script} ]] || continue
    [[ ${script##*/} == inspec-container-up ]] && HAS_UP=1
    text="$(oracle_hook_logical "${script}")"

    local -a words=()
    while IFS= read -r word; do
      [[ -n ${word} ]] && words+=("${word}")
    done < <(oracle_hook_words "${text}" | sort -u)

    local functions reason
    functions="$(oracle_hook_functions "${text}")"
    local -a called=()
    # What the word scan cannot read is refused, not assumed harmless.
    while IFS= read -r reason; do
      [[ -n ${reason} ]] || continue
      called+=("${reason// /-}(UNKNOWN)")
      HOOK_UNKNOWN+="${tag}/${script##*/}: ${reason}; "
    done < <(oracle_hook_opaque "${text}" | sort -u)
    for word in ${words[@]+"${words[@]}"}; do
      case "${HOOK_SHELL_WORDS}" in *" ${word} "*) continue ;; esac
      [[ ${word} == *')' ]] && continue
      if [[ " ${FAKE_NAMES[*]} " == *" ${word} "* ]]; then
        called+=("${word}(fake)")
      elif [[ ${functions} == *" ${word} "* ]]; then
        continue
      elif [[ ${HOOK_LOCAL_TOOLS} == *" ${word} "* ]]; then
        called+=("${word}(local)")
      else
        called+=("${word}(UNKNOWN)")
        HOOK_UNKNOWN+="${tag}/${script##*/}: ${word}; "
      fi
    done
    printf 'HOOK\t%s/%s\t%s\n' "${tag}" "${script##*/}" "${called[*]-}" >>"${REC_FILE%.tsv}.hooks"

    local name
    while IFS= read -r name; do
      [[ -n ${name} ]] && names+=("${name}")
    done < <(oracle_hook_vars "${text}")
  done

  # Sorted and deduplicated across the scripts of the copy; one variant per
  # value of the name that has the most values (the others cycle).
  local -a uniq_names=() values=()
  local variants=1 count i value item
  while IFS= read -r name; do
    [[ -z ${name} ]] && continue
    uniq_names+=("${name}")
    read -r -a values <<<"$(oracle_dummy_values "${name}")"
    [[ ${#values[@]} -gt ${variants} ]] && variants=${#values[@]}
  done < <(printf '%s\n' ${names[@]+"${names[@]}"} | sort -u)

  HOOK_VARIANTS=()
  for ((i = 0; i < variants; i++)); do
    item=''
    for name in ${uniq_names[@]+"${uniq_names[@]}"}; do
      read -r -a values <<<"$(oracle_dummy_values "${name}")"
      count=${#values[@]}
      value="${values[i % count]}"
      item+="${name}=${value} "
    done
    HOOK_VARIANTS+=("${item% }")
  done
  # The first variant serves every pass but the successful `test`.
  read -r -a HOOK_EXPORTS <<<"${HOOK_VARIANTS[0]}"
}

# Dummy values of the variables the hooks read, by name. `oracle` for all but
# those listed: run_mode selects the branch of the gitlab-runner hook that
# starts a container (`dind)` and `default)`; any other value starts nothing,
# and the forge API call of its cleanup hook would never be reached).
oracle_dummy_values() {
  case "$1" in
    run_mode) printf 'default dind' ;;
    *) printf 'oracle' ;;
  esac
}

# The script with comments, blank lines and line continuations removed.
oracle_hook_logical() {
  sed -E -e 's/^[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$1" | sed -e ':a;/\\$/{N;s/\\\n[[:space:]]*/ /;ba}'
}

# Names of the functions the script defines, as " a b c ".
oracle_hook_functions() {
  local out
  out="$(sed -nE -e 's/^[[:space:]]*function[[:space:]]+([A-Za-z_][A-Za-z0-9_]*).*/\1/p' -e 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\(\)[[:space:]]*\{?.*/\1/p' <<<"$1" | tr '\n' ' ')"
  printf ' %s ' "${out}"
}

# oracle_hook_opaque <logical text> : one line per construct the word scan
# below cannot read reliably. That scan takes the first word of a line and the
# word after a separator; it is blind to a command that comes after a variable
# assignment (`A=1 git fetch`), after an opening brace or parenthesis on the
# same line, after a lone `&`, after the pattern of a case arm, or inside a
# process substitution. A script holding one of these is not run: its `test`
# is skipped and reported, like one that calls an unknown command.
oracle_hook_opaque() {
  local line bare flat
  while IFS= read -r line; do
    # Quoted text is not code. Double quotes first, so that an apostrophe
    # inside them ("can't") does not open a single-quoted string.
    bare="$(sed -E -e 's/"[^"]*"//g' -e "s/'[^']*'//g" <<<"${line}")"
    case "${bare}" in
      *\'*|*\"*) printf 'unbalanced quote\n'; continue ;;
    esac
    # A command substitution is a value here (`id=$(docker run ...)`): the
    # word scan reads the command inside it.
    flat="$(sed -E 's/\$\([^()]*\)//g' <<<"${bare}")"
    if grep -qE '(^|[;&|][[:space:]]*|[[:space:]](then|do|else)[[:space:]]+)([A-Za-z_][A-Za-z0-9_]*=[^[:space:];|&]*[[:space:]]+)+[A-Za-z_./][^=[:space:]]*([[:space:]]|$)' <<<"${flat}" &&
      ! grep -qE '^[[:space:]]*(local|export|declare|readonly)[[:space:]]' <<<"${flat}"; then
      printf 'command after an assignment\n'
    fi
    # A command named by a variable (`$tool fetch`): the scan cannot know it.
    grep -qE '(^[[:space:]]*|[;&|][[:space:]]*|[[:space:]](then|do|else)[[:space:]]+)\$[{A-Za-z_]' <<<"${flat}" && printf 'command named by a variable\n'
    grep -qE '(^|[^$])\{[[:space:]]*[^[:space:]]' <<<"${bare}" && printf 'command after an opening brace\n'
    grep -qE '(^|[[:space:];|&])\([[:space:]]*[^)[:space:]]' <<<"${bare}" && printf 'subshell\n'
    grep -qE '[<>]\(' <<<"${bare}" && printf 'process substitution\n'
    grep -qE '(^|[^&>])&([^&>0-9]|$)' <<<"${bare}" && printf 'background command\n'
    grep -qE '^[[:space:]]*[^[:space:]()]+\)[[:space:]]*[^[:space:];]' <<<"${bare}" && printf 'command on a case pattern line\n'
  done <<<"$1"
  return 0
}

# Command words: the first word of each logical line, the first word of each
# $( ... ), and the first word after | && || ; outside quotes.
oracle_hook_words() {
  local line stripped word quoted
  while IFS= read -r line; do
    grep -oE '\$\([[:space:]]*[^ )]+' <<<"${line}" | sed -E 's/^\$\([[:space:]]*//' || true
    stripped="${line#"${line%%[![:space:]]*}"}"
    word="${stripped%%[[:space:]]*}"
    if [[ ! ${word} =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      printf '%s\n' "${word}"
    fi
    # Backtick substitutions.
    # shellcheck disable=SC2016 # the backtick is the pattern, not an expansion
    grep -oE '`[[:space:]]*[A-Za-z_./][^[:space:]`]*' <<<"${line}" | sed -E 's/^`[[:space:]]*//' || true
    quoted="$(sed -E -e 's/"[^"]*"//g' -e "s/'[^']*'//g" <<<"${line}")"
    # The word after a keyword that introduces a command: if, then, do, else,
    # elif, while, until and the negation `!`.
    grep -oE '(^|[[:space:];|&(])(if|then|do|else|elif|while|until|!)[[:space:]]+[A-Za-z_./][^[:space:];|&)]*' <<<"${quoted}" | sed -E 's/^[[:space:];|&(]*(if|then|do|else|elif|while|until|!)[[:space:]]+//' || true
    grep -oE '(\|\||&&|\||;)[[:space:]]*[A-Za-z_./][^[:space:];|&)]*' <<<"${quoted}" | sed -E 's/^(\|\||&&|\||;)[[:space:]]*//' || true
  done <<<"$1"
}

# Variables the script reads and does not define itself: the ones the oracle
# exports as dummies. `X=${X}` does not define X, it needs X from outside.
oracle_hook_vars() {
  local text=$1 name rhs defined re
  while IFS= read -r name; do
    [[ -z ${name} ]] && continue
    oracle_reserved_name "${name}" && continue
    defined=0
    re="\\\$\\{?${name}([^A-Za-z0-9_]|\$)"
    while IFS= read -r rhs; do
      if [[ ! ${rhs} =~ ${re} ]]; then
        defined=1
        break
      fi
    done < <(sed -nE "s/^[[:space:]]*((local|export|declare)[[:space:]]+)?${name}=(.*)\$/\\3/p" <<<"${text}")
    if [[ ${defined} -eq 0 ]] && grep -qE "^[[:space:]]*for[[:space:]]+${name}[[:space:]]+in[[:space:]]" <<<"${text}"; then
      defined=1
    fi
    [[ ${defined} -eq 0 ]] && printf '%s\n' "${name}"
  done < <(grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*' <<<"${text}" | sed -E 's/^\$\{?//' | sort -u)
}

# oracle_for_each_repo <worker function> : runs `worker <label> <name> <source>`
# on every repository of the fleets, at most ORACLE_PARALLEL at a time, each in
# its own subshell with its record under ${RUN_DIR}/rec.
oracle_for_each_repo() {
  local worker=$1 fleet label dir name
  NOCFG=()
  REPOS=()
  for fleet in "${FLEETS[@]}"; do
    label="$(oracle_fleet_label "${fleet}")"
    for dir in "${fleet}"/*/; do
      # An empty fleet leaves the pattern itself: nothing to record.
      [[ -d ${dir} ]] || continue
      dir="${dir%/}"
      name="${dir##*/}"
      if [[ -f ${dir}/donico.yml ]]; then
        REPOS+=("${label}"$'\t'"${name}"$'\t'"${dir}")
      else
        NOCFG+=("${label}"$'\t'"${name}")
        printf 'NOCFG\t-\t%s\t%s\t%s\n' "${label}" "${name}" 'no donico.yml' >"${RUN_DIR}/rec/${label}.${name}.tsv"
      fi
    done
  done

  local item
  for item in ${REPOS[@]+"${REPOS[@]}"}; do
    while [[ $(jobs -pr | wc -l) -ge ${ORACLE_PARALLEL} ]]; do
      sleep 0.2
    done
    (
      IFS=$'\t' read -r label name dir <<<"${item}"
      REC_LABEL=${label}
      REC_REPO=${name}
      REC_FILE="${RUN_DIR}/rec/${label}.${name}.tsv"
      : >"${REC_FILE}"
      "${worker}" "${label}" "${name}" "${dir}"
      # The last line of a worker that reached its end. A worker that died on
      # the way (unbound variable, kill) leaves a record without it, which
      # oracle_summary reports and fails on: its remaining pairs were never
      # compared.
      printf 'DONE\t-\t%s\t%s\t-\n' "${label}" "${name}" >>"${REC_FILE}"
      printf 'done %s/%s\n' "${label}" "${name}" >&2
    ) &
  done
  wait
}

# The fleet label: its path under PROJECTS without the common tail.
oracle_fleet_label() {
  local label=$1
  label="${label#*/PROJECTS/}"
  label="${label%/ci-config/docker-images}"
  printf '%s' "${label//\//_}"
}

# oracle_summary : the report, from the records. Sets nothing, prints
# `N compared, M different` last and returns 1 when M > 0.
oracle_summary() {
  local started=$1 rec_dir="${RUN_DIR}/rec"
  local all="${RUN_DIR}/all.tsv"
  cat "${rec_dir}"/*.tsv >"${all}" 2>/dev/null || : >"${all}"

  if compgen -G "${rec_dir}/*.hooks" >/dev/null; then
    printf '\nHook scripts and the commands they call\n'
    cat "${rec_dir}"/*.hooks | sort | awk -F'\t' '{ printf "  %s: %s\n", $2, ($3 == "" ? "(none)" : $3) }'
  fi

  printf '\nSkipped and failing repositories\n'
  awk -F'\t' '$1 == "NOCFG" { n[$3]++ } $1 == "GEMFAIL" { printf "  gem failure  %s/%s [%s]: %s\n", $3, $4, $2, $5 } $1 == "SKIP" { printf "  skipped      %s/%s [%s]: %s\n", $3, $4, $2, $5 }
    END { for (l in n) printf "  no donico.yml: %d in %s\n", n[l], l }' "${all}" | sort

  if compgen -G "${rec_dir}/*.diff" >/dev/null && [[ -n "$(cat "${rec_dir}"/*.diff)" ]]; then
    printf '\nDifferences\n'
    cat "${rec_dir}"/*.diff
  fi

  printf '\nStale committed files (not a bug of the binary)\n'
  awk -F'\t' '$1 == "STALE" { printf "  %s/%s: %s\n", $3, $4, $5 }' "${all}" | sort

  printf '\nPer fleet and pass (same / different / gem failure / skipped)\n'
  awk -F'\t' '$1 == "SAME" || $1 == "DIFF" || $1 == "GEMFAIL" || $1 == "SKIP" { key = $3 "\t" $2; n[key] = 1; c[key "\t" $1]++ }
    END { for (k in n) { split(k, p, "\t"); printf "  %-34s %-20s %5d / %d / %d / %d\n", p[1], p[2], c[k "\tSAME"], c[k "\tDIFF"], c[k "\tGEMFAIL"], c[k "\tSKIP"] } }' "${all}" | sort

  printf '\nPer pass, all fleets (same / different / gem failure / skipped)\n'
  awk -F'\t' '$1 == "SAME" || $1 == "DIFF" || $1 == "GEMFAIL" || $1 == "SKIP" { n[$2] = 1; c[$2 "\t" $1]++ }
    END { for (k in n) printf "  %-20s %5d / %d / %d / %d\n", k, c[k "\tSAME"], c[k "\tDIFF"], c[k "\tGEMFAIL"], c[k "\tSKIP"] }' "${all}" | sort

  printf '\nPer fleet (same / different / gem failure / skipped)\n'
  awk -F'\t' '$1 == "SAME" || $1 == "DIFF" || $1 == "GEMFAIL" || $1 == "SKIP" { n[$3] = 1; c[$3 "\t" $1]++ }
    END { for (k in n) printf "  %-34s %5d / %d / %d / %d\n", k, c[k "\tSAME"], c[k "\tDIFF"], c[k "\tGEMFAIL"], c[k "\tSKIP"] }' "${all}" | sort

  if compgen -G "${RUN_DIR}/work/*.corpus" >/dev/null; then
    printf '\nHosts named in the call logs (registry prefixes of image names, and URLs)\n'
    local hosts
    hosts="$(cat "${RUN_DIR}"/work/*.corpus | awk '
      /:\/\/[A-Za-z0-9.-]+/ && !/^type=bind/ && !/^docker:\/\// { match($0, /:\/\/[A-Za-z0-9.-]+/); print "url      " substr($0, RSTART + 3, RLENGTH - 3); next }
      /^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+(:[0-9]+)?\// { split($0, p, "/"); print "registry " p[1] }' | sort | uniq -c | sed 's/^/  /')"
    printf '%s\n' "${hosts:-  (none)}"
  fi

  # A repository whose worker never wrote its DONE line.
  local file unfinished=0
  for file in "${rec_dir}"/*.tsv; do
    [[ -f ${file} ]] || continue
    grep -qE '^(DONE|NOCFG)'$'\t' "${file}" && continue
    [[ ${unfinished} -eq 0 ]] && printf '\nUnfinished repositories (the worker died: nothing after its last record was compared)\n'
    printf '  %s\n' "$(basename "${file}" .tsv)"
    unfinished=$((unfinished + 1))
  done

  local compared different gemfail=0 line pattern allowed
  compared="$(awk -F'\t' '$1 == "SAME" || $1 == "DIFF" { n++ } END { print n + 0 }' "${all}")"
  different="$(awk -F'\t' '$1 == "DIFF" { n++ } END { print n + 0 }' "${all}")"
  while IFS= read -r line; do
    allowed=0
    for pattern in ${ORACLE_GEMFAIL_ALLOWED[@]+"${ORACLE_GEMFAIL_ALLOWED[@]}"}; do
      [[ ${line} =~ ${pattern} ]] && allowed=1
    done
    [[ ${allowed} -eq 0 ]] && gemfail=$((gemfail + 1))
  done < <(awk -F'\t' '$1 == "GEMFAIL" { printf "%s/%s\t%s\t%s\n", $3, $4, $2, $5 }' "${all}")
  printf '\nelapsed: %d s\n' "$((SECONDS - started))"
  printf '%d gem failure(s) not allowed (the pairs on which the gem itself misbehaved)\n' "${gemfail}"
  [[ ${unfinished} -eq 0 ]] || printf '%d unfinished repository(ies)\n' "${unfinished}"
  # Zero pairs is not a success: a wrong fleet directory, or one without any
  # donico.yml, compares nothing and used to end green.
  [[ ${compared} -gt 0 ]] || printf 'nothing was compared: check the fleet directories\n'
  printf '%d compared, %d different\n' "${compared}" "${different}"
  [[ ${compared} -gt 0 && ${different} -eq 0 && ${gemfail} -eq 0 && ${unfinished} -eq 0 ]]
}
