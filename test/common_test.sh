#!/bin/bash

SHUNIT_PARENT=$(realpath "$0")
ILFS_TEST_PATH=$(dirname "$SHUNIT_PARENT")
ILFS_ROOT=$(dirname "$ILFS_TEST_PATH")
source "$ILFS_ROOT"/test/testlib.sh || exit 1

source "$ILFS_ROOT"/lib/libinterlayfs.sh || exit 1

# Check expected dirname and basename behavior
declare -Ar DIRNAMES=(
  [/a/b]=/a
  [/a/]=/
  [/]=/
  [//]=/
  [a/b]=a
  [a//b//]=a
  [a]=.
  [a/]=.
  [.]=.
)
declare -Ar BASENAMES=(
  [/a/b]=b
  [/a/]=a
  [/]=/
  [//]=/
  [.//]=.
  [a//.]=.
  [a/b]=b
  [a//b//]=b
  [a]=a
  [a/]=a
  [.]=.
)

testDirname()
{
  local p
  for p in "${!DIRNAMES[@]}"; do
    assertEquals "dirname of '$p'" "${DIRNAMES[$p]}" "$(dirname "$p")"
  done
}

testDirnameV()
{
  local p d
  for p in "${!DIRNAMES[@]}"; do
    dirname_v d "$p"
    assertEquals "dirname of '$p'" "${DIRNAMES[$p]}" "$d"
  done
}

testBasename()
{
  local p
  for p in "${!BASENAMES[@]}"; do
    assertEquals "basename of '$p'" "${BASENAMES[$p]}" "$(basename "$p")"
  done
}

testBasenameV()
{
  local p b
  for p in "${!BASENAMES[@]}"; do
    basename_v b "$p"
    assertEquals "basename of '$p'" "${BASENAMES[$p]}" "$b"
  done
}

testBashArrays()
{
  local -a a
  # prepend to all elements
  a=( x '\' )
  a=( "${a[@]/#//}" )
  assertEquals 2 "${#a[@]}"
  assertEquals '/x' "${a[0]}"
  assertEquals '/\' "${a[1]}"
  a=()
  a=( "${a[@]/#//}" )
  assertEquals 0 "${#a[@]}"
}

testEnvSubst()
{
  local -r nl=$'\n'
  assertEquals 'empty template' "" "$(ilfs_envsubst <<<"")"
  assertEquals 'trivial single line template' " foo bar" "$(ilfs_envsubst <<<" foo bar")"
  assertEquals 'trivial multiline template' " foo$nl bar" "$(ilfs_envsubst <<<" foo$nl bar")"
  assertEquals 'subst at start & backslash processing' \
    '$bar\$$bar\$${FOO}'"${nl}"'$bar\$baz' \
    "$(FOO='$bar\$' ilfs_envsubst <<<'${FOO}${FOO}\${FOO}'"${nl}"'${FOO}baz')"
  assertEquals 'subst at end & backslash processing' \
    '\\${FOO}$bar\$'"$nl"'$bar\$$bar\$' \
    "$(FOO='$bar\$' ilfs_envsubst <<<'\\\${FOO}${FOO}'"$nl"'${FOO}${FOO}')"
  assertEquals 'empty string subst' \
    '' \
    "$(FOO='' ilfs_envsubst <<<'${FOO}')"

  # error conditions
  local ret
  ilfs_envsubst <<<'$' &>/dev/null && fail 'unquoted $' || :
  FOO=bar ilfs_envsubst <<<'foo $'"$nl"'{FOO}' &>/dev/null && fail 'NL between $ and {' || :
  FOO=bar ilfs_envsubst <<<'foo $\'"$nl"'{FOO}' &>/dev/null && fail 'quoted NL between $ and {' || :
  ilfs_envsubst <<<'${UNDEFINED42}' &>/dev/null && ret=0 || ret=$?; \
    assertEquals 'error code for undefined variable' 1 $ret
  ilfs_envsubst <<<'${42UNDEFINED}' &>/dev/null && ret=0 || ret=$?; \
    assertEquals 'error code for invalid variable name' 2 $ret
}

testParseOpts()
{
  local -A a=()
  ilfs_parse_opts 'rw' a
  assertTrue 'opts mismatch 1' "[[ ${#a[@]} -eq 1 && ${a[ro]} -eq 0 ]]"
  a=()
  ilfs_parse_opts 'rw,init=skip,ro' a 'x :'
  assertTrue 'opts mismatch 2' "[[ ${#a[@]} -eq 2 && ${a['x :ro']} -eq 1 && ${a['x :init']} = skip ]]"
  ilfs_parse_opts 'rw' a
}

testPathValid()
{
  local -a ok nok
  ok=( / /a /dir/sub /... /a/... /a/.../x '/a/. ' '/a/ ./dir' )
  nok=( . .. a /. /./ /.. /../ // //dir /dir//sub /dir/.. /dir/sub/.. /dir/./sub /dir1/../dir2 '' )
  local p
  for p in "${ok[@]}"; do
    ilfs_paths_validate "$p" || fail "'$p' should be valid" || :
  done
  for p in "${nok[@]}"; do
    ilfs_paths_validate "$p" && fail "'$p' should be invalid" || :
  done
}

testPathsContainsGlob()
{
  local -a glob noglob
  glob=( '*' '/x/*.jpg' '/x/*/y' 'x\*/x*' 'x*/x\*' 'x?' 'x\/a?/y' 'x/+(x)' 'a/[bc]/d' )
  noglob=( '[/]' 'x[x/x]x' '[\/]' 'x/+\(x)' 'a/[bc\]/d' )
  local s
  for s in "${glob[@]}"; do
    ilfs_paths_contains_glob "$s" || fail "'$s' should be treated as a glob" || :
  done
  for s in "${noglob[@]}"; do
    ilfs_paths_contains_glob "$s" && "'$s' should not be treated as a glob" || :
  done
}

testGlobexpand()
{
  mkdir -p "$SHUNIT_TMPDIR"/dir/{dir,.dotdir}
  touch "$SHUNIT_TMPDIR"/dir/{file,.dotfile,'ug ly)','*','quot:"'}
  mkdir "$SHUNIT_TMPDIR"/emptydir

  local pwd0=$PWD shopt0=$(shopt) ifs0=$IFS
  local -a matches

  ilfs_globexpand_v matches "$SHUNIT_TMPDIR"/dir '*'
  assertEquals "CWD affected" "$pwd0" "$PWD"
  assertEquals "shopt affected" "$shopt0" "$(shopt)"
  assertEquals "IFS affected" "$ifs0" "$IFS"
  assertEquals "dir+file glob expansion with dotnames" '* dir .dotdir .dotfile file quot:" ug ly)' "${matches[*]}"
  assertEquals "dir+file glob expansion with dotnames" 7 ${#matches[@]}

  ilfs_globexpand_v matches "$SHUNIT_TMPDIR"/dir '*/'
  assertEquals "dir glob expansion with dotnames" 'dir/ .dotdir/' "${matches[*]}"
  assertEquals "dir glob expansion with dotnames" 2 ${#matches[@]}

  ilfs_globexpand_v matches "$SHUNIT_TMPDIR"/emptydir '*/'
  assertEquals "glob expansion with no matches" 0 ${#matches[@]}
}

. shunit2
