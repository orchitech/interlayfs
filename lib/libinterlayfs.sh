# libinterlayfs.sh
# Manage a bind mount-based tree combined from several FS trees in a configurable way.
# Provides an alternative to overlayfs on Linux using Linux kernel's shared subtrees.
#
# Copyright: Orchitech Solutions, s.r.o.
# License: GNU Lesser General Public License v3
# 
# control variables
# ILFS_DEBUG: print more debugging info if set

[[ -n "${ILFS_ROOT-}" ]] || \
  ILFS_ROOT=$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")
source "$ILFS_ROOT/lib/libinterlayfs-utils.sh"

## GLOBAL AND COMMON OPTIONS

ilfs_init()
{
  local target=$1

  [[ -d "$target" ]] || {
    ilfs_err "Invalid mount target directory '$target'."
    return 1
  }

  declare -g _ilfs_op=''
  declare -g _ilfs_target=$target
  declare -gA _ilfs_opts=()
  declare -gA _ilfs_trees_root=()
  declare -gA _ilfs_trees_opts=()
  declare -ga _ilfs_paths=()
  declare -gA _ilfs_paths_tree=()
  declare -gA _ilfs_paths_opts=()
  declare -gA _ilfs_paths_initcmd=()
}

ilfs_add_opts()
{
  ilfs_parse_opts "$@" _ilfs_opts
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
  [ro]=''
  [rw]=''
  [init]='^(never|skip|missing|always)$'
  [type]='^[edf]$'
)
ilfs_parse_opts()
{
  local optstr=$1
  local -n __optarr=$2
  local index_prefix=${3-}
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

## MOUNTING

ilfs_mount()
{
  trap '_ilfs_op=""' RETURN
  _ilfs_op=mount
  ilfs_paths_init
  ilfs_create_mountpoints
  local path tree root rw
  local -i opt_ro
  for path in "${_ilfs_paths[@]}"; do
    ilfs_paths_comp_opt_v opt_ro "$path" ro
    (( opt_ro )) && rw=ro || rw=rw
    tree=${_ilfs_paths_tree[$path]}
    root=${_ilfs_trees_root[$tree]}
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
  for path in "${_ilfs_paths[@]}"; do
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
  if [[ "$parent_path" = '/' ]]; then
    subpath=${path#/}
  else
    subpath=${path#$parent_path/}
  fi
  if [[ "$subpath" == "$path" || "$subpath" = /* ]]; then
    ilfs_err "Cannot calculate relative mountpoint path for path '$path' with parent '$parent_path'."
    return 1
  fi

  local dir leaf=$subpath
  dirname_v dir "$subpath"
  local -a dirs=()
  while [[ "$dir" != . ]]; do
    dirs=("$dir" "${dirs[@]}")
    dirname_v dir "$dir"
  done
  if [[ "$path_type" = d ]]; then
    dirs+=("$leaf")
    leaf=''
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
  local tree root parent_path parent_tree='' parent_root

  tree=${_ilfs_paths_tree[$path]}
  root=${_ilfs_trees_root[$tree]}
  if ilfs_paths_parent_v parent_path "$path"; then
    parent_tree=${_ilfs_paths_tree[$parent_path]}
    parent_root=${_ilfs_trees_root[$parent_tree]}
  else
    parent_path=/
    parent_root=$_ilfs_target
    [[ -d "$parent_root" ]] || {
      ilfs_err "Invalid target root dir '$parent_root'."
      return 1
    }
  fi

  local path_type parent_tree_path_type
  ilfs_ospath_type_v path_type "${root}${path}" || {
    ilfs_err "OS path '${root}${path}' not ready for mounting."
    return 1
  }

  if ! [[ -e "${parent_root}${path}" ]]; then
    ilfs_paths_do_create_mountpoint "$parent_root" "$parent_path" "$path" "$path_type" || {
      ilfs_err "Failed to create mountpoint on '${parent_root}${path}'."
      return 1
    }
  fi

  ilfs_ospath_type_v parent_tree_path_type "${parent_root}${path}" || {
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
  local tree=$1 root=$2 opts=${3-}

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
      optstr=''
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
  [ ${_ilfs_paths_tree[$path]+_} ]
}

# ilfs_paths_comp_opt_v var [ -t TREE ] { PATH | ARRAY_REF } OPTION
ilfs_paths_comp_opt_v()
{
  local -n _ilfs_paths_comp_opt_var=$1; shift
  local _ilfs_paths_comp_opt_out
  _ilfs_paths_comp_opt_v "$@" || return $?
  _ilfs_paths_comp_opt_var=$_ilfs_paths_comp_opt_out
}

_ilfs_paths_comp_opt_v()
{
  local tree=''; [[ "$1" = -t ]] && { tree=$2; shift 2; }
  local path_or_arrname=$1
  local opt=$2
  local -n __popts
  local popt_prefix

  if [[ "$path_or_arrname" = /* ]]; then
    ilfs_paths_defined "$path_or_arrname" || {
      ilfs_err "Invalid path '$path_or_arrname'."
      return 1
    }
    __popts=_ilfs_paths_opts
    popt_prefix=${path_or_arrname}//
    if [[ -z "$tree" ]]; then
      tree=${_ilfs_paths_tree[$path_or_arrname]}
    fi
  else
    __popts=${path_or_arrname}
    popt_prefix=''
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
    ro) overrides='_ILFS_OPTS_DEFAULTS __popts     _ilfs_trees_opts _ilfs_opts' ;;
    *)  overrides='_ILFS_OPTS_DEFAULTS _ilfs_opts  _ilfs_trees_opts __popts' ;;
  esac
  local arrname prefix='' value=''
  for arrname in $overrides; do
    local -n __optarr=$arrname
    case "$arrname" in
      __popts) prefix=$popt_prefix ;;
      _ilfs_trees_opts) prefix=$tree// ;;
      *) prefix='' ;;
    esac
    if [[ ${__optarr["$prefix$opt"]+_} ]]; then
      value=${__optarr["$prefix$opt"]}
    fi
  done
  _ilfs_paths_comp_opt_out=$value
}

ilfs_paths_has_subpaths()
{
  local path=$1 p
  path=${path%/}
  for p in "${_ilfs_paths[@]}"; do
    [[ ${p%/}/ == "$path"/* ]] && return 0
  done
  return 1
}

ilfs_paths_parent_v()
{
  local -n _pp_var=$1
  local _pp_path=$2 _pp_parent
  dirname_v _pp_parent "$_pp_path"
  while [[ "$_pp_parent" != [/.] ]] && ! ilfs_paths_defined "$_pp_parent"; do
    dirname_v _pp_parent "$_pp_parent"
  done
  _pp_var=''
  ilfs_paths_defined "$_pp_parent" && _pp_var=$_pp_parent
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
      optstr=''
      initcmd=''
    fi
    if [[ "$initcmd" == \#* ]]; then
      initcmd=''
    fi

    ilfs_trees_defined "$tree" || {
      ilfs_err "Unknown tree '$tree' in config line '$line'."
      return 1
    }

    # Process options
    local -A optarr=()
    ilfs_parse_opts "$optstr" optarr

    local isglob=''
    # Explicit initializing not allowed for globs
    if ilfs_paths_contains_glob "$pathspec"; then
      isglob=1
      case "${optarr[init]-}" in
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

    # Treat trailing slash as type=d and fail on conflicting path type setting
    if [[ "$pathspec" == */ ]]; then
      [[ "${optarr[type]-e}" == [ed] ]] || {
        ilfs_err "Path '$path' ends with slash, but type='${optarr[type]}' is required in config line '$line'."
        return 1
      }
      [[ "$pathspec" == '/' ]] || pathspec=${pathspec%/}
      optarr[type]=d
    fi
    # Normalize path spec. Globs should validate like a normal path.
    [[ "$pathspec" == '/' ]] || pathspec="/${pathspec#/}"
    ilfs_paths_validate "$pathspec" || {
      ilfs_err "Invalid path spec '$pathspec' in config line '$line'."
      return 1
    }

    # Evaluate matching paths and validate initialization
    local tree_root=${_ilfs_trees_root[$tree]}
    local -a paths=()
    if [[ -n "$isglob" ]]; then
      ilfs_globexpand_v paths "$tree_root" "${pathspec#/}"
      # TODO: filter matched paths by required type
      paths=("${paths[@]/#//}")
    else
      paths=("$pathspec")
      if ! [[ -e "${tree_root}${pathspec}" ]]; then
        local init
        ilfs_paths_comp_opt_v init -t "$tree" optarr init || return 1
        case "$init" in
          missing|always|skip)
            ;;
          *)
            ilfs_err "Path spec '$pathspec' did not match anything in config line '$line' and is not about to be initialized."
            return 1
            ;;
        esac
      fi
    fi

    # Final path config processing
    local path type
    for path in "${paths[@]}"; do
      # Revalidate after glob expansion
      [[ "$path" == '/' || "$path" != */ ]] && ilfs_paths_validate "$path" || {
        ilfs_err "Invalid path '$path' in config line '$line'."
        return 1
      }
      # Do not allow shadowing of previously defined paths
      ilfs_paths_has_subpaths "$path" && {
        ilfs_err "Path '$path' conflicts with a previously defined path in config line '$line'."
        return 1
      }
      # Existing paths must match the required type
      ilfs_paths_comp_opt_v type -t "$tree" optarr type || return 1
      if [[ -e "${tree_root}${path}" ]] && ! [ -"$type" "${tree_root}${path}" ]; then
        ilfs_err "Path '$path' does not match its required type '$type' in config line '$line'."
        return 1
      fi
      # Finally, push the processed path
      _ilfs_paths+=("$path")
      _ilfs_paths_tree+=([$path]=$tree)
      _ilfs_paths_initcmd+=([$path]=$initcmd)
      local o
      for o in "${!optarr[@]}"; do
        _ilfs_paths_opts+=(["$path//$o"]=${optarr[$o]})
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
  tree=${_ilfs_paths_tree[$path]}
  rootdir=${_ilfs_trees_root[$tree]}
  # double bracket alternative won't work this way
  [ "$test" "${rootdir}${path}" ]
}

ilfs_paths_init()
{
  local path
  for path in "${_ilfs_paths[@]}"; do
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

  ilfs_paths_comp_opt_v init "$path" init || return 1
  if [[ "$init" = always ]] || ! ilfs_paths_test -e "$path"; then
    case "$init" in
      never|skip)
        # Handled in ilfs_paths_load_config, but the behavior might change
        # with introducing explicit initializing options => (re)validate here.
        ilfs_err "Path '$path' is expected to exist (init=$init)."
        return 1
        ;;
    esac
    ilfs_paths_do_path_init "$path" || return 1
    ilfs_paths_comp_opt_v type "$path" type || return 1
    if ! ilfs_paths_test -"$type" "$path"; then
      ilfs_err "Initializing path '$path' has not resulted in a valid path of type '$type'."
      return 1
    fi
  fi
  return 0
}

# ilfs_paths_do_path_init path
# Initialize path by calling configured initcmd.
# Interpreting initcmd:
# - initcmd is evaluated using bash -c
# - it can call external program(s) or use pure bash
# - user can refer to their pre-defined functions in environment (export -f)
# - interlayfs itself provides some utility functions, see `Exported functions` below
# - interlayfs provides predefined initialization functions, see `Exported functions` below
# Invocation of initcmd
# - initcmd is started as a script with $1 set to relative path (i.e. without leading '/')
# - CWD is set to the root of the tree where the path is going to be initialized
# - Provided environment variables:
#    - ILFS_OP: init|mount
#    - ILFS_TREE: tree name
#    - ILFS_TREE_ROOT: root directory of the tree, same as initial CWD
#    - ILFS_PATH: canonic path (i.e. with leading '/')
#    - ILFS_PATH_OPTS_RO: path-level option 'ro'
#    - ILFS_PATH_OPTS_TYPE: path-level option 'type'
#    - ILFS_PATH_OPTS_INIT: path-level option 'init'
#    - ILFS_RELPATH: relative path to the initialized path, same as $1
#    - ILFS_EXISTING_RELPATH: leading portion of ILFS_RELPATH that exists and is not necessarily subject to initialization
#    - ILFS_INIT_SUBPATH: trailing portion of ILFS_RELPATH that does not exist or is subject to initialization
# Interpreting initcmd result:
# - Exit code currently distinguishes only success (zero) and failure (non-zero) codes.
# - Special codes might be introduced if there is a use case for them, e.g. ILFS_INIT_ERR_SKIP might be treated as an instruction to programatically skip the path.
# - Subsequent validation checks if the initialized path exists and matches respective type restriction.
ilfs_paths_do_path_init()
{
  local path=$1
  local initcmd
  initcmd=${_ilfs_paths_initcmd[$path]}
  [[ "$initcmd" =~ [^[:space:]] ]] || {
    # Blank initcmd is treated as a special condition just to be user-friendly.
    # Even non-blank initcmd can do just nothing, which is actually a correct
    # behavior for init=always.
    ilfs_err "Path '$path' should be initialized with blank initcmd."
    return 1
  }
  # global variables
  local ILFS_OP=${_ilfs_op:-init}

  # tree-related variables
  local ILFS_TREE ILFS_TREE_ROOT
  ILFS_TREE=${_ilfs_paths_tree[$path]}
  ILFS_TREE_ROOT=${_ilfs_trees_root[$ILFS_TREE]}

  # absolute/canonic paths
  local ILFS_PATH=$path
  local ILFS_PATH_OPTS_RO=${_ilfs_paths_opts[$path//ro]-}
  local ILFS_PATH_OPTS_INIT=${_ilfs_paths_opts[$path//init]-}
  local ILFS_PATH_OPTS_TYPE=${_ilfs_paths_opts[$path//type]-e}

  # relative paths
  local ILFS_RELPATH ILFS_EXISTING_RELPATH ILFS_INIT_SUBPATH
  ILFS_RELPATH=${path#/}
  if [[ -n "$ILFS_RELPATH" ]]; then
    dirname_v ILFS_EXISTING_RELPATH "$ILFS_RELPATH"
    basename_v ILFS_INIT_SUBPATH "$ILFS_RELPATH"
    local basename
    while [[ "$ILFS_EXISTING_RELPATH" != . && ! -d "$ILFS_TREE_ROOT/$ILFS_EXISTING_RELPATH" ]]; do
      basename_v basename "$ILFS_EXISTING_RELPATH"
      ILFS_INIT_SUBPATH="$basename/$ILFS_INIT_SUBPATH"
      dirname_v ILFS_EXISTING_RELPATH "$ILFS_EXISTING_RELPATH"
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

    # Exported functions
    export -f dirname_v
    export -f basename_v
    export -f ilfs_envsubst
    export -f ilfs_err # TODO: Revisit error handling in initcmd
    export -f il_mkdir
    export -f il_template_envsubst
    export -f il_copy
    export -f il_ownership
    export -f il_apply_to_subpaths

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
  dirname_v parentdir "$ILFS_INIT_SUBPATH"
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
    local parentdir
    dirname_v parentdir "$ILFS_INIT_SUBPATH"
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
  dirname_v path "$path"
  while [[ "$path" != . ]]; do
    subpaths=("$path" "${subpaths[@]}")
    dirname_v path "$path"
  done
  "$@" "${subpaths[@]}"
}
