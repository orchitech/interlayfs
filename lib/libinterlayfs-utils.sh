# libinterlayfs-utils.sh
# Provide common utils for interlayfs.

ilfs_err()
{
  read line file <<<$(caller)
  echo "[$file:$line] ERROR $1" >&2
}

ilfs_fatal()
{
  local msg=$1
  [[ -n "$msg" ]] || msg="Internal software error."
  read line file <<<$(caller) # TODO: a stack trace would be better here
  echo "[$file:$line] ERROR $msg" >&2
  if [[ ${#FUNCNAME[@]} -gt 1 ]]; then
    local i
    echo "Call tree:" >&2
    for ((i=0;i<${#FUNCNAME[@]}-1;i++)); do
      echo " $i: ${BASH_SOURCE[$i+1]}:${BASH_LINENO[$i]} ${FUNCNAME[$i]}()"
    done
  fi
  exit 70 # sysexits.h
}

ilfs_deps_check()
{
  local -a errs=()
  local -i bash_major bash_minor
  local rest
  IFS=. read bash_major bash_minor rest <<<"${BASH_VERSION}"
  ((bash_major > 4 || bash_major == 4 && bash_minor >= 3)) || \
    errs+=("Incompatible bash version '$BASH_VERSION'. Required Bash 4.3 or higher.")
  [[ "$OSTYPE" = linux-gnu ]] || \
    errs+=("Incompatible OS '$OSTYPE'. Required linux-gnu.")
  command -v printenv &> /dev/null || errs+=("Missing printenv")
  getopt -T &> /dev/null; [[ $? -eq 4 ]] || \
    errs+=("Incompatible getopt version. Required enhanced getopt.")
  if [[ ${#errs[@]} -gt 0 ]]; then
    ilfs_err "Compatibility issues found:"$'\n'"$(printf -- '- %s\n' "${errs[@]}")"
    return 1
  fi
  return 0
}

# ilfs_envsubst
# Substitute environment variables in shell format strings
# TODO: envsubst-preprocessed configs will not probably behave as the user expects.
# TODO: reimplement read-based parsing in ilfs_paths_load_config using regexps with envsubst merged.
ilfs_envsubst()
{
  local rest=$(cat)
  local out=

  while [[ "$rest" =~ ^(([^\$\\]|\\.)*)\$(\{([a-zA-Z_][a-zA-Z0-9_]*)\})?(.*)$ ]]; do
    out+="${BASH_REMATCH[1]//\\\$/\$}"
    local var=${BASH_REMATCH[4]}
    rest=${BASH_REMATCH[5]}
    [[ -n "$var" ]] || {
      ilfs_err "Invalid usage of an unescpaed '\$' character in config file."
      return 2
    }
    out+=$(printenv "$var") || {
      ilfs_err "Undefined env variable '$var' referenced in config file."
      return 1
    }
  done
  printf '%s%s\n' "$out" "${rest//\\\$/\$}"
}

# dirname_v var name
# Provide an efficient dirname alternative.
# Implementation remarks:
# - way faster than OS dirname execution in a subprocess
# - compared to bash regexps: twice as fast and does not leak BASH_REMATCH
# - compared to extglob pattern suffix removing: 30 times as fast
# - not nice though (extglob pattern suffix removing would be a one-liner)
dirname_v()
{
  local -n __v=$1
  local __name=$2

  __v=$__name
  while [[ $__v == */ ]]; do
    __v=${__v%/}
  done
  if [[ $__v == */* ]]; then
    __v=${__v%/*}
    while [[ $__v == */ ]]; do
      __v=${__v%/}
    done
  else
    __v=''
  fi
  if [[ -n $__v ]]; then
    return 0
  elif [[ "${__name:0:1}" == '/' ]]; then
    __v='/'
  else
    __v='.'
  fi
}

# basename_v var name
# Provide an efficient basename alternative consistent with dirname_v.
basename_v()
{
  local -n __v=$1
  local __name=$2

  __v=$__name
  while [[ $__v == */ ]]; do
    __v=${__v%/}
  done
  __v=${__v##*/}
  if [[ -n $__v ]]; then
    return 0
  elif [[ $__name == */ ]]; then
    __v='/'
  fi
}

ilfs_ospath_type_v()
{
  local -n __v=$1
  local __ospath=$2

  if [[ -L "$__ospath" ]]; then
    __v=''
    ilfs_err "Encountered OS path '$ospath': symlinks not allowed."
    return 1
  elif [[ -d "$__ospath" ]]; then
    __v='d'
    return 0
  elif [[ -f "$__ospath" ]]; then
    __v='f'
    return 0
  elif [[ -e "$__ospath" ]]; then
    ilfs_err "Encountered OS path '$ospath': unsupported file type."
    return 1
  fi
  ilfs_err "Encountered OS path '$ospath': file not found."
  return 1
}

ilfs_globexpand_v()
{
  local -n __v=$1
  local __cwd=$2 __pattern=$3
  local __shopts_set='' __shopts_unset=''
  local IFS=' '

  cd "$__cwd" || return $?
  shopt -q dotglob || __shopts_set+=' dotglob'
  shopt -q nullglob || __shopts_set+=' nullglob'
  shopt -q extglob && __shopts_unset+=' extglob' || :
  [[ -z "$__shopts_set" ]] || shopt -s $__shopts_set
  [[ -z "$__shopts_unset" ]] || shopt -u $__shopts_unset
  IFS=''
  __v=($__pattern)
  IFS=' '
  [[ -z "$__shopts_set" ]] || shopt -u $__shopts_set
  [[ -z "$__shopts_unset" ]] || shopt -u $__shopts_unset
  cd "$OLDPWD"
}
