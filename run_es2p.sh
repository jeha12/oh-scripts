if [[ ! -d $STATIC_ROOT_DIR ]]; then
    echo "Error: Invalid STATIC_ROOT_DIR specified" >&2
    exit 1
fi

export ROOT_DIR=${STATIC_ROOT_DIR}/../..


export NODE_TLS_REJECT_UNAUTHORIZED=0

compiler_log=false
ninja_build=false
keep_logs=false
debug=false
debug_dump=false
device=false
generate=false
run_only=false
flaky=""
build_dir=""
prefix=""
intermediate_dir=""
compiler_regex=""
tests=()
processes=6

special_case=""

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
        --debug-dump)
            debug_dump=true
            shift
            ;;  
        -D|--device)
            device=true
            shift
            ;;
        -r|--run-only)
            run_only=true
            shift
            ;;
        -f|--flaky)
            flaky="$2"
            shift
            ;;
        -j|--processes)
            processes="$2"
            shift
            ;;
        -t|--test)
            tests+=("$2")
            shift
            ;;
        -I|--intermediate-dir)
            intermediate_dir="$2"
            shift
            ;;
        -C|--compiler-regex)
            compiler_regex="$2"
            shift
            ;;
        -g|--generate)
            generate=true
            shift
            ;;
        -S|--case)
            special_case="$2"
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

if [[ ! -n $intermediate_dir ]]; then
    intermediate_dir=${WORK_DIR}/intermediate
fi
mkdir -p ${WORK_DIR}
mkdir -p ${intermediate_dir}


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
    aot_options=(
        --compiler-inline-external-methods-aot=true
        --compiler-inlining-blacklist=$1
        --compiler-emit-debug-info=true
    )
    if [ $compiler_log == true ]; then
        aot_options+=(
            --log-debug=compiler
            --compiler-log=inlining     
        )
    fi
    if [[ -n $compiler_regex ]]; then
        ir_dump_dir=${intermediate_dir}/${test}_ir_dump
        rm -r ${ir_dump_dir}/*.ir
        aot_options+=(
            --compiler-dump:folder=${intermediate_dir}/${test}_ir_dump
            --compiler-regex=$compiler_regex
        )
    fi

    # # Disable passes
    # aot_options+=(
    #     --compiler-aot-ra=false
    #     --compiler-balance-expressions=false
    #     --compiler-branch-elimination=false
    #     --compiler-checks-elimination=false
    #     --compiler-deoptimize-elimination=false
    #     --compiler-if-conversion=false
    #     --compiler-if-merging=false
    #     --compiler-interop-intrinsic-optimization=false
    #     --compiler-licm=false
    #     --compiler-licm-conditions=false
    #     --compiler-loop-idioms=false
    #     --compiler-loop-peeling=false
    #     --compiler-loop-unroll=false
    #     --compiler-loop-unswitch=false
    #     --compiler-lse=false
    #     --compiler-memory-coalescing=false
    #     --compiler-move-constants=false
    #     --compiler-peepholes=false
    #     --compiler-redundant-loop-elimination=false
    #     --compiler-reserve-string-builder-buffer=false
    #     --compiler-scalar-replacement=false
    #     --compiler-simplify-string-builder=false
    #     --compiler-spill-fill-pair=false
    #     --compiler-unroll-unknown-trip-count=false
    #     --compiler-unroll-with-side-exits=false
    #     --compiler-vn=false
    # )


    if [[ $run_only == false ]]; then
        echo "Run ark_aot:"
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
            ${intermediate_dir}/${test}.ets.abc
            --paoc-output ${intermediate_dir}/${test}.ets.an
        )
        "${ark_aot_command[@]}" || return $?
        if [[ $debug == true ]]; then
            echo "${ark_aot_command[@]}"
            if [[ $debug_dump == true ]]; then
                ${BUILD_DIR}/bin/ark_disasm --verbose ${intermediate_dir}/${test}.ets.abc ${intermediate_dir}/${test}.ets.abc.asm
                ${BUILD_DIR}/bin/ark_aotdump ${intermediate_dir}/${test}.ets.an &> ${intermediate_dir}/${test}.ets.an.dump
            fi
        fi
    fi

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
        --aot-files
        ${intermediate_dir}/${test}.ets.an
        --compiler-enable-jit=false
        --panda-files=${intermediate_dir}/${test}.ets.abc
        ${intermediate_dir}/${test}.ets.abc
        ${test}.ETSGLOBAL::main
    )
    if [[ -n $flaky ]]; then
        run_flaky $flaky_i $flaky_j "${ark_command[@]}"
    else
        "${ark_command[@]}"
        echo "Exit: $?"
    fi
    if [[ $debug == true ]]; then
        echo "${ark_command[@]}"
    fi
}

function direct_test() {

    test=$1

    if [[ $run_only == true ]]; then
        run_ark
        return
    fi

    inlined_ext_funcs=()

    if [[ $special_case == "fill0_pass" ]] || [[ $special_case == "fill0_fail" ]]; then
        inlined_ext_funcs=(
            "escompat.ArrayBuffer::<ctor>"
            "escompat.ArrayBuffer::doBoundaryCheck"
            "escompat.ArrayBuffer::set"
            # "escompat.Array::<ctor>"
            "escompat.Array::ensureUnusedCapacity"
            "escompat.Array::<get>length"
            "escompat.Array::pushOne"
            "escompat.Array::toString"
            "escompat.Buffer::<ctor>"
            "escompat.DataView::<get>byteLength"
            "escompat.DataView::getUint8"
            "escompat.DataView::getUint8Big"
            "escompat.ETSGLOBAL::isNaN"
            "escompat.IteratorResult::<ctor>"
            "escompat.Uint8ClampedArray::clamp"
            "escompat.Uint8ClampedArray::<ctor>"
            "escompat.Uint8ClampedArray::<get>length"
            "escompat.Uint8ClampedArray::set"
            "escompat.Uint8ClampedArray::setUnsafe"
            "escompat.Uint8ClampedArray::setUnsafeClamp"
            "std.core.ArrayValue::getLength"
            "std.core.ClassType::equals"
            "std.core.ClassType::getMethod"
            "std.core.ClassType::getMethodsNum"
            "std.core.Console::addToBuffer"
            "std.core.Console::<get>indent"
            "std.core.Console::log"
            "std.core.Console::print"
            "std.core.Console::println"
            "std.core.Double::compare"
            "std.core.Double::<ctor>"
            "std.core.Double::toDouble"
            "std.core.ETSGLOBAL::getBootRuntimeLinker"
            "std.core.Float::<ctor>"
            "std.core.Floating::<ctor>"
            "std.core.Float::toFloat"
            "std.core.Float::unboxed"
            "std.core.Int::<ctor>"
            "std.core.Integral::<ctor>"
            "std.core.Int::toInt"
            "std.core.Int::toString"
            "std.core.Lambda0::<ctor>"
            "std.core.LogLevel::valueOf"
            "std.core.Method::getName"
            "std.core.Method::getType"
            "std.core.Method::isStatic"
            "std.core.Numeric::<ctor>"
            "std.core.Object::<ctor>"
            "std.core.Runtime::sameFloatValue"
            "std.core.Runtime::sameNumberValue"
            "std.core.Runtime::sameValue"
            "std.core.StringBuilder::<ctor>"
            "std.core.TypeAPI::getClassDescriptor"
            "std.core.TypeAPI::getTypeDescriptor"
            "std.core.Type::of"
            "std.testing.arktest::assertCommon"
            "std.testing.arktest::assertEQ"
            "std.testing.arktest::assertTrue"
        )
        if [[ $special_case == "fill0_pass" ]]; then
            inlined_ext_funcs+=(
                "escompat.Array::<ctor>"
            )
        fi
    fi

    echo "${test}.ets:"
    echo "Run es2panda:"
    es2panda_command=(
        ${BUILD_DIR}/bin/es2panda
        --arktsconfig=${BUILD_DIR}/tools/es2panda/generated/arktsconfig.json
        --gen-stdlib=false
        --extension=ets
        --opt-level=2
        --output=${intermediate_dir}/${test}.ets.abc
        ${BUILD_DIR}/es2p/gen/${test}.ets
    )
    if [[ $debug == true ]]; then
        echo "${es2panda_command[@]}"
        es2panda_command+=(
            --debug-info=true
        )
    fi
    "${es2panda_command[@]}" || return $?

    echo "Run verifier:"
    ${BUILD_DIR}/bin/verifier --boot-panda-files=${BUILD_DIR}/plugins/ets/etsstdlib.abc --load-runtimes=ets --config-file=${STATIC_ROOT_DIR}/tests/tests-u-runner/runner/plugins/ets/ets-verifier.config ${intermediate_dir}/${test}.ets.abc

    blacklist=$(IFS=,; echo "${inlined_ext_funcs[*]}")

    run_ark "${blacklist}"
}

function es2p_runner() {
    runner_command=(
        ${STATIC_ROOT_DIR}/tests/tests-u-runner/runner.sh
        --ets-es-checked
        --build-dir="${BUILD_DIR}"
        --processes=${processes}
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
        --processes=${processes}
    )
    "${command[@]}"
}

if [ "$ninja_build" = true ]; then
    cd ${BUILD_DIR}
    ninja -j${processes} ark ark_aot es2panda ets-compile-stdlib-default
    cd -

    # cd ${BUILD_DIR}/plugins/ets && ${BUILD_DIR}/bin/es2panda_stdlib_compiler --opt-level=2 --thread=0 --extension=ets --output=${BUILD_DIR}/plugins/ets/etsstdlib.abc --gen-stdlib=true --generate-decl:enabled,path=${BUILD_DIR}/plugins/ets/stdlib/decls --arktsconfig=${STATIC_ROOT_DIR}/plugins/ets/stdlib/stdconfig.json --debug-info=true
    # ${STATIC_ROOT_DIR}/plugins/ets/compiler/tools/paoc_compile_stdlib.sh --prefix="" --binary-dir=${BUILD_DIR} -compiler-options="--compiler-check-final=true --compiler-emit-debug-info=true" -paoc-output=${BUILD_DIR}/plugins/ets/etsstdlib.an

fi

if [[ $generate == true ]]; then
    for test in ${tests[@]}; do
        test_yaml="${test%%_*}"
        test_name=$(echo "$test" | sed 's/[0-9]*$//')
        ${STATIC_ROOT_DIR}/tests/tests-u-runner/tools/generate-es-checked/main.rb \
            --out ${BUILD_DIR}/es2p/gen \
            --tmp ${BUILD_DIR}/es2p/tmp \
            --ts-node=npx:--prefix:${STATIC_ROOT_DIR}/tests/tests-u-runner/tools/generate-es-checked:ts-node:-P:${STATIC_ROOT_DIR}/tests/tests-u-runner/tools/generate-es-checked/tsconfig.json \
            --filter "^${test_name}$" \
            ${STATIC_ROOT_DIR}/plugins/ets/tests/ets_es_checked/${test_yaml}.yaml
    done
fi

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
        --output=${intermediate_dir}/${test}.ets.abc
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
        ${intermediate_dir}/${test}.ets.abc
        --paoc-output
        ${intermediate_dir}/${test}.ets.an
    )
    "${ark_aot_command[@]}"

    if ! lock_device; then
        exit
    fi

    TEMP_DIR=${intermediate_dir}
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
