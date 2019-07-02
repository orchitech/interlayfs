# testlib.sh
# Provide common functions for testing interlayfs testing.
#
# Copyright: Orchitech Solutions, s.r.o.
# License: GNU Lesser General Public License v3

# Perform test in a private mount namespace.
execInPrivateNs()
{
  if [[ -z "$_ILFS_IN_TEST_NAMESPACE" ]]; then
    _ILFS_IN_TEST_NAMESPACE=1 exec unshare -m "$@"
    exit $?
  fi
}

umountPathsStartingWith()
{
  local path=$1
  local mp umounts=-1 umount_loops=3

  while (( umounts != 0 && umount_loops-- > 0 )); do
    umounts=0
    while read -r type mp rest; do
      mp=$(printf '%b' "$mp")
      if [[ "$mp" = "$path"* ]]; then
        umount "$mp" || :
        ((umounts++)) || :
      fi
    done < <(tac /proc/mounts)
  done
  if (( umounts != 0 )); then
    echo "Cannot clean up mounts under '$path'. " >&2
    echo "THE SYSTEM HAS BEEN LEFT ALTERED!" >&2
    exit 1
  fi
  return 0
}

# workaround for https://github.com/kward/shunit2/issues/37
patchShellOpts()
{
  local f=$1
  eval "__orig_$f()
  # $(declare -f $f)
  $f()
  {
    local -r __testenv_opts=\$(set +o)
    local __testenv_errexit __orig_retcode
    case \$- in
      *e*) __testenv_errexit=-e ;;
      *) __testenv_errexit=+e ;;
    esac
    set +eEu
    set +o pipefail
    __orig_$f \"\$@\"
    __orig_retcode=\$?
    eval \"\$__testenv_opts\"
    set \"\$__testenv_errexit\"
    return \$__orig_retcode
  }"
}

oneTimeSetUp()
{
  patchShellOpts assertTrue
  patchShellOpts assertFalse
  trap 'tearDown; ilfs_fatal "Unhandled error."' ERR 
}

set -eE
