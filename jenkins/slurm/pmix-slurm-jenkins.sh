#!/bin/bash -xeE
export PATH=/hpc/local/bin::/usr/local/bin:/bin:/usr/bin:/usr/sbin:${PATH}

rel_path=$(dirname $0)
abs_path=$(readlink -f $rel_path)
source $abs_path/../functions.sh

jenkins_test_build=${jenkins_test_build:="yes"}
jenkins_test_build_pre=${jenkins_test_build_pre:="yes"}
jenkins_test_check=${jenkins_test_check:="no"}
jenkins_test_cov=${jenkins_test_cov:="no"}
jenkins_test_style=${jenkins_test_style:="yes"}
timeout_exe=${timout_exe:="timeout -s SIGKILL 10m"}

# prepare to run from command line w/o jenkins
if [ -z "$WORKSPACE" ]; then
    WORKSPACE=$PWD
    JOB_URL=$WORKSPACE
    BUILD_NUMBER=1
    JENKINS_RUN_TESTS=yes
    NOJENKINS=${NOJENKINS:="yes"}
fi

TARGET_DIR=$WORKSPACE/pmix_install1
#TEST_ID=pmix-14102015.1988
TEST_ID=${TEST_ID:="pmix-$(date '+%d%m%Y').$$"}
TMP_DIR=$HOME/tmp/$TEST_ID
TMP_DIR_MUNGE=/tmp/$TEST_ID
mkdir -p $TMP_DIR
mkdir -p $TMP_DIR_MUNGE

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
    echo Exiting...

    set +x
    rc=$((rc + $?))
    echo exit code=$rc
    if [ $rc -ne 0 ]; then
        # FIX: when rpmbuild fails, it leaves folders w/o any permissions even for owner
        # jenkins fails to remove such and fails
        find $topdir -type d -exec chmod +x {} \;
    fi
    val=$(ps uxU $USER | grep slurmd | head -n 1 | awk '{print $2}')
    if [ -n $val ]; then
        kill -9 $val
    fi
    val=$(ps uxU $USER | grep slurmctld | head -n 1 | awk '{print $2}')
    if [ -n $val ]; then
        kill -9 $val
    fi
    val=$(ps uxU $USER | grep munged | head -n 1 | awk '{print $2}')
    if [ -n $val ]; then
        kill -9 $val
    fi
    set -x

    echo Checking if all daemons are unloaded
    ps uxU $USER | grep slurmd
    ps uxU $USER | grep slurmctld
    ps uxU $USER | grep munged
}

# $1 - test name
# $2 - test command
# $3 - match word in result output
# $4 - number of found
function check_result()
{
    local tmp_check_file="tmp_check_.$$"

    echo "running: $1 > $2"
    echo "expected: $3 $4 times"

    rm -f $tmp_check_file
    set +e
    if [ -n "$3" ]; then
        eval "$2" > $tmp_check_file 2>&1
        cat $tmp_check_file
        ret=$(grep OK $tmp_check_file | wc -l)
        ret=$(($ret-$4))
    else
        eval "$2"
        ret=$?
    fi
    set -e
    if [ $ret -gt 0 ]; then
        echo "not ok $test_id $1" >> $run_tap
    else
        echo "ok $test_id $1" >> $run_tap
    fi
    test_id=$((test_id+1))
}

function create_slurm_conf
{
    local hostname=$(hostname | cut -d . -f 1)
    local hostaddr=127.0.0.1
    mkdir -p $TARGET_DIR/etc
    mkdir -p $TARGET_DIR/tmp
    cat > $TARGET_DIR/etc/slurm.conf <<END_MSG
ControlMachine=$hostname                                      # CHANGE "HOSTNAME"
ControlAddr=$hostaddr

AuthType=auth/munge
ClusterName=fake_cluster
CryptoType=crypto/munge
FastSchedule=1
JobAcctGatherType=jobacct_gather/none
JobCompType=jobcomp/none
MpiDefault=none
ProctrackType=proctrack/pgid
#ReturnToService=1
SallocDefaultCommand="$TARGET_DIR/bin/srun -n1 -N1 --pty --preserve-env --mpi=none \$SHELL"
SchedulerType=sched/backfill
SchedulerPort=7321
SelectType=select/cons_res
SelectTypeParameters=CR_CPU
SlurmctldDebug=10
SlurmctldLogFile=$TARGET_DIR/tmp/slurmctld.log
SlurmctldPidFile=$TARGET_DIR/tmp/slurmctld.pid
SlurmctldPort=6827
SlurmdPidFile=$TARGET_DIR/tmp/slurmd.%n.pid
SlurmdDebug=10
SlurmdLogFile=$TARGET_DIR/tmp/slurmd.%n.log
SlurmdPort=6828
SlurmdSpoolDir=$TARGET_DIR/tmp/slurmd.%n.state
SlurmUser=$USER                                                   # CHANGE "USER"
SlurmdUser=$USER                                                  # CHANGE "USER"
StateSaveLocation=$TARGET_DIR/tmp/slurmctld.state
SwitchType=switch/none

# 
# COMPUTE NODES
FrontEndName=$hostname FrontEndAddr=$hostaddr                 # CHANGE "HOSTNAME"

NodeName=tux[1-4] NodeHostname=$hostaddr NodeAddr=$hostaddr
PartitionName=debug Nodes=tux[1-4] Default=YES MaxTime=INFINITE State=UP
END_MSG
}

trap "on_exit" INT TERM ILL KILL FPE SEGV ALRM

on_start

cd $WORKSPACE

if [ "$jenkins_test_build" = "yes" ]; then
    echo "Building munge"

    cd $TMP_DIR_MUNGE
    if [ ! -e munge-0.5.11 ]; then
        wget https://munge.googlecode.com/files/munge-0.5.11.tar.bz2
        bunzip2 munge-0.5.11.tar.bz2
        tar xf munge-0.5.11.tar
    fi
    cd munge-0.5.11
    MUNGE_DIR=$PWD/install
    rm -rf $MUNGE_DIR

    ./configure --prefix=$MUNGE_DIR && make && make install
    if [ ! -f ${MUNGE_DIR}/etc/munge/munge.key ]; then
        dd if=/dev/urandom bs=1 count=1024 >${MUNGE_DIR}/etc/munge/munge.key
        chmod 0400 ${MUNGE_DIR}/etc/munge/munge.key
    fi

    echo "Building pmix library"

    cd $TMP_DIR
    wget http://sourceforge.net/projects/levent/files/libevent/libevent-2.0/libevent-2.0.22-stable.tar.gz
    tar zxf libevent-2.0.22-stable.tar.gz
    cd libevent-2.0.22-stable
    LIBEVENT_DIR=$PWD/install
    ./autogen.sh && ./configure --prefix=$LIBEVENT_DIR && make && make install

    cd $TMP_DIR
    git clone https://github.com/pmix/master.git pmix
    cd pmix
    PMIX_DIR=$PWD/install
    if [ -x "autogen.sh" ]; then
        autogen_script=./autogen.sh
    else
        autogen_script=./autogen.pl
    fi
    $autogen_script 
    ./configure --prefix=$PMIX_DIR --with-libevent=$LIBEVENT_DIR
    make $make_opt install 

    cd test
    env PATH=$PMIX_DIR/bin:$PATH LD_LIBRARY_PATH=$PMIX_DIR/lib:$LD_LIBRARY_PATH make all && make install

    rm -rf $TARGET_DIR
    echo "Building slurm with pmix plugin (debug)"

#    cd $WORKSPACE
#    rm -rf build
#    ./autogen.sh
#    mkdir build && cd build 
#    ../configure --prefix=$TARGET_DIR --with-pmix=$PMIX_DIR \
#        --enable-debug CFLAGS=-g --with-hdf5=no \
#        --enable-front-end --enable-multiple-slurmd \
#        --sysconfdir=$TARGET_DIR/etc --with-munge=$MUNGE_DIR
#    make $make_opt
#    make $make_opt clean

    echo "Building slurm with pmix plugin (release)"

    cd $WORKSPACE
    rm -rf build
    ./autogen.sh
    mkdir build && cd build 
    ../configure --prefix=$TARGET_DIR --with-pmix=$PMIX_DIR \
        --enable-debug CFLAGS=-g --with-hdf5=no \
        --enable-front-end --enable-multiple-slurmd \
        --sysconfdir=$TARGET_DIR/etc --with-munge=$MUNGE_DIR
    make $make_opt install
    make contrib && make install
fi

if [ "$jenkins_test_build_pre" = "yes" ]; then
    echo "Build preparing"

    MUNGE_DIR=$TMP_DIR_MUNGE/munge-0.5.11/install
    PMIX_DIR=$TMP_DIR/pmix/install

    $MUNGE_DIR/sbin/munged
    if [ pgrep munged ]; then
        MUNGE_PRELOAD=LD_PRELOAD=/usr/lib64/libmunge.so.2
    else
        MUNGE_PRELOAD=
        $MUNGE_DIR/bin/munge -n
        $MUNGE_DIR/bin/munge -n | $MUNGE_DIR/bin/unmunge
        $MUNGE_DIR/bin/remunge
    fi
    create_slurm_conf

    eval $MUNGE_PRELOAD $TARGET_DIR/sbin/slurmctld -Dcvvvvv > /dev/null 2>&1 &
    sleep 5
    eval $MUNGE_PRELOAD $TARGET_DIR/sbin/slurmd -Dcvvvvv > /dev/null 2>&1 &
    sleep 10

    cd $WORKSPACE
fi

if [ "$jenkins_test_check" = "yes" ]; then
    echo "Build checking"

    make $make_opt check || exit 12
fi

if [ "$jenkins_test_cov" = "yes" ]; then
    echo "Coverity checking"

    # make cov
    make $make_opt clean

    gh_cov_msg=$WORKSPACE/cov_gh_msg.txt
    cov_stat_tap=$WORKSPACE/cov_test.tap
    cov_url_webroot=${JOB_URL}/${BUILD_ID}/Coverity_Report

    set +e
    test_cov $WORKSPACE "slurm-pmix" "make $make_opt all" "TODO"
    if [ -n "$ghprbPullId" -a -f "$gh_cov_msg" ]; then
        echo "* Coverity report at $cov_url_webroot" >> $gh_cov_msg
        gh pr $ghprbPullId --comment "$(cat $gh_cov_msg)"
    fi
    set -e
fi

if [ "$jenkins_test_style" = "yes" ]; then
    echo "Coding style checking"

    cd $TMP_DIR
    wget  --no-check-certificate https://raw.githubusercontent.com/torvalds/linux/master/scripts/checkpatch.pl
    wget  --no-check-certificate https://github.com/torvalds/linux/blob/master/scripts/spelling.txt
    chmod +x checkpatch.pl

    style_tap=$WORKSPACE/style_test.tap
    rm -rf $style_tap
    check_files=$(find $WORKSPACE/src/plugins/mpi/pmix -name '*.c' -o -name '*.h')
    echo "1..$(echo $check_files | wc -w)" > $style_tap
    i=0
    for file in $check_files; do
        set +e
        eval checkpatch.pl --file --terse --no-tree $file
        ret=$?
        set -e
        i=$((i+1))
        if [ $ret -gt 0 ]; then
            echo "not ok $i $file" >> $style_tap
        else
            echo "ok $i $file" >> $style_tap
        fi
    done
fi

#
# JENKINS_RUN_TESTS should be set in jenkins slave node to indicate that node can run tests
#
if [ -n "$JENKINS_RUN_TESTS" ]; then
    echo "Coding style checking"

#    PARTITION=$(sinfo | grep `hostname | cut -d . -f 1` | cut -f1 -d' ')
    PARTITION=debug
    if [ ! -z $PARTITION ]; then
        PARTITION="-p${PARTITION}"
    fi

    cd $TMP_DIR

    run_tap=$WORKSPACE/run_test.tap
    rm -rf $run_tap

    echo "1..13" > $run_tap

    test_id=1
    # 1-sinfo
    test_exec="$MUNGE_PRELOAD $TARGET_DIR/bin/sinfo"
    check_result "sinfo" "$test_exec"

    # 2-legacy pmi2-hello
    gcc -Wall $WORKSPACE/contribs/pmi2/testpmi2.c -I$TARGET_DIR/include/slurm -L$TARGET_DIR/lib -lpmi2 -o ./pmi2-hello
    test_exec="$MUNGE_PRELOAD $TARGET_DIR/bin/srun ${PARTITION} --mpi=pmi2 ./pmi2-hello"
    check_result "legacy pmi2-hello" "$test_exec"

    # 3-using srun with pmix directly
    test_exec="$MUNGE_PRELOAD $TARGET_DIR/bin/srun ${PARTITION} -n1 --mpi=pmix hostname"
    check_result "using srun pmix" "$test_exec"

    # 4-using srun with pmix from allocation
    test_exec="$MUNGE_PRELOAD $TARGET_DIR/bin/salloc ${PARTITION} -n1 $MUNGE_PRELOAD $TARGET_DIR/bin/srun --mpi=pmix hostname"
    check_result "using srun pmix from allocation" "$test_exec"

    # 5-using srun with pmix for pmi1 app
    test_exec="env VERBOSE=3 $MUNGE_PRELOAD $TARGET_DIR/bin/srun ${PARTITION} -n2 --time=2 --mpi=pmix $PMIX_DIR/bin/pmi_client"
    check_result "using pmix for app/pmi1" "$test_exec"

    # 6-using srun with pmix for pmi2 app
    test_exec="env VERBOSE=3 $MUNGE_PRELOAD $TARGET_DIR/bin/srun ${PARTITION} -n2 --time=2 --mpi=pmix $PMIX_DIR/bin/pmi2_client"
    check_result "using pmix for app/pmi2" "$test_exec"

    # 7-blocking fence with data exchange among all processes from two namespaces:
    test_exec="$MUNGE_PRELOAD $TARGET_DIR/bin/srun ${PARTITION} -n2 --time=2 --mpi=pmix $PMIX_DIR/bin/pmix_client -n 2 --timeout 100 --ns-dist 3:1 --fence \"[db | 0:0-2;1:3]\""
    check_result "blocking fence w/ data all ti1" "$test_exec" "OK" 2

    # 8-blocking fence with data exchange among all processes from two namespaces:
    test_exec="$MUNGE_PRELOAD $TARGET_DIR/bin/srun ${PARTITION} -n2 --time=2 --mpi=pmix $PMIX_DIR/bin/pmix_client -n 2 --timeout 100 --ns-dist 3:1 --fence \"[db | 0:;1:3]\""
    check_result "blocking fence w/ data all ti2" "$test_exec" "OK" 2

    # 9-blocking fence with data exchange among all processes from two namespaces:
    test_exec="$MUNGE_PRELOAD $TARGET_DIR/bin/srun ${PARTITION} -n2 --time=2 --mpi=pmix $PMIX_DIR/bin/pmix_client -n 2 --timeout 100 --ns-dist 3:1 --fence \"[db | 0:;1:]\""
    check_result "blocking fence w/ data all ti3" "$test_exec" "OK" 2

    # 10-non-blocking fence without data exchange among processes from the 1st namespace
    test_exec="$MUNGE_PRELOAD $TARGET_DIR/bin/srun ${PARTITION} -n2 --time=2 --mpi=pmix $PMIX_DIR/bin/pmix_client -n 2 --timeout 100 --ns-dist 3:1 --fence \"[0:]\""
    check_result "non-blocking fence w/o data" "$test_exec" "OK" 2

    # 11-blocking fence without data exchange among processes from the 1st namespace
    test_exec="$MUNGE_PRELOAD $TARGET_DIR/bin/srun ${PARTITION} -n2 --time=2 --mpi=pmix $PMIX_DIR/bin/pmix_client -n 2 --timeout 100 --ns-dist 3:1 --fence \"[b | 0:]\""
    check_result "blocking fence w/ data" "$test_exec" "OK" 2

    # 12-non-blocking fence with data exchange among processes from the 1st namespace. Ranks 0, 1 from ns 0 are sleeping for 2 sec before doing fence test.
    test_exec="$MUNGE_PRELOAD $TARGET_DIR/bin/srun ${PARTITION} -n2 --time=2 --mpi=pmix $PMIX_DIR/bin/pmix_client -n 2 --timeout 100 --ns-dist 3:1 --fence \"[d | 0:]\" --noise \"[0:0,1]\""
    check_result "non-blocking fence w/ data" "$test_exec" "OK" 2

    # 13-blocking fence with data exchange across processes from the same namespace.
    test_exec="$MUNGE_PRELOAD $TARGET_DIR/bin/srun ${PARTITION} -n2 --time=2 --mpi=pmix $PMIX_DIR/bin/pmix_client -n 2 --timeout 100 --job-fence -c"
    check_result "blocking fence w/ data on the same nspace" "$test_exec" "OK" 2
fi

on_exit
