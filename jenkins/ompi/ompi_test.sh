#!/bin/bash -eEl

set -u
set -o pipefail

if [ "$DEBUG" = "true" ]
then
    set -x
fi

# Check that you are inside a docker container
cat /proc/1/cgroup

if [ -z "$WORKSPACE" ]
then
    echo "WARNING: WORKSPACE is not defined"
    WORKSPACE="$PWD"
fi

cd "$WORKSPACE"
export PATH="/hpc/local/bin:/usr/local/bin:/bin:/usr/bin:/usr/sbin:${PATH}"

help_txt_list="${help_txt_list:="oshmem ompi/mca/coll/hcoll ompi/mca/pml/ucx ompi/mca/spml/ucx"}"
hca_port="${hca_port:=1}"
ci_test_build=${ci_test_build:="yes"}
ci_test_examples=${ci_test_examples:="yes"}
ci_test_oshmem=${ci_test_oshmem:="yes"}
ci_test_check=${ci_test_check:="yes"}
ci_test_threads=${ci_test_threads:="no"}
ci_test_use_ucx_branch=${ci_test_use_ucx_branch:="no"}
ci_test_ucx_branch=${ci_test_ucx_branch:="master"}
ci_test_hcoll=${ci_test_hcoll:="yes"}

# Ensure that we will cleanup all temp files
# even if the application will fail and won't
# do that itself
ci_session_base=$(mktemp -d)

function ci_cleanup {
    EXIT_CODE=$?
    echo "Script exited with code = ${EXIT_CODE}"
    rm -rf "${ci_session_base}"
    echo "rm -rf ... returned $?"

    if [ "${EXIT_CODE}" -eq 0 ]
    then
        echo "PASS"
    else
        echo "FAIL"
    fi

    exit ${EXIT_CODE}
}

trap ci_cleanup EXIT

EXECUTOR_NUMBER=${EXECUTOR_NUMBER:="none"}

if [ "${EXECUTOR_NUMBER}" != "none" ]
then
    AFFINITY_GLOB="taskset -c $(( 2 * EXECUTOR_NUMBER )),$(( 2 * EXECUTOR_NUMBER + 1))"
else
    AFFINITY_GLOB=""
fi

timeout_exe=${timout_exe:="${AFFINITY_GLOB} timeout -s SIGSEGV 17m"}
mpi_timeout="--report-state-on-timeout --get-stack-traces --timeout 900"

# global mpirun options
export OMPI_MCA_mpi_warn_on_fork="0"

OMPI_HOME="$WORKSPACE/ompi_install"
topdir="$WORKSPACE/rpms"

AUTOMAKE_JOBS=$(nproc)
export AUTOMAKE_JOBS

make_opt="-j$(nproc)"
rel_path=$(dirname "$0")
abs_path=$(readlink -f "${rel_path}")

if [ -d "${OMPI_HOME}" ]
then
    echo "WARNING: ${OMPI_HOME} already exists"
    ci_test_build="no"
    ci_test_check="no"
fi

echo "Running following tests:"
set | grep ci_test_

extra_conf=${extra_conf:=""}

if [ "${ci_test_threads}" = "yes" ]
then
    extra_conf="--enable-mpi-thread-multiple --enable-opal-multi-threads ${extra_conf}"
fi

function mpi_runner()
{
    AFFINITY=${AFFINITY_GLOB}

    if [ "$1" = "--no-bind" ]
    then
        AFFINITY=""
        shift
    fi

    local np="$1"
    local exe_path="$2"
    local exe_args="$3"
    local common_mca="--bind-to none"
    local mpirun="${OMPI_HOME}/bin/mpirun"
    common_mca="${common_mca} ${mpi_timeout}"

    if [ "${ci_test_hcoll}" = "no" ]
    then
        common_mca="${common_mca} --mca coll ^hcoll"
    fi

    local mca="${common_mca}"

    for hca_dev in $(ibstat -l)
    do
        if [ -f "${exe_path}" ]
        then
            local hca="${hca_dev}:${hca_port}"
            mca="${common_mca} -x UCX_NET_DEVICES=$hca"

            echo "Running ${exe_path} ${exe_args}"
            # shellcheck disable=SC2086
            ${timeout_exe} "$mpirun" --np "$np" $mca --mca pml ucx ${AFFINITY} "${exe_path}" "${exe_args}"
        fi
    done
}

function oshmem_runner()
{
    AFFINITY=${AFFINITY_GLOB}

    if [ "$1" = "--no-bind" ]
    then
        AFFINITY=""
        shift
    fi

    local np=$1
    local exe_path="$2"
    local exe_args=${3}
    local spml_ucx="--mca spml ucx"
    local oshrun="${OMPI_HOME}/bin/oshrun"
    local common_mca="--bind-to none -x SHMEM_SYMMETRIC_HEAP_SIZE=256M"
    common_mca="${common_mca} ${mpi_timeout}"

    if [ "${ci_test_hcoll}" = "no" ]
    then
        common_mca="${common_mca} --mca coll ^hcoll"
    fi

    local mca="$common_mca"

    "${OMPI_HOME}/bin/oshmem_info" -a -l 9

    for hca_dev in $(ibstat -l)
    do
        if [ -f "${exe_path}" ]
        then
            local hca="${hca_dev}:${hca_port}"
            mca="${common_mca}"
            mca="$mca -x UCX_NET_DEVICES=$hca"
            mca="$mca --mca rmaps_base_dist_hca $hca --mca sshmem_verbs_hca_name $hca"
            echo "Running ${exe_path} ${exe_args}"
            # shellcheck disable=SC2086
            ${timeout_exe} "$oshrun" --np "$np" $mca "${spml_ucx}" --mca pml ucx --mca btl ^vader,tcp,openib,uct ${AFFINITY} "${exe_path}" "${exe_args}"
        fi
    done
}

function on_start()
{
    echo "Starting on host: $(hostname)"

    export distro_name
    distro_name=$(python -c 'import platform ; print platform.dist()[0]' | tr '[:upper:]' '[:lower:]')

    export distro_ver
    distro_ver=$(python  -c 'import platform ; print platform.dist()[1]' | tr '[:upper:]' '[:lower:]')

    if [ "${distro_name}" = "suse" ]
    then
        patch_level=$(grep -E PATCHLEVEL /etc/SuSE-release | cut -f2 -d= | sed -e "s/ //g")
        if [ -n "${patch_level}" ]
        then
            export distro_ver="${distro_ver}.${patch_level}"
        fi
    fi

    echo "${distro_name} -- ${distro_ver}"

    # save current environment to support debugging
    env | sed -ne "s/\(\w*\)=\(.*\)\$/export \1='\2'/p" > "$WORKSPACE/test_env.sh"
    chmod 755 "$WORKSPACE/test_env.sh"
}

function on_exit
{
    rc=$((rc + $?))
    echo exit code=$rc
    if [ $rc -ne 0 ]
    then
        # TODO: when rpmbuild fails, it leaves folders w/o any permissions even for owner
        # removing of such files may fail
        find "$topdir" -type d -exec chmod +x {} \;
    fi
}

function test_tune()
{
    echo "check if mca_base_env_list parameter is supported in ${OMPI_HOME}"
    val=$("${OMPI_HOME}/bin/ompi_info" --param mca base --level 9 | grep --count mca_base_env_list || true)
    val=0 #disable all mca_base_env_list tests until ompi schizo is fixed

    mca="--mca pml ucx --mca btl ^vader,tcp,openib,uct"

    if [ "$val" -gt 0 ]
    then
        #TODO disabled, need to re-visit for Open MPI 5.x
        #echo "test mca_base_env_list option in ${OMPI_HOME}"
        #export XXX_C=3 XXX_D=4 XXX_E=5
        ## shellcheck disable=SC2086
        #val=$("${OMPI_HOME}/bin/mpirun" $mca --np 2 --mca mca_base_env_list 'XXX_A=1;XXX_B=2;XXX_C;XXX_D;XXX_E' env | grep --count ^XXX_ || true)
        #if [ "$val" -ne 10 ]
        #then
        #    exit 1
        #fi

        # check amca param
        echo "mca_base_env_list=XXX_A=1;XXX_B=2;XXX_C;XXX_D;XXX_E" > "$WORKSPACE/test_amca.conf"
        # shellcheck disable=SC2086
        val=$("${OMPI_HOME}/bin/mpirun" $mca --np 2 --tune "$WORKSPACE/test_amca.conf" "${abs_path}/env_mpi" |grep --count ^XXX_ || true)
        if [ "$val" -ne 10 ]
        then
            exit 1
        fi
    fi

    # testing -tune option (mca_base_envar_file_prefix mca parameter) which supports setting both mca and env vars
    echo "check if mca_base_envar_file_prefix parameter (a.k.a -tune cmd line option) is supported in ${OMPI_HOME}"
    val=$("${OMPI_HOME}/bin/ompi_info" --param mca base --level 9 | grep --count mca_base_envar_file_prefix || true)
    val=0 #disable all mca_base_env_list tests until ompi schizo is fixed
    if [ "$val" -gt 0 ]
    then
        echo "test -tune option in ${OMPI_HOME}"
        echo "-x XXX_A=1 -x XXX_B=2 -x XXX_C -x XXX_D -x XXX_E" > "$WORKSPACE/test_tune.conf"
        # next line with magic sed operation does the following:
        # 1. cut all patterns XXX_.*= from the begining of each line, only values of env vars remain.
        # 2. replace \n by + at each line
        # 3. sum all values of env vars with given pattern.
        # shellcheck disable=SC2086
        val=$("${OMPI_HOME}/bin/mpirun" $mca --np 2 --tune "$WORKSPACE/test_tune.conf" -x XXX_A=6 "${abs_path}/env_mpi" | sed -n -e 's/^XXX_.*=//p' | sed -e ':a;N;$!ba;s/\n/+/g' | bc)
        # precedence goes left-to-right.
        # A is set to 1 in "tune" and then reset to 6 with the -x option
        # B is set to 2 in "tune"
        # C, D, E are taken from the environment as 3,4,5
        # return (6+2+3+4+5)*2=40
        if [ "$val" -ne 40 ]
        then
            exit 1
        fi

        echo "--mca mca_base_env_list \"XXX_A=1;XXX_B=2;XXX_C;XXX_D;XXX_E\"" > "$WORKSPACE/test_tune.conf"
        # shellcheck disable=SC2086
        val=$("${OMPI_HOME}/bin/mpirun" $mca --np 2 --tune "$WORKSPACE/test_tune.conf" "${abs_path}/env_mpi" | sed -n -e 's/^XXX_.*=//p' | sed -e ':a;N;$!ba;s/\n/+/g' | bc)
        # precedence goes left-to-right.
        # A is set to 1 in "tune"
        # B is set to 2 in "tune"
        # C, D, E are taken from the environment as 3,4,5
        # return (1+2+3+4+5)*2=30
        if [ "$val" -ne 30 ]
        then
            exit 1
        fi

        echo "--mca mca_base_env_list \"XXX_A=1;XXX_B=2;XXX_C;XXX_D;XXX_E\"" > "$WORKSPACE/test_tune.conf"
        # shellcheck disable=SC2086
        val=$("${OMPI_HOME}/bin/mpirun" $mca -np 2 --tune "$WORKSPACE/test_tune.conf" --mca mca_base_env_list \
            "XXX_A=7;XXX_B=8" "${abs_path}/env_mpi" | sed -n -e 's/^XXX_.*=//p' | sed -e ':a;N;$!ba;s/\n/+/g' | bc)
        # precedence goes left-to-right.
        # A is set to 1 in "tune", and then reset to 7 in the --mca parameter
        # B is set to 2 in "tune", and then reset to 8 in the --mca parameter
        # C, D, E are taken from the environment as 3,4,5
        # return (7+8+3+4+5)*2=54
        if [ "$val" -ne 54 ]
        then
            exit 1
        fi

        # echo "--mca mca_base_env_list \"XXX_A=1;XXX_B=2;XXX_C;XXX_D;XXX_E\"" > "$WORKSPACE/test_tune.conf"
        # echo "mca_base_env_list=XXX_A=7;XXX_B=8" > "$WORKSPACE/test_amca.conf"
        # A is first set to 1 in "tune", and then reset to 7 in "amca".  <==== this is NOT allowed
        # B is first set to 2 in "tune", but then reset to 8 in "amca"   <==== this is NOT allowed
        #
        # REPLACEMENT:
        # A is set to 7 in "tune"
        # B is set to 8 in "amca"
        # C, D, E are taken from the environment as 3,4,5
        # return (7+8+3+4+5)*2=54
        echo "--mca mca_base_env_list \"XXX_A=7;XXX_C;XXX_D;XXX_E\"" > "$WORKSPACE/test_tune.conf"
        echo "mca_base_env_list=XXX_B=8" > "$WORKSPACE/test_amca.conf"
        # shellcheck disable=SC2086
        val=$("${OMPI_HOME}/bin/mpirun" $mca --np 2 --tune "$WORKSPACE/test_tune.conf" \
            --am "$WORKSPACE/test_amca.conf" "${abs_path}/env_mpi" | sed -n -e 's/^XXX_.*=//p' | sed -e ':a;N;$!ba;s/\n/+/g' | bc)
        if [ "$val" -ne 54 ]
        then
            exit 1
        fi

        # echo "--mca mca_base_env_list \"XXX_A=1;XXX_B=2;XXX_C;XXX_D;XXX_E\"" > "$WORKSPACE/test_tune.conf"
        # echo "mca_base_env_list=XXX_A=7;XXX_B=8" > "$WORKSPACE/test_amca.conf"
        # A is first set to 1 in "tune", and then reset to 7 by "amca".  <==== this is NOT allowed
        # B is first set to 2 in "tune", but then reset to 8 in "amca"   <==== this is NOT allowed
        #
        # REPLACEMENT:
        # A is set to 7 in "tune", and then reset to 9 on the cmd line
        # B is set to 8 in "amca", and then reset to 10 on the cmd line
        # C, D, E are taken from the environment as 3,4,5
        #
        # shellcheck disable=SC2086
        echo "--mca mca_base_env_list \"XXX_A=7;XXX_C;XXX_D;XXX_E\"" > "$WORKSPACE/test_tune.conf"
        echo "mca_base_env_list=XXX_B=8" > "$WORKSPACE/test_amca.conf"
        val=$("${OMPI_HOME}/bin/mpirun" $mca --np 2 --tune "$WORKSPACE/test_tune.conf" --am "$WORKSPACE/test_amca.conf" \
            --mca mca_base_env_list "XXX_A=9;XXX_B=10" "${abs_path}/env_mpi" | sed -n -e 's/^XXX_.*=//p' | sed -e ':a;N;$!ba;s/\n/+/g' | bc)
        # return (9+10+3+4+5)*2=62
        if [ "$val" -ne 62 ]
        then
            exit 1
        fi

        echo "-x XXX_A=6 -x XXX_C=7 -x XXX_D=8" > "$WORKSPACE/test_tune.conf"
        echo "-x XXX_B=9 -x XXX_E" > "$WORKSPACE/test_tune2.conf"
        # shellcheck disable=SC2086
        val=$("${OMPI_HOME}/bin/mpirun" $mca --np 2 --tune "$WORKSPACE/test_tune.conf,$WORKSPACE/test_tune2.conf" \
            "${abs_path}/env_mpi" | sed -n -e 's/^XXX_.*=//p' | sed -e ':a;N;$!ba;s/\n/+/g' | bc)
        # precedence goes left-to-right.
        # A is set to 6 in "tune"
        # B is set to 9 in "tune2"
        # C is set to 7 in "tune"
        # D is set to 8 in "tune"
        # E is taken from the environment as 5
        # return (6+9+7+8+5)*2=70
        if [ "$val" -ne 70 ]
        then
            exit 1
        fi
    fi
}

trap "on_exit" INT TERM ILL FPE SEGV ALRM

on_start

if [ "${ci_test_build}" = "yes" ]
then
    echo "Building Open MPI..."

    if [ -x "autogen.sh" ]
    then
        autogen_script="./autogen.sh"
    else
        autogen_script="./autogen.pl"
    fi

    # control mellanox platform file, select various configure flags
    export mellanox_autodetect="yes"
    export mellanox_debug="yes"

    configure_args="--with-platform=contrib/platform/mellanox/optimized --with-ompi-param-check --enable-picky ${extra_conf}"

    module load hpcx-gcc-stack

    if [ "${ci_test_use_ucx_branch}" = "yes" ]
    then
        export ucx_root="$WORKSPACE/ucx_local"
        git clone https://github.com/openucx/ucx -b ${ci_test_ucx_branch} "${ucx_root}"
        (cd "${ucx_root}";\
            ./autogen.sh;\
            ./contrib/configure-release --prefix="${ucx_root}/install";\
            make -j"$(nproc)" install; )
       export UCX_DIR=$ucx_root/install

       # We need to override LD_LIBRARY_PATH because.
       # `module load hpcx-gcc-stack` will pull the legacy
       # UCX files that will interfere with our custom-built
       # UCX during configuration and the runtime I guess
       export LD_LIBRARY_PATH="${HPCX_UCX_DIR}/lib:${LD_LIBRARY_PATH}"
    fi

    export ucx_dir=${HPCX_UCX_DIR}

    # build ompi
    ${autogen_script}
    echo "./configure ${configure_args} --prefix=${OMPI_HOME}" | bash -xeE
    make "${make_opt}" install

    # make check
    if [ "${ci_test_check}" = "yes" ]
    then
        make "${make_opt}" check || exit 12
    fi
fi

if [ "${ci_test_examples}" = "yes" ]
then
    exe_dir="${OMPI_HOME}/examples"

    if [ ! -d "${exe_dir}" ]
    then
        echo "Running examples for ${OMPI_HOME}"
        cp -prf "${WORKSPACE}/examples" "${OMPI_HOME}"
        (
            PATH="${OMPI_HOME}/bin:$PATH" LD_LIBRARY_PATH="${OMPI_HOME}/lib:${LD_LIBRARY_PATH}" make -C "${exe_dir}" all
        )
    fi

    for exe in hello_c ring_c
    do
        exe_path="${exe_dir}/$exe"
        (
            set +u
            PATH="${OMPI_HOME}/bin:$PATH" LD_LIBRARY_PATH="${OMPI_HOME}/lib:${LD_LIBRARY_PATH}" mpi_runner 4 "${exe_path}"
            set -u
        )
    done

    if [ "${ci_test_oshmem}" = "yes" ]
    then
        for exe in hello_oshmem oshmem_circular_shift oshmem_shmalloc oshmem_strided_puts oshmem_symmetric_data
        do
            exe_path="${exe_dir}/$exe"
            (
                set +u
                PATH="${OMPI_HOME}/bin:$PATH" LD_LIBRARY_PATH="${OMPI_HOME}/lib:${LD_LIBRARY_PATH}" oshmem_runner 4 "${exe_path}"
                set -u
            )
        done

        if [ "$(command -v clang)" ]
        then
            if [ -f "${OMPI_HOME}/include/pshmem.h" ]
            then
                pshmem_def="-DENABLE_PSHMEM"
            fi

            clang "${abs_path}/c11_test.c" -std=c11 ${pshmem_def} -o /tmp/c11_test -I"${OMPI_HOME}/include" \
                -L"${OMPI_HOME}/lib" -loshmem
        fi
    fi
fi

if [ "${ci_test_threads}" = "yes" ]
then
    ci_test_hcoll_bkp="${ci_test_hcoll}"
    exe_dir="${OMPI_HOME}/thread_tests"

    if [ ! -d "${exe_dir}" ]
    then
        pushd .
        mkdir -p "${exe_dir}"
        cd "${exe_dir}"

        # Keep this test locally to avoid future connection problems
        #wget --no-check-certificate http://www.mcs.anl.gov/~thakur/thread-tests/thread-tests-1.1.tar.gz
        cp /hpc/local/mpitests/thread-tests-1.1.tar.gz .
        tar zxf thread-tests-1.1.tar.gz
        cd thread-tests-1.1
        make CC="${OMPI_HOME}/bin/mpicc"
        popd
    fi

    # Disable HCOLL for the MT case
    ci_test_hcoll="no"

    for exe in overlap latency
    do
        exe_path="${exe_dir}/thread-tests-1.1/$exe"
        (
            set +u
            PATH="${OMPI_HOME}/bin:$PATH" LD_LIBRARY_PATH="${OMPI_HOME}/lib:${LD_LIBRARY_PATH}" mpi_runner --no-bind 4 "${exe_path}"
            set -u
        )
    done

    for exe in latency_th bw_th message_rate_th
    do
        exe_path="${exe_dir}/thread-tests-1.1/$exe"
        (
            set +u
            PATH="${OMPI_HOME}/bin:$PATH" LD_LIBRARY_PATH="${OMPI_HOME}/lib:${LD_LIBRARY_PATH}" mpi_runner --no-bind 2 "${exe_path}" 4
            set -u
        )
    done

    ci_test_hcoll="${ci_test_hcoll_bkp}"
fi

for mpit in "${abs_path}"/*.c
do
    out_name="$(basename "$mpit" .c)"
    "${OMPI_HOME}/bin/mpicc" -o "${abs_path}/${out_name}" "$mpit"
done

test_tune
