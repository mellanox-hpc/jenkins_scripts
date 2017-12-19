#!/bin/bash -xeE
export PATH=/hpc/local/bin::/usr/local/bin:/bin:/usr/bin:/usr/sbin:${PATH}

rel_path=$(dirname $0)
abs_path=$(readlink -f $rel_path)

jenkins_test_build=${jenkins_test_build:="yes"}
jenkins_test_check=${jenkins_test_check:="yes"}
jenkins_test_src_rpm=${jenkins_test_src_rpm:="yes"}
jenkins_test_cov=${jenkins_test_cov:="yes"}
jenkins_test_comments=${jenkins_test_comments:="no"}
jenkins_test_vg=${jenkins_test_vg:="no"}

timeout_exe=${timout_exe:="timeout -s SIGKILL 1m"}

# prepare to run from command line w/o jenkins
if [ -z "$WORKSPACE" ]; then
    WORKSPACE=$PWD
    JOB_URL=$WORKSPACE
    BUILD_NUMBER=1
    JENKINS_RUN_TESTS=1
    NOJENKINS=${NOJENKINS:="yes"}
fi

OUTDIR=$WORKSPACE/out

prefix=jenkins
rm -rf ${WORKSPACE}/${prefix}
mkdir -p ${WORKSPACE}/${prefix}
work_dir=${WORKSPACE}/${prefix}
build_dir=${work_dir}/build
pmix_dir=${work_dir}/install
build_dir=${work_dir}/build
rpm_dir=${work_dir}/rpms
cov_dir=${work_dir}/cov
tarball_dir=${work_dir}/tarball


make_opt="-j$(nproc)"

test_ret=0

# extract jenkins commands from function args
function check_commands
{
    local cmd=$1
    local pat=""
    local test_list="threads src_rpm oshmem check help_txt known_issues cov all"
    for pat in $(echo $test_list); do
        echo -n "checking $pat "
        if [[ $cmd =~ jenkins\:.*no${pat}.* ]]; then
            echo disabling 
            eval "jenkins_test_${pat}=no"
        elif [[ $cmd =~ jenkins\:.*${pat}.* ]]; then
            echo enabling
            eval "jenkins_test_${pat}=yes"
        else
            echo no directive for ${pat}
        fi
    done

    if [ "$jenkins_test_all" = "yes" ]; then
        echo Enabling all tests
        for pat in $(echo $test_list); do
            eval "jenkins_test_${pat}=yes"
        done
    fi
}

function test_cov
{
    local cov_root_dir=$1
    local cov_proj=$2
    local cov_make_cmd=$3
    local cov_directive=$4

    local nerrors=0;

    module load tools/cov

    local cov_build_dir=$cov_dir/$cov_proj

    rm -rf $cov_build_dir
    cov-build   --dir $cov_build_dir $cov_make_cmd

    for excl in $cov_exclude_file_list; do
        cov-manage-emit --dir $cov_build_dir --tu-pattern "file('$excl')" delete
    done

    cov-analyze --dir $cov_build_dir
    nerrors=$(cov-format-errors --dir $cov_build_dir | awk '/Processing [0-9]+ errors?/ { print $2 }')

    index_html=$(cd $cov_build_dir && find . -name index.html | cut -c 3-)

    if [ -n "$nerrors" ]; then
        if [ "$nerrors" = "0" ]; then
            echo ok - coverity found no issues for $cov_proj >> $cov_stat_tap
        else
            echo "not ok - coverity detected $nerrors failures in $cov_proj # $cov_directive" >> $cov_stat_tap
            local cov_proj_disp="$(echo $cov_proj|cut -f1 -d_)"
            echo "" >> $gh_cov_msg
            echo "* Coverity found $nerrors errors for ${cov_proj_disp}" >> $gh_cov_msg
            echo "<li><a href=${cov_proj}/output/errors/index.html>Report for ${cov_proj}</a>" >> $cov_dir/index.html
        fi
    else
        echo "not ok - coverity failed to run for $cov_proj # SKIP failed to init coverity" >> $cov_stat_tap
    fi

    module unload tools/cov

    return $nerrors
}

# check for jenkins commands in PR title
if [ -n "$ghprbPullTitle" ]; then
    check_commands "$ghprbPullTitle"
fi

# check for jenkins command in PR last comment
if [ -n "$ghprbPullLink" ]; then
    set +xeE
    pr_url=$(echo $ghprbPullLink | sed -e s,github.com,api.github.com/repos,g -e s,pull,issues,g)
    pr_url="${pr_url}/comments"
    pr_file="$WORKSPACE/github_pr_${ghprbPullId}.json"
    curl -s $pr_url > $pr_file
    echo Fetching PR comments from URL: $pr_url

    # extracting last comment
    pr_comments="$(cat $pr_file | jq -M -a '.[length-1] | .body')"

    echo Last comment: $pr_comments
    if [ -n "$pr_comments" ]; then
        check_commands "$pr_comments"
    fi
    set -xeE
fi

echo Running following tests:
set|grep jenkins_test_

function on_start()
{
    echo Starting on host: $(hostname)

    export distro_name=`python -c 'import platform ; print platform.dist()[0]' | tr '[:upper:]' '[:lower:]'`
    export distro_ver=`python  -c 'import platform ; print platform.dist()[1]' | tr '[:upper:]' '[:lower:]'`
    if [ "$distro_name" == "suse" ]; then
        patch_level=$(egrep PATCHLEVEL /etc/SuSE-release|cut -f2 -d=|sed -e "s/ //g")
        if [ -n "$patch_level" ]; then
            export distro_ver="${distro_ver}.${patch_level}"
        fi
    fi
    echo $distro_name -- $distro_ver

    # save current environment to support debugging
#    set +x
#    env| sed -ne "s/\(\w*\)=\(.*\)\$/export \1='\2'/p" > $WORKSPACE/test_env.sh
#    chmod 755 $WORKSPACE/test_env.sh
#    set -x
}

function on_exit
{
    set +x
    rc=$((rc + $?))
    echo exit code=$rc
    if [ $rc -ne 0 ]; then
        # FIX: when rpmbuild fails, it leaves folders w/o any permissions even for owner
        # jenkins fails to remove such and fails
        find $rpm_dir -type d -exec chmod +x {} \;
    fi
}

function check_out()
{
    for out in `ls $OUTDIR/out.*`; do
        status=`cat $out`
        echo "check file: $out: $status"
        if [ "$status" != "OK" ]; then
            test_ret=1
        fi
    done
}

# $1 - test name
# $2 - test command
function check_result()
{
    set +e
    eval $timeout_exe $2
    ret=$?
    set -e
    check_out
    if [ $ret -gt 0 ]; then
        echo "not ok $test_id $1 ($2)" >> $run_tap
        test_ret=1
    else
        echo "ok $test_id $1 ($2)" >> $run_tap
    fi
    rm $OUTDIR/*
    test_id=$((test_id+1))
}

# $1 - GDS external module name
function pmix_run_tests()
{
    cd $build_dir/test

    # set the gds param
    gds=$1
    if [ "" = "$gds" ]; then
        gds_param=""
    else
        gds_param="--gds $gds"
    fi

    echo "1..14" >> $run_tap

    test_ret=0

    test_id=1
    # 1 blocking fence with data exchange among all processes from two namespaces:
    test_exec='./pmix_test -n 4 --ns-dist 3:1 --fence "[db | 0:0-2;1:3]" -o $OUTDIR/out'
    check_result "blocking fence w/ data all" "$test_exec $gds_param"
    test_exec='./pmix_test -n 4 --ns-dist 3:1 --fence "[db | 0:;1:3]" -o $OUTDIR/out'
    check_result "blocking fence w/ data all" "$test_exec $gds_param"
    test_exec='./pmix_test -n 4 --ns-dist 3:1 --fence "[db | 0:;1:]" -o $OUTDIR/out'
    check_result "blocking fence w/ data all" "$test_exec $gds_param"

    # 1 non-blocking fence without data exchange among processes from the 1st namespace
    test_exec='./pmix_test -n 4 --ns-dist 3:1 --fence "[0:]" -o $OUTDIR/out'
    check_result "non-blocking fence w/o data" "$test_exec $gds_param"

    # blocking fence without data exchange among processes from the 1st namespace
    test_exec='./pmix_test -n 4 --ns-dist 3:1 --fence "[b | 0:]" -o $OUTDIR/out'
    check_result "blocking fence w/ data" "$test_exec $gds_param"

    # non-blocking fence with data exchange among processes from the 1st namespace. Ranks 0, 1 from ns 0 are sleeping for 2 sec before doing fence test.
    test_exec='./pmix_test -n 4 --ns-dist 3:1 --fence "[d | 0:]" --noise "[0:0,1]" -o $OUTDIR/out'
    check_result "non-blocking fence w/ data" "$test_exec $gds_param"

    # blocking fence with data exchange across processes from the same namespace.
    test_exec='./pmix_test -n 4 --job-fence -c -o $OUTDIR/out'
    check_result "blocking fence w/ data on the same nspace" "$test_exec $gds_param"

    # blocking fence with data exchange across processes from the same namespace.
    test_exec='./pmix_test -n 4 --job-fence -o $OUTDIR/out'
    check_result "blocking fence w/o data on the same nspace" "$test_exec $gds_param"

    # 3 fences: 1 - non-blocking without data exchange across processes from ns 0,
    # 2 - non-blocking across processes 0 and 1 from ns 0 and process 3 from ns 1,
    # 3 - blocking with data exchange across processes from their own namespace.
    # Disabled as incorrect at the moment
    # test_exec='./pmix_test -n 4 --job-fence -c --fence "[0:][d|0:0-1;1:]" --use-same-keys --ns-dist "3:1"'
    # check_result "mix fence" $test_exec

    # test publish/lookup/unpublish functionality.
    test_exec='./pmix_test -n 2 --test-publish -o $OUTDIR/out'
    check_result "publish" "$test_exec $gds_param"

    # test spawn functionality.
    test_exec='./pmix_test -n 2 --test-spawn -o $OUTDIR/out'
    check_result "spawn" "$test_exec $gds_param"

    # test connect/disconnect between processes from the same namespace.
    test_exec='./pmix_test -n 2 --test-connect -o $OUTDIR/out'
    check_result "connect" "$test_exec $gds_param"

    # resolve peers from different namespaces.
    test_exec='./pmix_test -n 5 --test-resolve-peers --ns-dist "1:2:2" -o $OUTDIR/out'
    check_result "resolve peers" "$test_exec $gds_param"

    # resolve peers from different namespaces.
    test_exec='./pmix_test -n 5 --test-replace 100:0,1,10,50,99 -o $OUTDIR/out'
    check_result "key replacement" "$test_exec $gds_param"

    # resolve peers from different namespaces.
    test_exec='./pmix_test -n 5 --test-internal 10 -o $OUTDIR/out'
    check_result "local store" "$test_exec $gds_param"

    # run valgrind
    if [ "$jenkins_test_vg" = "yes" ]; then 
        set +e
        module load tools/valgrind
        vg_opt="--tool=memcheck --leak-check=full --error-exitcode=0 --trace-children=yes  --trace-children-skip=*/sed,*/collect2,*/gcc,*/cat,*/rm,*/ls --track-origins=yes --xml=yes --xml-file=valgrind%p.xml --fair-sched=try --gen-suppressions=all"
        valgrind $vg_opt  ./pmix_test -n 4 --timeout 60 --ns-dist 3:1 --fence "[db | 0:;1:3]"
        valgrind $vg_opt  ./pmix_test -n 4 --timeout 60 --job-fence -c
        valgrind $vg_opt  ./pmix_test -n 2 --timeout 60 --test-publish
        valgrind $vg_opt  ./pmix_test -n 2 --timeout 60 --test-spawn
        valgrind $vg_opt  ./pmix_test -n 2 --timeout 60 --test-connect
        valgrind $vg_opt  ./pmix_test -n 5 --timeout 60 --test-resolve-peers --ns-dist "1:2:2"
        valgrind $vg_opt  ./pmix_test -n 5 --test-replace 100:0,1,10,50,99
        valgrind $vg_opt  ./pmix_test -n 5 --test-internal 10
        module unload tools/valgrind
        set -e
    fi

    if [ "$test_ret" = "0" ]; then
        echo "Test OK"
    else
        echo "Test failed"
    fi
}

trap "on_exit" INT TERM ILL KILL FPE SEGV ALRM

on_start

autogen_done=0

cd $WORKSPACE
if [ "$jenkins_test_build" = "yes" ]; then
    echo "Checking for build ..."

    cd ${WORKSPACE}/${prefix}
    curl -L https://github.com/libevent/libevent/releases/download/release-2.0.22-stable/libevent-2.0.22-stable.tar.gz | tar -xz
    cd libevent-2.0.22-stable
    libevent_dir=$PWD/install
    ./autogen.sh && ./configure --prefix=$libevent_dir && make && make install

    cd $WORKSPACE
    if [ -x "autogen.sh" ]; then
        autogen_script=./autogen.sh
    else
        autogen_script=./autogen.pl
    fi

    configure_args="--with-libevent=$libevent_dir"

    # build pmix
    $autogen_script
    autogen_done=1 
    echo ./configure --prefix=$pmix_dir $configure_args | bash -xeE
    make $make_opt install
    jenkins_build_passed=1

    # make check
    if [ "$jenkins_test_check" = "yes" ]; then
        make $make_opt check || exit 12
    fi
fi

cd $WORKSPACE
if [ -n "jenkins_build_passed" -a "$jenkins_test_cov" = "yes" ]; then
    echo "Checking for coverity ..."

    vpath_dir=$WORKSPACE
    cov_proj="all"
    gh_cov_msg=$WORKSPACE/cov_gh_msg.txt
    cov_stat=$vpath_dir/cov_stat.txt
    cov_stat_tap=$vpath_dir/cov_stat.tap
    cov_build_dir=$vpath_dir/${prefix}/cov_build
    cov_url_webroot=${JOB_URL}/${BUILD_ID}/Coverity_Report

    rm -f $cov_stat $cov_stat_tap

    if [ -d "$vpath_dir" ]; then
        mkdir -p $cov_build_dir
        pushd $vpath_dir
        for dir in $cov_proj; do
            if [ "$dir" = "all" ]; then
                make_cov_opt=""
                cov_directive="SKIP"
            else
                if [ ! -d "$dir" ]; then
                    continue
                fi
                cov_directive="TODO"
                make_cov_opt="-C $dir"
            fi
            echo Working on $dir

            cov_proj="cov_$(basename $dir)"
            set +eE
            make $make_cov_opt $make_opt clean 2>&1 > /dev/null
            test_cov $cov_build_dir $cov_proj "make $make_cov_opt $make_opt all" $cov_directive
            set -eE
        done
        if [ -n "$ghprbPullId" -a -f "$gh_cov_msg" ]; then
            echo "* Coverity report at $cov_url_webroot" >> $gh_cov_msg
            if [ "$jenkins_test_comments" = "yes" ]; then
                gh pr $ghprbPullId --comment "$(cat $gh_cov_msg)"
            fi
        fi
        popd
    fi
fi

cd $WORKSPACE
if [ "$jenkins_test_src_rpm" = "yes" ]; then
    echo "Checking for rpm ..."

    # check distclean
    make $make_opt distclean 
    if [ "${autogen_done}" != "1" ]; then
        $autogen_script 
        autogen_done=1
    fi

    if [ -x /usr/bin/dpkg-buildpackage ]; then
        echo "Do not support PMIX on debian"
    else
        echo ./configure --prefix=$pmix_dir $configure_args | bash -xeE || exit
        echo "Building PMIX src.rpm"
        rm -rf $tarball_dir
        mkdir -p $tarball_dir

        make_dist_args="--highok --distdir=$tarball_dir --greekonly"

        for arg in no-git-update dirtyok verok; do
            if grep $arg contrib/make_tarball 2>&1 > /dev/null; then 
                make_dist_args="$make_dist_args --${arg}"
            fi
        done

        # ugly hack, make_tarball has hardcoded "-j32" and sometimes it fails on some race
        sed -i -e s,-j32,-j8,g contrib/make_tarball

        export LIBEVENT=$libevent_dir
        chmod +x ./contrib/make* ./contrib/buildrpm.sh
        echo contrib/make_tarball $make_dist_args | bash -xeE || exit 11

        # build src.rpm
        # svn_r=$(git rev-parse --short=7 HEAD| tr -d '\n') ./contrib/make_tarball --distdir=$tarball_dir
        tarball_src=$(ls -1 $tarball_dir/pmix-*.tar.bz2|sort -r|head -1)

        echo "Building PMIX bin.rpm"
        rpm_flags="--define 'mflags -j8' --define '_source_filedigest_algorithm md5' --define '_binary_filedigest_algorithm md5'"
        (cd ./contrib/ && env rpmbuild_options="$rpm_flags" rpmtopdir=$rpm_dir ./buildrpm.sh $tarball_src)
        # check distclean
        make $make_opt distclean 
    fi
fi

#
# JENKINS_RUN_TESTS should be set in jenkins slave node to indicate that node can run tests
#
cd $WORKSPACE
if [ -n "$JENKINS_RUN_TESTS" -a "$JENKINS_RUN_TESTS" -ne "0" ]; then
    run_tap=$WORKSPACE/run_test.tap
    rm -rf $run_tap

    export TMPDIR="/tmp"

    if [ ! -d "$OUTDIR" ]; then
        mkdir $OUTDIR
    fi

    # Run autogen only once
    if [ "${autogen_done}" != "1" ]; then 
        $autogen_script 
        autogen_done=1
    fi

    vers=1
    if [ -f "config/pmix_get_version.sh" ] && [ -f "VERSION" ]; then
        vers=`config/pmix_get_version.sh VERSION --major`
    fi

    rc=0

    if [ "$vers" -ge "2" ]; then
        echo "----------------------------------- Building ----------------------------------------------"
        mkdir ${build_dir}
        cd ${build_dir}
        echo ${WORKSPACE}/configure --prefix=${pmix_dir} $configure_args --disable-visibility --enable-dstore | bash -xeE
        make $make_opt install

        echo "--------------------------- Checking with messages ----------------------------------------"
        echo "Checking without dstor:" >> $run_tap
        pmix_run_tests "hash"
        rc=$((test_ret+rc))

        echo "--------------------------- Checking with pthread-lock ------------------------------------"
        echo "Checking with dstor:" >> $run_tap
        pmix_run_tests "ds12"

        rm -Rf ${pmix_dir} ${build_dir}
        rc=$((test_ret+rc))

        # Test pmix/dstore/flock
        echo "--------------------------- Building with dstore/flock ----------------------------------------"
        mkdir ${build_dir}
        cd ${build_dir}
        echo ${WORKSPACE}/configure --prefix=$pmix_dir $configure_args --disable-visibility --enable-dstore --disable-dstore-pthlck | bash -xeE
        make $make_opt install
        echo "--------------------------- Checking with dstore/flock ----------------------------------------"
        echo "Checking with dstor/flock:" >> $run_tap
        pmix_run_tests "ds12"
        rm -Rf ${pmix_dir} ${build_dir}
        rc=$((test_ret+rc))

    else
        # Test pmix/messaging
        echo "--------------------------- Building with messages ----------------------------------------"
        mkdir ${build_dir}
        cd ${build_dir}
        echo ${WORKSPACE}/configure --prefix=${pmix_dir} $configure_args --disable-visibility --enable-dstore | bash -xeE
        make $make_opt install
        echo "--------------------------- Checking with messages ----------------------------------------"
        echo "Checking without dstor:" >> $run_tap
        pmix_run_tests
        rm -Rf ${pmix_dir} ${build_dir}
        rc=$((test_ret+rc))

        # Test pmix/dstore/flock
        echo "--------------------------- Building with dstore/flock ----------------------------------------"
        mkdir ${build_dir}
        cd ${build_dir}
        echo ${WORKSPACE}/configure --prefix=$pmix_dir $configure_args --disable-visibility --enable-dstore --disable-dstore-pthlck | bash -xeE
        make $make_opt install
        echo "--------------------------- Checking with dstore/flock ----------------------------------------"
        echo "Checking with dstor/flock:" >> $run_tap
        pmix_run_tests
        rm -Rf ${pmix_dir} ${build_dir}
        rc=$((test_ret+rc))

        # Test pmix/dstore/pthread-lock
        echo "--------------------------- Building with dstore/pthread-lock ----------------------------------------"
        mkdir ${build_dir}
        cd ${build_dir}
        echo ${WORKSPACE}/configure --prefix=$pmix_dir $configure_args --disable-visibility --enable-dstore | bash -xeE
        make $make_opt install
        echo "--------------------------- Checking with dstore/pthread-lock ----------------------------------------"
        echo "Checking with dstor:" >> $run_tap
        pmix_run_tests
        rm -Rf ${pmix_dir} ${build_dir}
        rc=$((test_ret+rc))
    fi

    unset TMPDIR
    rmdir $OUTDIR
    cat $WORKSPACE/run_test.tap
    exit $rc

fi

