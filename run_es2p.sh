# export ROOT_DIR=/media/share/panda/panda2
export STATIC_ROOT_DIR=${ROOT_DIR}/runtime_core/static_core


export NODE_TLS_REJECT_UNAUTHORIZED=0

compiler_log=false
ninja_build=false
keep_logs=false
debug=false
device=false
flaky=""
build_dir=""
tests=()

while [[ $# -gt 0 ]]; do
    case $1 in
        -B|--build-dir)
            build_dir="$2"
            shift
            ;;
        -l|--log)
            compiler_log=true
            shift
            ;;
        -b|--build)
            ninja_build=true
            shift
            ;;
        -k|--keep-logs)
            keep_logs=true
            shift
            ;;
        -d|--debug)
            debug=true
            shift
            ;;
        -D|--device)
            device=true
            shift
            ;;
        -f|--flaky)
            flaky="$2"
            shift
            ;;
        -t|--test)
            tests+=("$2")
            shift
            ;;
        --) # end of options
            shift
            break
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *) # positional argument
            input_files+=("$1")
            shift
            ;;
    esac
done

# Validation
export BUILD_DIR=${STATIC_ROOT_DIR}/${build_dir}
if [[ ! -f "${BUILD_DIR}/build.ninja" ]]; then
    echo "Error: Invalid build directory specified" >&2
    exit 1
fi
export WORK_DIR=${BUILD_DIR}/es2p

# if [ ${#tests[@]} -eq 0 ]; then
#     echo "Error: No test specified" >&2
#     exit 1
# fi

if [[ "$flaky" =~ ^([0-9]+),([0-9]+)$ ]]; then
    flaky_i="${BASH_REMATCH[1]}"
    flaky_j="${BASH_REMATCH[2]}"
elif [[ -n $flaky ]]; then
    echo "Error: Flaky wrong iterations ("i,j")" >&2
    exit 1
fi

# set -e

mkdir -p ${WORK_DIR}/intermediate


function run_flaky() {
    # set -x
    set +e

    cmd=${@:3}

    OK_EXIT_CODE=0

    log_path_prefix=${BUILD_DIR}/log_flaky_${test}

    function run {
        RUN_ITER=_${i}_${j} ${cmd} 2>${log_path_prefix}_${i}_${j}.log 1>&2;
        if [[ $? -eq $OK_EXIT_CODE ]]; then
            if [[ $keep_logs == false ]]; then
                rm ${log_path_prefix}_${i}_${j}.log;
            fi
        else
            echo "FAIL ${i} ${j}"
        fi
    }

    rm -rf ${log_path_prefix}*.log
    for i in `seq $1`; do
        echo "Run $i"
        for j in `seq $2`; do
            run &
        done;
        wait;
    done;

    ls -lt ${log_path_prefix}*.log || return 0
    return $?
}

function run_ark() {
    echo "Run ark_aot:"
    aot_options=(
        --compiler-inline-external-methods-aot=true
        --compiler-inlining-blacklist=$1
    )
    if [ $compiler_log == true ]; then
        aot_options+=(
            --log-debug=compiler
            --compiler-log=inlining     
        )
    fi
    ${BUILD_DIR}/bin/ark_aot --gc-type=g1-gc --heap-verifier=fail_on_verification:pre:into:before_g1_concurrent:post --full-gc-bombing-frequency=0 --compiler-check-final=true --compiler-ignore-failures=false \
        "${aot_options[@]}" \
        --boot-panda-files=${BUILD_DIR}/plugins/ets/etsstdlib.abc --load-runtimes=ets --paoc-panda-files ${BUILD_DIR}/es2p/intermediate/${test}.ets.abc --paoc-output ${BUILD_DIR}/es2p/intermediate/${test}.ets.an
    echo "Run ark:"
    ark_command=(
        ${BUILD_DIR}/bin/ark
        --enable-an:force
        --gc-type=g1-gc
        --heap-verifier=fail_on_verification:pre:into:before_g1_concurrent:post
        --full-gc-bombing-frequency=0
        --boot-panda-files=${BUILD_DIR}/plugins/ets/etsstdlib.abc
        --load-runtimes=ets
        --verification-mode=ahead-of-time
        # --log-debug=all
        --aot-files
        ${BUILD_DIR}/es2p/intermediate/${test}.ets.an
        --compiler-enable-jit=false
        --panda-files=${BUILD_DIR}/es2p/intermediate/${test}.ets.abc
        ${BUILD_DIR}/es2p/intermediate/${test}.ets.abc
        ${test}.ETSGLOBAL::main
    )
    if [[ -n $flaky ]]; then
        run_flaky $flaky_i $flaky_j "${ark_command[@]}"
    else
        "${ark_command[@]}"
    fi
    [[ $debug == true ]] && echo "${ark_command[@]}"
}

function direct_test() {

    inlined_ext_funcs=()

    test=$1

    echo "${test}.ets:"
    echo "Run es2panda:"
    es2panda_command=(
        ${BUILD_DIR}/bin/es2panda
        --arktsconfig=${BUILD_DIR}/tools/es2panda/generated/arktsconfig.json
        --gen-stdlib=false
        --extension=ets
        --opt-level=2
        --output=${BUILD_DIR}/es2p/intermediate/${test}.ets.abc
        ${BUILD_DIR}/es2p/gen/${test}.ets
    )
    [[ $debug == true ]] && echo "${es2panda_command[@]}"
    "${es2panda_command[@]}"

    echo "Run verifier:"
    ${BUILD_DIR}/bin/verifier --boot-panda-files=${BUILD_DIR}/plugins/ets/etsstdlib.abc --load-runtimes=ets --config-file=${STATIC_ROOT_DIR}/tests/tests-u-runner/runner/plugins/ets/ets-verifier.config ${BUILD_DIR}/es2p/intermediate/${test}.ets.abc

    blacklist=$(IFS=,; echo "${inlined_ext_funcs[*]}")

    run_ark "${blacklist}"
}

function es2p_runner() {
    runner_command=(
        ${STATIC_ROOT_DIR}/tests/tests-u-runner/runner.sh
        --ets-es-checked
        --build-dir="${BUILD_DIR}"
        --processes=16
        --work-dir=${BUILD_DIR}/es2p${RUN_ITER}
        --heap-verifier=fail_on_verification:pre:into:before_g1_concurrent:post
        --gdb-timeout=5
        --es2panda-timeout=90
        --aot
        # --aot-args="--compiler-inline-external-methods-aot=true"
        --aot-args="--compiler-check-final=true"
        --aot-args="--compiler-ignore-failures=false"
        # --aot-args="--compiler-inlining-blacklist=$1"
        --timeout=65
        --ark-args="--enable-an:force"
        --force-generate
        --compare-files-iterations=2
        --test-file ${test}.ets
    )
    "${runner_command[@]}"
}

function es2p() {
    command=(
        ${ROOT_DIR}/jenkins-ci/scripts/es2panda_test.sh
        --
        --ets-es-checked
        --es2panda-opt-level=2
        --es2panda-timeout=90
        --timeout=95
        --gdb-timeout=5
        --gc-type=g1-gc
        --heap-verifier=fail_on_verification:pre:into:before_g1_concurrent:post
        --aot
        --aot-args='--compiler-check-final=true'
        --aot-args='--compiler-ignore-failures=false'
        --ark-args='--enable-an:force'
        --work-dir ${BUILD_DIR}/es2p${RUN_ITER}
        --processes=16
    )
    "${command[@]}"
}

if [ "$ninja_build" = true ]; then
    cd ${BUILD_DIR}
    ninja -j4 ark ark_aot es2panda
    cd -
fi

# # test=${tests[0]}
# export RETRIES_IN_STRICT_MODE=4
# es2p

# exit 0

if [[ $device == true ]]; then

function HDC() {
    hdc -s ${HDC_SERVER_IP_PORT} -t ${HDC_DEVICE_SERIAL} ${@}
}
function HDC_SEND() {
    hdc -s ${HDC_SERVER_IP_PORT} -t ${HDC_DEVICE_SERIAL} file send ${@}
}

lock_device()
{
    if [[ `HDC shell file $MUTEX` == *"cannot"* ]]; then
        echo Device is free - locking...
        HDC shell "echo $USER > $MUTEX"
        return 0
    else
        echo Device is busy by `HDC shell cat $MUTEX` ...
        return 1
    fi        
}
 
release_device()
{
    echo Release device
    HDC shell rm $MUTEX
}

MUTEX=/data/local/tmp/mutex
MODE=release

trap release_device EXIT INT TERM HUP


test=${tests[0]}

set -e

es2panda_command=(
    ${BUILD_DIR}/bin/es2panda
    --arktsconfig=${BUILD_DIR}/tools/es2panda/generated/arktsconfig.json
    --gen-stdlib=false
    --extension=ets
    --opt-level=2
    --output=${BUILD_DIR}/es2p/intermediate/${test}.ets.abc
    ${BUILD_DIR}/es2p/gen/${test}.ets
)
"${es2panda_command[@]}"

ark_aot_command=(
    ${BUILD_DIR}/bin/ark_aot
    --gc-type=g1-gc
    --heap-verifier=fail_on_verification:pre:into:before_g1_concurrent:post
    --full-gc-bombing-frequency=0
    --compiler-check-final=true
    --compiler-ignore-failures=false
    "${aot_options[@]}"
    --boot-panda-files=${BUILD_DIR}/plugins/ets/etsstdlib.abc
    --load-runtimes=ets
    --paoc-panda-files
    ${BUILD_DIR}/es2p/intermediate/${test}.ets.abc
    --paoc-output
    ${BUILD_DIR}/es2p/intermediate/${test}.ets.an
)
"${ark_aot_command[@]}"

if ! lock_device; then
    exit
fi

TEMP_DIR=${BUILD_DIR}/es2p/intermediate
TEST=${test}.ets

HDC_SEND $TEMP_DIR/$TEST.abc $DEV_HOME/$TEST.abc
HDC_SEND $TEMP_DIR/$TEST.an $DEV_HOME/$TEST.an 

ark_command=(
    --enable-an:force
    --gc-type=g1-gc
    --heap-verifier=fail_on_verification:pre:into:before_g1_concurrent:post
    --full-gc-bombing-frequency=0
    --boot-panda-files=$DEV_HOME/etsstdlib.abc
    --load-runtimes=ets
    --verification-mode=ahead-of-time
    --aot-files=$DEV_HOME/$TEST.an
    --compiler-enable-jit=false
    --panda-files=$DEV_HOME/$TEST.abc
    $DEV_HOME/$TEST.abc
    ${test}.ETSGLOBAL::main
)
HDC shell "(hilog -r) && \time -v /system/bin/taskset -a 3F0 env LD_LIBRARY_PATH=$DEV_HOME/lib $DEV_HOME/ark ${ark_command[@]}"

release_device

elif [ ${#tests[@]} -eq 0 ]; then
    es2p
elif [ ${#tests[@]} -eq 1 ]; then
    direct_test ${tests[0]}
else
    # Store process IDs
    pids=()

    # Launch multiple tasks
    for t in ${tests[@]}; do
        direct_test $t &
        pids+=($!)
        echo $t
    done

    # Wait for all processes and collect exit codes
    exit_codes=()
    for pid in "${pids[@]}"; do
        wait $pid
        exit_codes+=($?)
    done

    # Display results
    echo "All tasks completed"
    for i in "${!exit_codes[@]}"; do
        echo "Task $((i+1)) exit code: ${exit_codes[i]}"
    done
fi
