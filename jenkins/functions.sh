
# cov_stat_tap should be set
# gh_cov_msg should be set

function test_cov
{
    local cov_root_dir=$1
    local cov_proj=$2
    local cov_make_cmd=$3
    local cov_directive=$4

    local nerrors=0;

    module load tools/cov

    local cov_build_dir=$cov_root_dir/$cov_proj

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
            echo "<li><a href=${cov_proj}/output/errors/index.html>Report for ${cov_proj}</a>" >> $cov_root_dir/index.html
        fi
    else
        echo "not ok - coverity failed to run for $cov_proj # SKIP failed to init coverity" >> $cov_stat_tap
    fi

    module unload tools/cov

    return $nerrors
}

