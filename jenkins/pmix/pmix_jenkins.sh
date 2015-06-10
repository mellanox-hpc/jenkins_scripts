#!/bin/bash -xeE
export PATH=/hpc/local/bin::/usr/local/bin:/bin:/usr/bin:/usr/sbin:${PATH}

rel_path=$(dirname $0)
abs_path=$(readlink -f $rel_path)
source $abs_path/../functions.sh

jenkins_test_build=${jenkins_test_build:="yes"}
jenkins_test_check=${jenkins_test_check:="yes"}
timeout_exe=${timout_exe:="timeout -s SIGKILL 10m"}

# prepare to run from command line w/o jenkins
if [ -z "$WORKSPACE" ]; then
    WORKSPACE=$PWD
    JOB_URL=$WORKSPACE
    BUILD_NUMBER=1
    JENKINS_RUN_TESTS=yes
    NOJENKINS=${NOJENKINS:="yes"}
fi

PMIX_HOME=$WORKSPACE/pmix_install

make_opt="-j$(nproc)"

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

    export distro_name=$(python -c 'import platform ; print platform.dist()[0]' | tr '[:upper:]' '[:lower:]')
    export distro_ver=$(python  -c 'import platform ; print platform.dist()[1]' | tr '[:upper:]' '[:lower:]')
    if [ "$distro_name" == "suse" ]; then
        patch_level=$(egrep PATCHLEVEL /etc/SuSE-release|cut -f2 -d=|sed -e "s/ //g")
        if [ -n "$patch_level" ]; then
            export distro_ver="${distro_ver}.${patch_level}"
        fi
    fi
    echo $distro_name -- $distro_ver

    # save current environment to support debugging
    set +x
    env| sed -ne "s/\(\w*\)=\(.*\)\$/export \1='\2'/p" > $WORKSPACE/test_env.sh
    chmod 755 $WORKSPACE/test_env.sh
    set -x
}

function on_exit
{
    set +x
    rc=$((rc + $?))
    echo exit code=$rc
    if [ $rc -ne 0 ]; then
        # FIX: when rpmbuild fails, it leaves folders w/o any permissions even for owner
        # jenkins fails to remove such and fails
        find $topdir -type d -exec chmod +x {} \;
    fi
}

trap "on_exit" INT TERM ILL KILL FPE SEGV ALRM

on_start


cd $WORKSPACE

if [ "$jenkins_test_build" = "yes" ]; then
    echo "Building PMIX"
    wget http://sourceforge.net/projects/levent/files/libevent/libevent-2.0/libevent-2.0.22-stable.tar.gz
    tar zxf libevent-2.0.22-stable.tar.gz
    cd libevent-2.0.22-stable
    libevent_dir=$PWD/install
    ./autogen.sh && ./configure --prefix=$libevent_dir && make && make install

    cd $WORKSPACE
    if [ -x "autogen.sh" ]; then
        autogen_script=./autogen.sh
    else
        autogen_script=./autogen.pl
    fi

    # build pmix
    $autogen_script 
    echo ./configure --prefix=$PMIX_HOME --with-libevent=$libevent_dir | bash -xeE
    make $make_opt install 

    # make check
    if [ "$jenkins_test_check" = "yes" ]; then
        make $make_opt check || exit 12
    fi

    # make cov
    make $make_opt clean

    gh_cov_msg=$WORKSPACE/cov_gh_msg.txt
    cov_stat_tap=$WORKSPACE/cov_test.tap
    cov_url_webroot=${JOB_URL}/${BUILD_ID}/Coverity_Report

    set +e
    test_cov $WORKSPACE "pmix" "make $make_opt all" "TODO"
    if [ -n "$ghprbPullId" -a -f "$gh_cov_msg" ]; then
        echo "* Coverity report at $cov_url_webroot" >> $gh_cov_msg
        gh pr $ghprbPullId --comment "$(cat $gh_cov_msg)"
    fi
    set -e

fi

#
# JENKINS_RUN_TESTS should be set in jenkins slave node to indicate that node can run tests
#
if [ -n "$JENKINS_RUN_TESTS" ]; then
    
    exe_dir=$WORKSPACE/test
    cd $exe_dir
    (PATH=$PMIX_HOME/bin:$PATH LD_LIBRARY_PATH=$PMIX_HOME/lib:$LD_LIBRARY_PATH make -C $exe_dir all)
    # 1 blocking fence with data exchange among all processes from two namespaces:
    ./pmix_test -n 4 --ns-dist 3:1 --fence "[db | 0:0-2;1:3]"
    ./pmix_test -n 4 --ns-dist 3:1 --fence "[db | 0:;1:3]"
    ./pmix_test -n 4 --ns-dist 3:1 --fence "[db | 0:;1:]"

    # 1 non-blocking fence without data exchange among processes from the 1st namespace
    ./pmix_test -n 4 --ns-dist 3:1 --fence "[0:]"

    # blocking fence without data exchange among processes from the 1st namespace
    ./pmix_test -n 4 --ns-dist 3:1 --fence "[b | 0:]"

    # non-blocking fence with data exchange among processes from the 1st namespace. Ranks 0, 1 from ns 0 are sleeping for 2 sec before doing fence test.
    ./pmix_test -n 4 --ns-dist 3:1 --fence "[d | 0:]" --noise "[0:0,1]"

    # blocking fence with data exchange across processes from the same namespace.
    ./pmix_test -n 4 --job-fence -c

    # 3 fences: 1 - non-blocking without data exchange across processes from ns 0,
    # 2 - non-blocking across processes 0 and 1 from ns 0 and process 3 from ns 1,
    # 3 - blocking with data exchange across processes from their own namespace.
    ./pmix_test -n 4 --job-fence -c --fence "[0:][d|0:0-1;1:]" --use-same-keys --ns-dist "3:1"

    # test publish/lookup/unpublish functionality.
    ./pmix_test -n 2 --test-publish

    # test spawn functionality.
    ./pmix_test -n 2 --test-spawn

    # test connect/disconnect between processes from the same namespace.
    ./pmix_test -n 2 --test-connect

    # resolve peers from different namespaces.
    ./pmix_test -n 5 --test-resolve-peers --ns-dist "1:2:2"
    
fi

