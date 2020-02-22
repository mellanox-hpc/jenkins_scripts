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
ci_test_src_rpm=${ci_test_src_rpm:="no"}
ci_test_help_txt=${ci_test_help_txt:="no"}
ci_test_threads=${ci_test_threads:="yes"}
ci_test_cov=${ci_test_cov:="no"}
ci_test_known_issues=${ci_test_known_issues:="no"}
ci_test_debug=${ci_test_debug:="no"}
ci_test_slurm=${ci_test_slurm:="no"}
ci_test_comments=${ci_test_comments:="no"}
ci_test_ucx=${ci_test_ucx:="yes"}
ci_test_vg="no"
ci_test_xrc="no"
ci_test_use_ucx_branch=${ci_test_use_ucx_branch:="no"}
ci_test_ucx_branch=${ci_test_ucx_branch:="master"}
ci_test_hcoll="yes"

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

export OMPI_MCA_orte_tmpdir_base="${ci_session_base}"

EXECUTOR_NUMBER=${EXECUTOR_NUMBER:="none"}

if [ "${EXECUTOR_NUMBER}" != "none" ]
then
    AFFINITY_GLOB="taskset -c $(( 2 * EXECUTOR_NUMBER )),$(( 2 * EXECUTOR_NUMBER + 1))"
else
    AFFINITY_GLOB=""
fi

if [ ! -d "$WORKSPACE/ompi/mca/pml/ucx" ]
then
    ci_test_ucx="no"
fi

timeout_exe=${timout_exe:="${AFFINITY_GLOB} timeout -s SIGSEGV 17m"}
mpi_timeout="--report-state-on-timeout --get-stack-traces --timeout 900"

# internal flags to select/unselect OMPI transports used in test
btl_tcp="${btl_tcp:="yes"}"
btl_sm="${btl_sm:="yes"}"
btl_openib="${btl_openib:="yes"}"
btl_vader="${btl_vader:="yes"}"
btl_sm="no"
btl_tcp_bkp="${btl_tcp}"
btl_sm_bkp="${btl_sm}"
btl_openib_bkp="${btl_openib}"
btl_vader_bkp="${btl_vader}"

# TAP directive for MLNX modules in coverity
# empty - treat errors as failures
# can be TODO, SKIP
mlnx_cov="SKIP"

# indicate to coverity which files to exclude from report
cov_exclude_file_list="oshmem/mca/memheap/ptmalloc/malloc.c"

# global mpirun options
export OMPI_MCA_mpi_warn_on_fork="0"
export OMPI_MCA_btl_openib_warn_default_gid_prefix="0"

# exclude hwloc external package
if [ -d "opal/mca/hwloc/hwloc" ]
then
    # shellcheck disable=SC2044
    for excl in $(find opal/mca/hwloc/hwloc* -type f -name "*.[ch]")
    do
        cov_exclude_file_list="${cov_exclude_file_list} $excl"
    done
fi

gh_cov_msg="$WORKSPACE/cov_file.txt"
OMPI_HOME1="$WORKSPACE/ompi_install1"
ompi_home_list="${OMPI_HOME1}"
topdir="$WORKSPACE/rpms"
tarball_dir="$WORKSPACE/tarball"
check_help_exe="$WORKSPACE/contrib/check-help-strings.pl"

make_opt="-j$(nproc)"
rel_path=$(dirname "$0")
abs_path=$(readlink -f "${rel_path}")

if [ "${ci_test_debug}" = "no" ]
then
    ci_test_threads="yes"
    ci_test_oshmem="yes"
    ci_test_src_rpm="no"
    mlnx_cov="SKIP"
else
    ci_test_build="yes"
    ci_test_examples="yes"
    ci_test_oshmem="yes"
    ci_test_ucx="yes"
    ci_test_vg="yes"
    ci_test_check="no"
    ci_test_src_rpm="no"
    ci_test_help_txt="no"
    ci_test_threads=""
    ci_test_cov="no"
    ci_test_known_issues="no"
    ci_test_slurm="no"
    ci_test_comments="no"
fi

if [ -d "${OMPI_HOME1}" ]
then
    echo "WARNING: ${OMPI_HOME1} already exists"
    ci_test_build="no"
    ci_test_cov="no"
    ci_test_check="no"
    ci_test_src_rpm="no"
    ci_build_passed="1"
fi

echo "Running following tests:"
set | grep ci_test_

extra_conf=${extra_conf:=""}

if [ "${ci_test_threads}" = "yes" ]
then
    extra_conf="--enable-mpi-thread-multiple --enable-opal-multi-threads ${extra_conf}"
fi

if [ "${ci_test_slurm}" = "yes" ]
then
    extra_conf="--with-slurm --with-pmi ${extra_conf}"
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
    local common_mca="--bind-to none --mca orte_tmpdir_base ${ci_session_base}"
    local mpirun="${OMPI_HOME}/bin/mpirun"
    local has_timeout
    has_timeout=$("${OMPI_HOME}/bin/mpirun" --help | grep --count timeout || true)

    if [ "${has_timeout}" = "0" ]
    then
        # Help in newer versions was changed
        has_timeout=$("${OMPI_HOME}/bin/mpirun" --help debug 2>/dev/null | grep --count timeout || true)
    fi

    if [ "${has_timeout}" -gt 0 ]
    then
        # We leave external timeout just in case the internal one is broken
        common_mca="${common_mca} ${mpi_timeout}"
    fi

    if [ "${ci_test_hcoll}" = "no" ]
    then
        common_mca="${common_mca} --mca coll ^hcoll"
    fi

    local mca="${common_mca}"

    if [ "${btl_tcp}" = "yes" ]
    then
        # shellcheck disable=SC2086
        ${timeout_exe} "$mpirun" --np "$np" $mca --mca pml ob1 --mca btl self,tcp ${AFFINITY} "${exe_path}" "${exe_args}"
    fi

    if [ "${btl_sm}" = "yes" ]
    then
        # shellcheck disable=SC2086
        ${timeout_exe} "$mpirun" --np "$np" $mca --mca pml ob1 --mca btl self,sm ${AFFINITY} "${exe_path}" "${exe_args}"
    fi

    if [ "${btl_vader}" = "yes" ]
    then
        # shellcheck disable=SC2086
        ${timeout_exe} "$mpirun" --np "$np" $mca --mca pml ob1 --mca btl self,vader ${AFFINITY} "${exe_path}" "${exe_args}"
    fi

    local has_ucx
    local has_btl_openib
    has_ucx=$("${OMPI_HOME}/bin/ompi_info" --param pml all --level 9 | grep --count ucx || true)
    has_btl_openib=$("${OMPI_HOME}/bin/ompi_info" --param btl all | grep --count openib || true)

    for hca_dev in $(ibstat -l)
    do
        if [ -f "${exe_path}" ]
        then
            local hca="${hca_dev}:${hca_port}"
            mca="${common_mca} --mca btl_openib_if_include $hca -x UCX_NET_DEVICES=$hca --mca btl_openib_allow_ib true"

            echo "Running ${exe_path} ${exe_args}"

            if [ "${has_btl_openib}" -gt 0 ] && [ "${btl_openib}" = "yes" ]
            then
                # shellcheck disable=SC2086
                ${timeout_exe} "$mpirun" --np "$np" $mca --mca pml ob1 --mca btl self,openib ${AFFINITY} "${exe_path}" "${exe_args}"

                if [ "${ci_test_xrc}" = "yes" ]
                then
                    # shellcheck disable=SC2086
                    ${timeout_exe} "$mpirun" --np "$np" $mca --mca pml ob1 --mca btl self,openib --mca btl_openib_receive_queues X,4096,1024:X,12288,512:X,65536,512 \
                        ${AFFINITY} "${exe_path}" "${exe_args}"
                fi
            fi

            if [ "${ci_test_ucx}" = "yes" ] && [ "${has_ucx}" -gt 0 ] && [ "${hca_dev}" != "mlx4_0" ]
            then
                # shellcheck disable=SC2086
                ${timeout_exe} "$mpirun" --np "$np" $mca --mca btl self --mca pml ucx ${AFFINITY} "${exe_path}" "${exe_args}"
            fi
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
    local common_mca="--bind-to none -x SHMEM_SYMMETRIC_HEAP_SIZE=256M --mca orte_tmpdir_base ${ci_session_base}"

    local has_ucx
    has_ucx=$("${OMPI_HOME}/bin/ompi_info" --param pml all --level 9 | grep --count ucx || true)

    local has_timeout
    has_timeout=$("${OMPI_HOME}/bin/mpirun" --help | grep --count timeout || true)

    if [ "${has_timeout}" = "0" ]
    then
        # Help in newer versions was changed
        has_timeout=$("${OMPI_HOME}/bin/mpirun" --help debug 2>/dev/null | grep --count timeout || true)
    fi

    if [ "${has_timeout}" -gt 0 ]
    then
        # We leave external timeout just in case the internal one is broken
        common_mca="${common_mca} ${mpi_timeout}"
    fi

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
            mca="$mca --mca btl_openib_if_include $hca -x UCX_NET_DEVICES=$hca"
            mca="$mca --mca rmaps_base_dist_hca $hca --mca sshmem_verbs_hca_name $hca"
            echo "Running ${exe_path} ${exe_args}"

            if [ "${ci_test_ucx}" = "yes" ] && [ "${has_ucx}" -gt 0 ] && [ "${hca_dev}" != "mlx4_0" ]
            then
                # shellcheck disable=SC2086
                ${timeout_exe} "$oshrun" --np "$np" $mca "${spml_ucx}" --mca pml ucx --mca btl self ${AFFINITY} "${exe_path}" "${exe_args}"
            fi
        fi
    done
}

function slurm_runner()
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

    command -v srun >/dev/null 2>&1 || { echo "srun is not found."; exit 1; }

    # check PMI1
    ${timeout_exe} srun -p pj1 -n "$np" env OMPI_MCA_pml=ucx ${AFFINITY} "${exe_path}" "${exe_args}"

    # check PMI2
    ${timeout_exe} srun -p pj1 -n "$np" --mpi=pmi2 env OMPI_MCA_pml=ucx ${AFFINITY} "${exe_path}" "${exe_args}"
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

function test_cov
{
    local cov_root_dir="$1"
    local cov_proj="$2"
    local cov_make_cmd="$3"
    local cov_directive="$4"
    local nerrors="0"

    module load tools/cov

    local cov_build_dir="${cov_root_dir}/${cov_proj}"

    rm -rf "${cov_build_dir}"
    cov-build --dir "${cov_build_dir}" "${cov_make_cmd}"

    for excl in ${cov_exclude_file_list}
    do
        cov-manage-emit --dir "${cov_build_dir}" --tu-pattern "file('$excl')" delete
    done

    cov-analyze --dir "${cov_build_dir}"
    nerrors=$(cov-format-errors --dir "${cov_build_dir}" | awk '/Processing [0-9]+ errors?/ { print $2 }')

    if [ -n "$nerrors" ]
    then
        if [ "$nerrors" = "0" ]
        then
            echo "ok - coverity found no issues for ${cov_proj}" >> "${cov_stat_tap}"
        else
            echo "not ok - coverity detected $nerrors failures in ${cov_proj} # ${cov_directive}" >> "${cov_stat_tap}"
            local cov_proj_disp
            cov_proj_disp="$(echo "${cov_proj}" | cut -f1 -d_)"
            echo "" >> "${gh_cov_msg}"
            echo "* Coverity found $nerrors errors for ${cov_proj_disp}" >> "${gh_cov_msg}"
            echo "<li><a href=${cov_proj}/output/errors/index.html>Report for ${cov_proj}</a>" >> "${cov_root_dir}/index.html"
        fi
    else
        echo "not ok - coverity failed to run for ${cov_proj} # SKIP failed to init coverity" >> "${cov_stat_tap}"
    fi

    module unload tools/cov

    return "$nerrors"
}

function test_tune()
{
    echo "check if mca_base_env_list parameter is supported in ${OMPI_HOME}"
    val=$("${OMPI_HOME}/bin/ompi_info" --param mca base --level 9 | grep --count mca_base_env_list || true)

    mca="--mca pml ob1 --mca btl self,vader"

    if [ "$val" -gt 0 ]
    then
        echo "test mca_base_env_list option in ${OMPI_HOME}"
        export XXX_C=3 XXX_D=4 XXX_E=5
        # shellcheck disable=SC2086
        val=$("${OMPI_HOME}/bin/mpirun" $mca --np 2 --mca mca_base_env_list 'XXX_A=1;XXX_B=2;XXX_C;XXX_D;XXX_E' env | grep --count ^XXX_ || true)
        if [ "$val" -ne 10 ]
        then
            exit 1
        fi

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

        echo "--mca mca_base_env_list \"XXX_A=1;XXX_B=2;XXX_C;XXX_D;XXX_E\"" > "$WORKSPACE/test_tune.conf"
        echo "mca_base_env_list=XXX_A=7;XXX_B=8" > "$WORKSPACE/test_amca.conf"
        # shellcheck disable=SC2086
        val=$("${OMPI_HOME}/bin/mpirun" $mca --np 2 --tune "$WORKSPACE/test_tune.conf" \
            --am "$WORKSPACE/test_amca.conf" "${abs_path}/env_mpi" | sed -n -e 's/^XXX_.*=//p' | sed -e ':a;N;$!ba;s/\n/+/g' | bc)
        # precedence goes left-to-right.
        # A is first set to 1 in "tune", and then reset to 7 in "amca".
        # B is first set to 2 in "tune", but then reset to 8 in "amca"
        # C, D, E are taken from the environment as 3,4,5
        # return (7+8+3+4+5)*2=54
        if [ "$val" -ne 54 ]
        then
            exit 1
        fi

        echo "--mca mca_base_env_list \"XXX_A=1;XXX_B=2;XXX_C;XXX_D;XXX_E\"" > "$WORKSPACE/test_tune.conf"
        echo "mca_base_env_list=XXX_A=7;XXX_B=8" > "$WORKSPACE/test_amca.conf"
        # shellcheck disable=SC2086
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

    if [ "${ci_test_ucx}" = "yes" ]
    then
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
    fi

    rm -rf "${ompi_home_list}"

    # build ompi
    ${autogen_script}
    echo "./configure ${configure_args} --prefix=${OMPI_HOME1}" | bash -xeE
    make "${make_opt}" install
    ci_build_passed=1

    # make check
    if [ "${ci_test_check}" = "yes" ]
    then
        make "${make_opt}" check || exit 12
    fi
fi

if [ -n "${ci_build_passed}" ]
then
    # check coverity
    if [ "${ci_test_cov}" = "yes" ]
    then
        vpath_dir="$WORKSPACE"
        cov_proj="all oshmem ompi/mca/coll/hcoll"

        if [ "${ci_test_ucx}" = "yes" ]
        then
            cov_proj="${cov_proj} ompi/mca/pml/ucx"
        fi

        cov_stat="${vpath_dir}/cov_stat.txt"
        cov_stat_tap="${vpath_dir}/cov_stat.tap"
        cov_build_dir="${vpath_dir}/cov_build"

        rm -f "${cov_stat}" "${cov_stat_tap}"

        if [ -d "${vpath_dir}" ]
        then
            mkdir -p "${cov_build_dir}"
            pushd "${vpath_dir}"

            for dir in ${cov_proj}
            do
                if [ "$dir" = "all" ]
                then
                    make_cov_opt=""
                    cov_directive="SKIP"
                else
                    if [ ! -d "$dir" ]
                    then
                        continue
                    fi

                    cov_directive=${mlnx_cov}
                    make_cov_opt="-C $dir"
                fi

                echo "Working on $dir"

                cov_proj=$(basename "$dir")
                set +eE
                make "${make_cov_opt}" "${make_opt}" clean >/dev/null 2>&1
                test_cov "${cov_build_dir}" "${cov_proj}" "make ${make_cov_opt} ${make_opt} all" ${cov_directive}
                set -eE
            done

            echo "INFO: Coverity scan status:"
            cat "${cov_stat_tap}"
            popd
        fi
    fi
fi

if [ "${ci_test_src_rpm}" = "yes" ]
then
    # check distclean
    make "${make_opt}" distclean
    ${autogen_script}
    echo "./configure ${configure_args} --prefix=${OMPI_HOME1}" | bash -xeE || exit 11

    if [ -x /usr/bin/dpkg-buildpackage ]
    then
        echo "Building Open MPI on debian"
        # debian is here - run and hide
        build_debian="contrib/dist/mofed/compile_debian_mlnx_example"

        if [ -x ${build_debian} ]
        then
            ${build_debian}
        fi
    else
        echo "Building Open MPI src.rpm"
        rm -rf "${tarball_dir}"
        mkdir -p "${tarball_dir}"

        make_dist_args="--highok --distdir ${tarball_dir} --greekonly"

        for arg in no-git-update dirtyok verok
        do
            if grep $arg contrib/dist/make_tarball >/dev/null 2>&1
            then
                make_dist_args="${make_dist_args} --${arg}"
            fi
        done

        # ugly hack, make_tarball has hardcoded "-j32" and sometimes it fails on some race
        sed -i -e s,-j32,-j8,g contrib/dist/make_tarball

        chmod +x ./contrib/dist/make* ./contrib/dist/linux/buildrpm.sh
        echo "contrib/dist/make_tarball ${make_dist_args}" | bash -xeE || exit 11

        # build src.rpm
        # shellcheck disable=SC2012
        tarball_src=$(ls -1 "${tarball_dir}"/openmpi-*.tar.bz2 | sort -r | head -1)

        echo "Building Open MPI bin.rpm"
        rpm_flags="--define 'mflags -j8' --define '_source_filedigest_algorithm md5' --define '_binary_filedigest_algorithm md5'"
        (
            cd ./contrib/dist/linux && env rpmbuild_options="${rpm_flags}" rpmtopdir="$topdir" ./buildrpm.sh "${tarball_src}"
        )
    fi
fi

if [ "${ci_test_help_txt}" = "yes" ]
then
    if [ -f "${check_help_exe}" ]
    then
        echo "Checking help strings"

        for dir in ${help_txt_list}
        do
            if [ -d "$dir" ]
            then
                (cd "$dir" && ${check_help_exe} .)
            fi
        done
    fi
fi

for OMPI_HOME in ${ompi_home_list}
do
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
            # launch using slurm launcher in case mpi is configured with pmi support
            if [ "${ci_test_slurm}" = "yes" ]
            then
                (
                    slurm_runner 2 "${exe_path}"
                )
            fi
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

        # disabling btls which known to fail with threads
        if [ "${ci_test_known_issues}" = "no" ]
        then
            btl_tcp="no"
            btl_vader="no"
        fi

        btl_sm="no"
        ci_test_ucx_bak="${ci_test_ucx}"
        ci_test_ucx="no"

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

        ci_test_ucx="${ci_test_ucx_bak}"
        ci_test_hcoll="${ci_test_hcoll_bkp}"
        btl_openib="${btl_openib_bkp}"
        btl_tcp="${btl_tcp_bkp}"
        btl_sm="${btl_sm_bkp}"
        btl_vader="${btl_vader_bkp}"
    fi

    if [ "${ci_test_vg}" = "yes" ]
    then
        module load dev/mofed_valgrind
        module load tools/valgrind
        module load hpcx-gcc-stack

        exe_dir="${OMPI_HOME}/examples"
        vg_opt="--suppressions=${OMPI_HOME}/share/openmpi/openmpi-valgrind.supp --suppressions=${abs_path}/vg.supp --error-exitcode=3 --track-origins=yes -q"
        mpi_opt="--mca coll ^hcoll --np 1"

        mpi_exe="${OMPI_HOME}/examples/hello_c"

        PATH="${OMPI_HOME}/bin:$PATH"
        LD_LIBRARY_PATH="${OMPI_HOME}/lib:${LD_LIBRARY_PATH}"

        mpirun="${OMPI_HOME}/bin/mpirun"
        oshrun="${OMPI_HOME}/bin/oshrun"

        $mpirun "${mpi_opt}" --mca pml ob1 --mca btl self,vader valgrind "${vg_opt}" "${mpi_exe}"

        module unload dev/mofed_valgrind
        module unload tools/valgrind
        module unload hpcx-gcc-stack
    fi
done

for mpit in "${abs_path}"/*.c
do
    out_name="$(basename "$mpit" .c)"
    "${OMPI_HOME}/bin/mpicc" -o "${abs_path}/${out_name}" "$mpit"
done

for OMPI_HOME in ${ompi_home_list}
do
    test_tune
done
