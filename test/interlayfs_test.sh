#!/bin/bash

SHUNIT_PARENT=$(realpath "$0")
ILFS_TEST_PATH=$(dirname "$SHUNIT_PARENT")
ILFS_ROOT=$(dirname "$ILFS_TEST_PATH")
. "$ILFS_ROOT"/test/testlib.sh || exit 1
execInPrivateNs "$0" "$@"

. "$ILFS_ROOT"/lib/libinterlayfs.sh

setUp()
{
  declare -g TREES=${SHUNIT_TMPDIR}/trees
  mkdir "$TREES"
  (
    cd "$TREES"
    mkdir -p root
    mkdir -p src/{app/data/srcdata,lib}
    mkdir -p data1/lib/generated
    mkdir -p data2/app/data 
    mkdir target
  )
  ilfs_init "$TREES/target"
}

tearDown()
{
  umountPathsStartingWith "$TREES"
  ! [[ -d "$TREES" ]] || rm -rf "$TREES"
}

configureWithoutRoot()
{
  ilfs_trees_add src "$TREES/src" 
  ilfs_trees_add data1 "$TREES/data1" 'ro'
  ilfs_trees_add data2 "$TREES/data2" 
  ilfs_paths_load_config << END
src   app               ro
data2 app/data/         init=missing il_mkdir
data2 config.txt        init=missing il_template_envsubst $SHUNIT_TMPDIR/config.tpl.txt
src   app/data/srcdata
src   lib
data1 lib/generated
END
}

configureWithRoot()
{
  ilfs_trees_add root "$TREES/root"
  ilfs_trees_add src "$TREES/src" 
  ilfs_trees_add data1 "$TREES/data1" 'ro'
  ilfs_trees_add data2 "$TREES/data2" 
  ilfs_paths_load_config << END
root  /
src   app               ro
data2 app/data/         init=missing il_mkdir
src   app/data/srcdata
src   lib
data1 lib/generated
END
}

assertPathCompOpt()
{
  local expected=$1 path=$2 opt=$3
  assertEquals "path '$path' option '$opt'" \
    "$expected" \
    "$(ilfs_paths_comp_opt "$path" "$opt")"
}

testConfig()
{
  configureWithRoot || fail "ilfs_paths_load_config"
  assertPathCompOpt 0 /                 ro
  assertPathCompOpt 1 /app              ro
  assertPathCompOpt 0 /app/data         ro
  assertPathCompOpt 0 /app/data/srcdata ro
  assertPathCompOpt 0 /lib              ro
  assertPathCompOpt 1 /lib/generated    ro
}

testCreateMountpoint()
{
  local ndirs=$(find "$TREES" -type d | wc -l)
  configureWithoutRoot
  ilfs_paths_create_mountpoint /app/data/srcdata || fail "ilfs_paths_create_mountpoint"
  assertTrue "mountpoint expected at '$TREES/data2/app/data/srcdata'" "[[ -d \$TREES/data2/app/data/srcdata ]]"
  assertEquals "one new mountpoint dir expected" $((ndirs + 1)) $(find "$TREES" -type d | wc -l)
}

testInitPaths()
{
  rm -rf "$TREES"/data2/*
  echo 'NAME1=${VALUE1}'$'\n''NAME2=${VALUE2}' > "$SHUNIT_TMPDIR"/config.tpl.txt

  configureWithoutRoot
  VALUE1=foo VALUE2=bar ilfs_paths_init || fail "ilfs_paths_init failed."
  assertEquals 'il_template_envsubst-created file' \
    'NAME1=foo'$'\n''NAME2=bar' \
    "$(cat "$TREES"/data2/config.txt)"
  assertTrue 'il_mkdir expected to create dir' '[[ -d "$TREES"/data2/app/data ]]'
}

testMount()
{
  configureWithRoot
  ilfs_mount
  find "$TREES/root" >> /tmp/ilfs.log
  ilfs_umount
}

testCliMountUnmount()
{
  local nmounts=$(wc -l < /proc/mounts)
  cat > "$SHUNIT_TMPDIR"/treefile << END
src   $TREES/src               ro
data1 $TREES/data\${DATA1_ID}
data2 $TREES/data\${DATA2_ID}
END
  cat > "$SHUNIT_TMPDIR"/pathfile << END
src  /
src   app               ro
data2 app/data/         init=missing il_mkdir
src   app/data/srcdata
src   lib
data1 lib/generated
END
  DATA1_ID=1 DATA2_ID=2 \
  "$ILFS_ROOT"/bin/interlayfs \
    --treefile "$SHUNIT_TMPDIR"/treefile \
    --pathfile "$SHUNIT_TMPDIR"/pathfile \
    "$TREES"/target || fail "interlayfs mount"

  local npaths=$(grep -c '^[^#]*[[:alnum:]]' "$SHUNIT_TMPDIR"/pathfile)
  assertEquals "$npaths more mounts expected compared to original $nmounts mounts" \
    $((nmounts+npaths)) \
    $(wc -l < /proc/mounts)

  "$ILFS_ROOT"/bin/interlayfs -u "$TREES"/target || fail "interlayfs unmount"

  assertEquals "Same number of mounts expected after unmount" $nmounts $(wc -l < /proc/mounts)
}

. shunit2
