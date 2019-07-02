# libinterlayfs.sh
# Manage a bind mount-based tree combined from several FS trees in a configurable way.
# Provides an alternative to overlayfs on Linux using Linux kernel's shared subtrees.
#
# Copyright: Orchitech Solutions, s.r.o.
# License: GNU Lesser General Public License v3
# 
# control variables
# ILFS_DEBUG: print more debugging info if set

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
  local bash_major=${BASH_VERSION%%.*}
  [[ "$bash_major" -ge 4 ]] 2>/dev/null || errs+=("Incompatible bash version '$BASH_VERSION'. Required Bash 4 or higher.")
  [[ "$OSTYPE" = linux-gnu ]] || errs+=("Incompatible OS '$OSTYPE'. Required linux-gnu.")
  command -v printenv &> /dev/null || errs+=("Missing printenv")
  # TODO: test realpath
  getopt -T &> /dev/null; [[ $? -eq 4 ]] || errs+=("Incompatible getopt version. Required enhanced getopt.")
  if [[ -n "$errs" ]]; then
    ilfs_err "Compatibility issues found:"$'\n'"$(printf -- '- %s\n' "${errs[@]}")"
    return 1
  fi
  return 0
}

## GLOBAL AND COMMON OPTIONS

ilfs_init()
{
  local target=$1

  [[ -d "$target" ]] || {
    ilfs_err "Invalid mount target directory '$target'."
    return 1
  }

  declare -g _ilfs_op=
  declare -g _ilfs_target=$target
  declare -gA _ilfs_opts=()
  declare -gA _ilfs_trees_root=()
  declare -gA _ilfs_trees_opts=()
  declare -ga _paths=()
  declare -gA _paths_tree=()
  declare -gA _paths_opts=()
  declare -gA _paths_initcmd=()
}

ilfs_add_opts()
{
  ilfs_parse_opts "$@" _ilfs_opts
}

ilfs_ospath_type()
{
  local ospath=$1
  local ls type
  ls=$(ls -ld "$ospath" 2>/dev/null) && [[ -n "$ls" ]] || return 1
  type=${ls:0:1}
  if [[ "$type" != [df] ]]; then
    ilfs_err "Encountered OS path '$ospath': type '$type' not allowed."
    return 1
  fi
  echo "$type"
}

readonly -A _ILFS_OPTS_DEF=(
  [ro]=1
  [rw]=\!ro
  [init]=_
  [type]=_
)
readonly -A _ILFS_OPTS_DEFAULTS=(
  [ro]=0
  [init]=never
  [type]=e
)
readonly -A _ILFS_OPTS_VALUE_REX=(
  [ro]=
  [rw]=
  [init]='^(never|skip|missing|always)$'
  [type]='^[edf]$'
)
ilfs_parse_opts()
{
  local optstr=$1
  local -n __optarr=$2
  local index_prefix=$3
  local strict=1 # make this caller-defined if needed

  local -a opts
  IFS=, read -a opts <<< "$optstr"
  local o name value
  for o in "${opts[@]}"; do
    IFS='=' read name value <<< "$o"
    local def=${_ILFS_OPTS_DEF[$name]}
    if [[ -z "$def" && -n "$strict" ]]; then
      ilfs_err "Unknown option '$name'."
      return 1
    fi
    if ! [[ "$value" =~ ${_ILFS_OPTS_VALUE_REX[$name]} ]]; then
      ilfs_err "Invalid option value '$name=$value'."
      return 1
    fi

    if [[ "$def" = \!* ]]; then
      name=${def#\!}
      def=${_ILFS_OPTS_DEF[$name]}
      value=$(( ! def))
    elif [[ "$def" != _ ]]; then
      value=$def
    fi

    __optarr["${index_prefix}${name}"]=$value
  done
}

# FIXME: envsubst-preprocessed configs will not probably behave as the user expects.
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

## MOUNTING

ilfs_mount()
{
  trap '_ilfs_op=""' RETURN
  _ilfs_op=mount
  ilfs_paths_init
  ilfs_create_mountpoints
  local path tree root rw
  for path in "${_paths[@]}"; do
    #ilfs_paths_comp_opt "$path" ro

    rw=ro
    (( "$(ilfs_paths_comp_opt "$path" ro)" )) || rw=rw
    tree=$(ilfs_paths_tree "$path") || ilfs_fatal
    root=$(ilfs_trees_root "$tree") || ilfs_fatal
    mount --bind --make-private -o "$rw" "${root}${path}" "${_ilfs_target}${path}" || return 1
  done
}

ilfs_umount()
{
  umount -l "${_ilfs_target}"
}

ilfs_create_mountpoints()
{
  ilfs_paths_defined / || {
    ilfs_err "Configuration without root not yet supported."
    return 1
  }
  local path
  for path in "${_paths[@]}"; do
    ilfs_paths_create_mountpoint "$path" || {
      ilfs_err "Failed to create mountpoint for '$path'. Aborting."
      return 1
    }
  done
}

ilfs_paths_do_create_mountpoint()
{
  local parent_root=$1 parent_path=$2 path=$3 path_type=$4
  local subpath

  # Sanity assertions
  ! [[ -e "${parent_root}${path}" ]] || ilfs_fatal
  [[ -d "${parent_root}" ]] || ilfs_fatal
  [[ -d "${parent_root}${parent_path}" ]] || ilfs_fatal

  # TODO: unit-test this
  if [[ "$parent_path" = / ]]; then
    subpath=${path#/}
  else
    subpath=${path#$parent_path/}
  fi
  if [[ "$subpath" = "$path" || "$subpath" = /* ]]; then
    ilfs_err "Cannot calculate relative mountpoint path for path '$path' with parent '$parent_path'."
    return 1
  fi

  local leaf=$subpath
  local dir=$(dirname "$subpath")
  local -a dirs=()
  while [[ "$dir" != . ]]; do
    dirs=("$dir" "${dirs[@]}")
    dir=$(dirname "$dir")
  done
  if [[ "$path_type" = d ]]; then
    dirs+=("$leaf")
    leaf=
  fi
  # Behold, modifying the filesystem here
  (
    set -e
    umask 022
    cd "${parent_root}${parent_path}"
    for dir in "${dirs[@]}"; do
      [[ -d "$dir" ]] && continue
      if [[ -e "$dir" ]]; then
        ilfs_err "Colliding file on mountpoint path: '$(realpath "$dir")'."
        exit 1
      fi
      mkdir "$dir"
      touch "$dir/.ilfs-mountpoint"
    done
    if [[ -n "$leaf" ]]; then
      echo '#ilfs-mountpoint' > "$leaf"
    fi
  ) || return 1

  return 0
}

ilfs_paths_create_mountpoint()
{
  local path=$1
  local tree root parent_path parent_tree= parent_root

  tree=$(ilfs_paths_tree "$path") || ilfs_fatal
  root=$(ilfs_trees_root "$tree") || ilfs_fatal
  if parent_path=$(ilfs_paths_parent "$path"); then
    parent_tree=$(ilfs_paths_tree "$parent_path") || ilfs_fatal
    parent_root=$(ilfs_trees_root "$parent_tree") || ilfs_fatal
  else
    parent_path=/
    parent_root=$_ilfs_target
    [[ -d "$parent_root" ]] || {
      ilfs_err "Invalid target root dir '$parent_root'."
      return 1
    }
  fi

  local path_type parent_tree_path_type
  path_type=$(ilfs_ospath_type "${root}${path}") || {
    ilfs_err "OS path '${root}${path}' not ready for mounting."
    return 1
  }

  if ! [[ -e "${parent_root}${path}" ]]; then
    ilfs_paths_do_create_mountpoint "$parent_root" "$parent_path" "$path" "$path_type" || {
      ilfs_err "Failed to create mountpoint on '${parent_root}${path}'."
      return 1
    }
  fi

  parent_tree_path_type=$(ilfs_ospath_type "${parent_root}${path}") || {
    # should not occur if ilfs_paths_do_create_mountpoint fails correctly
    ilfs_err "Missing mountpoint on '${parent_root}${path}'."
    return 1
  }
  if [[ "$parent_tree_path_type" != "$path_type" ]]; then
    local err="OS path ${root}${path}', type '$path_type' does not match"
    err+=" the type of its mountpoint '${parent_root}${path}', type '$parent_tree_path_type'."
    ilfs_err "$err"
    return 1
  fi
  return 0
}

## TREE HANDLING

ilfs_trees_add()
{
  local tree=$1 root=$2 opts=$3

  [[ -n "$tree" ]] || {
    ilfs_err "Invalid tree name '$tree'."
    return 1
  }
  ilfs_trees_defined "$tree" && {
    ilfs_err "Duplicate tree name '$tree'."
    return 1
  }
  root=$(realpath "$root") && [[ -d "$root" ]] || {
    ilfs_err "Invalid root directory '$root' of tree '$tree'."
    return 1
  }
  _ilfs_trees_root+=([$tree]=$root)
  ilfs_parse_opts "$opts" _ilfs_trees_opts "$tree//"
}

ilfs_trees_defined()
{
  local tree=$1
  [[ ${_ilfs_trees_root[$tree]+_} ]]
}

ilfs_trees_root()
{
  local tree=$1
  local root=${_ilfs_trees_root[$tree]}
  [[ -n "$root" ]] || ilfs_fatal "undefined tree '$tree'."
  echo "$root"
}

ilfs_trees_opts()
{
  local tree=$1
  echo "${_ilfs_trees_root[$tree]}"
}

ilfs_trees_load_config()
{
  local tree root optstr
  while read tree root optstr; do
    [[ -n "$tree" && "$tree" != \#* ]] || continue
    local line="$tree $root $optstr"
    if [[ "$tree" == _error_ && -z "$root" && -z "$optstr" ]]; then
      return 1
    fi
    if [[ -z "$root" || "$root" == \#* ]]; then
      ilfs_err "Invalid number of fields in tree config line '$line'."
      return 1
    fi
    if [[ "$optstr" == \#* ]]; then
      optstr=
    fi
    ilfs_trees_add "$tree" "$root" "$optstr" || return 1
  done < <(ilfs_envsubst || echo _error_)
  return 0
}


## PATH HANDLING

readonly _ILFS_REGF_REX='[^./]|[^./]\.|\.[^./]|[^/]{3,}'
readonly _ILFS_SUBPATH_REX="^(/($_ILFS_REGF_REX))+/?$"
ilfs_paths_validate()
{
  local path=$1
  [[ "$path" = / || "$path" =~ $_ILFS_SUBPATH_REX ]]
}

# See unquoted_glob_pattern_p() in pathexp.c:
# http://git.savannah.gnu.org/cgit/bash.git/tree/pathexp.c?h=bash-4.4#n61
ilfs_paths_contains_glob()
{
  local spec=$1
  [[ "$spec" =~ (^|/)([^/\\]|\\[^/])*([*?]|[+@!]\() ]] && return 0
  [[ "$spec" =~ (^|/)([^/\\]|\\[^/])*\[([^/\\]|\\[^/])*\] ]] && return 0
  return 1
}

ilfs_paths_defined()
{
  local path=$1
  [ ${_paths_tree[$path]+_} ]
}

ilfs_paths_tree()
{
  local path=$1
  ilfs_paths_defined "$path" || {
    ilfs_err "Invalid path '$path' encountered."
    return 1
  }
  echo "${_paths_tree[$path]}"
}

ilfs_paths_initcmd()
{
  local path=$1
  ilfs_paths_defined "$path" || {
    ilfs_err "Invalid path '$path' encountered."
    return 1
  }
  echo "${_paths_initcmd[$path]}"
}

# ilfs_paths_comp_opt [ -t TREE ] { PATH | ARRAY_REF } OPTION
ilfs_paths_comp_opt()
{
  local tree=; [[ "$1" = -t ]] && { tree=$2; shift 2; }
  local path_or_arrname=$1
  local opt=$2
  local -n __popts

  if [[ "$path_or_arrname" = /* ]]; then
    ilfs_paths_defined "$path_or_arrname" || {
      ilfs_err "Invalid path '$path_or_arrname'."
      return 1
    }
    __popts=_paths_opts
    popt_prefix=$path_or_arrname//
    if [[ -z "$tree" ]]; then
      tree=$(ilfs_paths_tree "$path_or_arrname") || return 1
    fi
  else
    __popts=$path_or_arrname
    popt_prefix=
    [[ -n "$tree" ]] || {
      ilfs_err "Tree required."
      return 1
    }
  fi
  ilfs_trees_defined "$tree" || {
    ilfs_err "Invalid tree '$tree'."
    return 1
  }

  local overrides
  case "$opt" in
    ro) overrides='_ILFS_OPTS_DEFAULTS __popts       _ilfs_trees_opts _ilfs_opts' ;;
    *)  overrides='_ILFS_OPTS_DEFAULTS _ilfs_opts  _ilfs_trees_opts __popts' ;;
  esac
  local arrname prefix= value=
  for arrname in $overrides; do
    local -n __optarr=$arrname
    case "$arrname" in
      __popts) prefix=$popt_prefix ;;
      _ilfs_trees_opts) prefix=$tree// ;;
      *) prefix= ;;
    esac
    if [[ ${__optarr["$prefix$opt"]+_} ]]; then
      value=${__optarr["$prefix$opt"]}
    fi
  done
  echo "$value"
}

ilfs_paths_has_subpaths()
{
  local path=$1 p
  path=${path%/}
  for p in "${_paths[@]}"; do
    [[ ${p%/}/ == "$path"/* ]] && return 0
  done
  return 1
}

ilfs_paths_parent()
{
  local path=$1
  local parent=$(dirname "$path")
  while [[ "$parent" != [/.] ]] && ! ilfs_paths_defined "$parent"; do
    parent=$(dirname "$parent")
  done

  ilfs_paths_defined "$parent" && echo "$parent"
}

# Load and parse config from stdin. Tree definitions are expected to be present.
ilfs_paths_load_config()
{
  local tree pathspec optstr initcmd
  while read tree pathspec optstr initcmd; do
    [[ -n "$tree" && "$tree" != \#* ]] || continue
    local line="$tree $pathspec $optstr $initcmd"
    [[ -n "$pathspec" && "$pathspec" != \#* ]] || {
      ilfs_err "Invalid number of fields in config line '$line'."
      return 1
    }
    if [[ "$optstr" == \#* ]]; then
      optstr=
      initcmd=
    fi
    if [[ "$initcmd" == \#* ]]; then
      initcmd=
    fi

    ilfs_trees_defined "$tree" || {
      ilfs_err "Unknown tree '$tree' in config line '$line'."
      return 1
    }

    # Process options
    local -A optarr=()
    ilfs_parse_opts "$optstr" optarr
    # Explicit initializing not allowed for globs
    if ilfs_paths_contains_glob "$pathspec"; then
      case "${optarr[init]}" in
        '')
          optarr[init]=skip
          ;;
        skip|never)
          ;;
        *)
          ilfs_err "'init' must be 'skip' or 'never' when explicitly set for a glob-pattern path spec in config line '$line'."
          return 1
          ;;
      esac
    fi

    # Paths ending with slash must be directories and eventual direct path type setting must not contradict it
    if [[ "$pathspec" == */ ]]; then
      [[ "${optarr[type]-e}" = [ed] ]] || {
        ilfs_err "Path '$path' ends with slash, but type='${optarr[type]}' is required in config line '$line'."
        return 1
      }
      [[ "$pathspec" == / ]] || pathspec=${pathspec%/}
      optarr[type]=d
    fi
    # Normalize path spec. Should validate like a normal path.
    [[ "$pathspec" == / ]] || pathspec="/${pathspec#/}"
    ilfs_paths_validate "$pathspec" || {
      ilfs_err "Invalid path spec '$pathspec' in config line '$line'."
      return 1
    }

    # Perform glob-expansion
    local tree_root=$(ilfs_trees_root "$tree")
    local -a paths=()
    if [ "$pathspec" = / ]; then
      paths=( / )
    else
      local matching
      if matching=$(cd "$tree_root" && shopt -s dotglob && compgen -G "${pathspec#/}"); then
        readarray -t paths <<< "$matching"
        paths=( "${paths[@]/#//}" )
      else
        local init
        init=$(ilfs_paths_comp_opt -t "$tree" optarr init) || return 1
        case "$init" in
          missing|always)
            paths[0]="/${pathspec#/}"
            ;;
          skip)
            ;;
          never|*)
            ilfs_err "Path spec '$pathspec' did not match anything in config line '$line' and is not about to be initialized."
            return 1
            ;;
        esac
      fi
    fi

    # Final path config processing
    local path type
    for path in "${paths[@]}"; do
      ilfs_paths_validate "$path" || {
        ilfs_err "Invalid path '$path' in config line '$line'."
        return 1
      }
      # Do not allow shadowing of previously defined paths
      ilfs_paths_has_subpaths "$path" && {
        ilfs_err "Path '$path' conflicts with a previously defined path in config line '$line'."
        return 1
      }
      # Existing paths must match the required type
      type=$(ilfs_paths_comp_opt -t "$tree" optarr type) || return 1
      if [[ -e "${tree_root}${path}" ]] && ! [ -"$type" "${tree_root}${path}" ]; then
        ilfs_err "Path '$path' does not match its required type '$type' in config line '$line'."
        return 1
      fi
      # Finally, push the processed path
      _paths+=("$path")
      _paths_tree+=([$path]=$tree)
      _paths_initcmd+=([$path]=$initcmd)
      local o
      for o in "${!optarr[@]}"; do
        _paths_opts+=(["$path//$o"]=${optarr[$o]})
      done
    done
  done
}

## PATH INITIALIZATION

ilfs_paths_test()
{
  local test=$1
  local path=$2
  local tree rootdir
  tree=$(ilfs_paths_tree "$path") || ilfs_fatal
  rootdir=$(ilfs_trees_root "$tree")
  # double bracket alternative won't work this way
  [ "$test" "${rootdir}${path}" ]
}

ilfs_paths_init()
{
  local path
  for path in "${_paths[@]}"; do
    ilfs_paths_init_path "$path" || {
      ilfs_err "Failed to initialize path '$path'. Aborting."
      return 1
    }
  done
}

ilfs_paths_init_path()
{
  local path=$1
  local init type

  init=$(ilfs_paths_comp_opt "$path" init) || return 1
  if [[ "$init" = always ]] || ! ilfs_paths_test -e "$path"; then
    case "$init" in
      never|skip)
        # Currently already handled in ilfs_paths_load_config, but the behavior
        # might change with introducing explicit initializing options.
        ilfs_err "Path '$path' is expected to exist (init=$init)."
        return 1
        ;;
    esac
    ilfs_paths_do_path_init "$path" || return 1
    type=$(ilfs_paths_comp_opt "$path" type) || return 1
    if ! ilfs_paths_test -"$type" "$path"; then
      ilfs_err "Initializing path '$path' has not resulted in a valid path of type '$type'."
      return 1
    fi
  fi
  return 0
}

# API:
# CWD in tree root
# relative path as $1
# ILFS_PATH - canonic
# ILFS_OP=init|mount
# ILFS_TREE
# ILFS_TREE_ROOT
# ILFS_EXISTING_RELPATH
# ILFS_INIT_SUBPATH
# ILFS_PATH_OPTS_RO
# ILFS_PATH_OPTS_INIT
# ILFS_PATH_OPTS_TYPE=d/f/e
#
# ILFS_INIT_ERR_SKIP=??
# ILFS_INIT_ERR_FAIL=1
# ILFS_INIT_ERR_FAIL=1
ilfs_paths_do_path_init()
{
  local path=$1
  local initcmd
  initcmd=$(ilfs_paths_initcmd "$path") || return 1
  [[ "$initcmd" =~ [^[:space:]] ]] || {
    # Blank initcmd is treated as a special condition just to be user-friendly.
    # It still can do just nothing even if non-blank.
    ilfs_err "Path '$path' should be initialized with blank initcmd."
    return 1
  }
  # global variables
  local ILFS_OP=${_ilfs_op:-init}

  # tree-related variables
  local ILFS_TREE ILFS_TREE_ROOT
  ILFS_TREE=$(ilfs_paths_tree "$path") || return 1
  ILFS_TREE_ROOT=$(ilfs_trees_root "$ILFS_TREE") || return 1

  # absolute/canonic paths
  local ILFS_PATH=$path
  local ILFS_PATH_OPTS_RO=${_paths_opts[$path//ro]-}
  local ILFS_PATH_OPTS_INIT=${_paths_opts[$path//init]-}
  local ILFS_PATH_OPTS_TYPE=${_paths_opts[$path//type]-e}

  # relative paths
  local ILFS_RELPATH ILFS_EXISTING_RELPATH ILFS_INIT_SUBPATH
  ILFS_RELPATH=${path#/}
  if [[ -n "$ILFS_RELPATH" ]]; then
    ILFS_EXISTING_RELPATH=$(dirname "$ILFS_RELPATH")
    ILFS_INIT_SUBPATH=$(basename "$ILFS_RELPATH")
    while [[ "$ILFS_EXISTING_RELPATH" != . && ! -d "$ILFS_TREE_ROOT/$ILFS_EXISTING_RELPATH" ]]; do
      ILFS_INIT_SUBPATH="$(basename "$ILFS_EXISTING_RELPATH")/$ILFS_INIT_SUBPATH"
      ILFS_EXISTING_RELPATH=$(dirname "$ILFS_EXISTING_RELPATH")
    done
  else
    # initializing root
    ILFS_RELPATH=.
    ILFS_EXISTING_RELPATH=.
    ILFS_INIT_SUBPATH=.
  fi

  (
    set -e
    umask 022
    cd "$ILFS_TREE_ROOT"
    export ILFS_OP
    export ILFS_TREE ILFS_TREE_ROOT
    export ILFS_PATH
    export ILFS_PATH_OPTS_RO ILFS_PATH_OPTS_INIT ILFS_PATH_OPTS_TYPE
    export ILFS_RELPATH ILFS_EXISTING_RELPATH ILFS_INIT_SUBPATH

    export -f il_mkdir
    export -f il_template_envsubst
    export -f ilfs_envsubst
    export -f il_copy
    export -f il_ownership
    export -f il_apply_to_subpaths
    export -f ilfs_err # TODO

    echo "Initializing '$path' using '$initcmd'." >&2
    exec bash -e -c "$initcmd" init "$ILFS_RELPATH"
  ) # passing exit code as return code
}

il_mkdir()
{
  cd "$ILFS_EXISTING_RELPATH"
  mkdir -p "$ILFS_INIT_SUBPATH"
  il_ownership
}

il_template_envsubst()
{
  local tpl=$1
  local content parentdir
  cd "$ILFS_EXISTING_RELPATH"
  content=$(ilfs_envsubst < "$1") || return 1
  parentdir=$(dirname "$ILFS_INIT_SUBPATH")
  [[ "$parentdir" == . ]] || mkdir -p "$parentdir"
  touch "$ILFS_INIT_SUBPATH" # fail early
  printf '%s\n' "$content" > "$ILFS_INIT_SUBPATH"
  il_ownership
}

il_copy()
{
  local src
  src=$(realpath "$1") || return 1
  if ! [[ -e "$src" ]]; then
    echo "Invalid copy source '$src'." >&2
    return 1
  fi
  if [[ -e "$ILFS_RELPATH" ]]; then
    echo "Copy on an existing path not supported." >&2
    return 1
  fi
  (
    set -e
    cd "$ILFS_EXISTING_RELPATH"
    local parentdir=$(dirname "$ILFS_INIT_SUBPATH")
    [[ "$parentdir" == . ]] || mkdir -p "$parentdir"
    il_ownership "$parentdir"
  )
  cp -rp "$src" "$ILFS_RELPATH"
  if [[ -n "$ILFS_INIT_CHOWN" ]]; then
    chown -R -- "$ILFS_INIT_CHOWN" "$ILFS_RELPATH"
  fi
  if [[ -n "$ILFS_INIT_CHGRP" ]]; then
    chgrp -R -- "$ILFS_INIT_CHGRP" "$ILFS_RELPATH"
  fi
}

il_ownership()
{
  local subpath=${1-$ILFS_INIT_SUBPATH}
  if [[ -n "$ILFS_INIT_CHOWN" ]]; then
    il_apply_to_subpaths "$subpath" chown -- "$ILFS_INIT_CHOWN"
  fi
  if [[ -n "$ILFS_INIT_CHGRP" ]]; then
    il_apply_to_subpaths "$subpath" chgrp -- "$ILFS_INIT_CHGRP"
  fi
}

il_apply_to_subpaths()
{
  local path=$1; shift
  [[ "$path" != /* ]] || { echo "Refusing to work on absolute path '$p'."; return 1; }
  local -a subpaths=("$path")
  path=$(dirname "$path")
  while [[ "$path" != . ]]; do
    subpaths=("$path" "${subpaths[@]}")
    path=$(dirname "$path")
  done
  "$@" "${subpaths[@]}"
}
