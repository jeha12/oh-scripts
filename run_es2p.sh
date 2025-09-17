# export ROOT_DIR=/media/share/panda/panda2
export STATIC_ROOT_DIR=${ROOT_DIR}/runtime_core/static_core


export NODE_TLS_REJECT_UNAUTHORIZED=0

compiler_log=false
ninja_build=false
keep_logs=false
debug=false
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

    # set +e
    # run_flaky 1 10 run_ark
    # run_ark "${blacklist}"
    run_ark

    # inlined_ext_funcs=(
    #     "escompat.Array::<ctor>"
    # )

    # # blacklist=()
    # # for i in "${!inlined_ext_funcs[@]}"; do
    # for func in "${inlined_ext_funcs[@]}"; do
    #     # blacklist+=("${func}")
    #     blacklist_str=$(IFS=,; echo "${blacklist[*]}")
    #     echo
    #     echo "BLACKLIST: ${blacklist_str}"
    #     echo "Run ark_aot:"
    #     aot_options=(
    #         --compiler-inline-external-methods-aot=true
    #         # --log-debug=compiler
    #         # --compiler-log=inlining
    #         --compiler-inlining-blacklist=${blacklist_str}
    #         # --compiler-inlining-blacklist="escompat.IteratorResult::<ctor>,std.core.ArrayValue::getLength,std.core.Lambda0::<ctor>,std.core.Object::<ctor>,std.core.Double::<ctor>,std.core.Floating::<ctor>,std.core.Int::<ctor>,std.core.Integral::<ctor>,std.core.Int::toString,std.core.Numeric::<ctor>,std.core.StringBuilder::<ctor>,std.testing.arktest::assertCommon,std.testing.arktest::assertEQ,${test}.%%lambda-lambda_invoke-0::<ctor>,${test}.%%lambda-lambda_invoke-0::invoke0" \
    #     )
    #     ${BUILD_DIR}/bin/ark_aot --gc-type=g1-gc --heap-verifier=fail_on_verification:pre:into:before_g1_concurrent:post --full-gc-bombing-frequency=0 --compiler-check-final=true --compiler-ignore-failures=false \
    #         "${aot_options[@]}" \
    #         --boot-panda-files=${BUILD_DIR}/plugins/ets/etsstdlib.abc --load-runtimes=ets --paoc-panda-files ${BUILD_DIR}/es2p/intermediate/${test}.ets.abc --paoc-output ${BUILD_DIR}/es2p/intermediate/${test}.ets.an
    #     echo "Run ark:"
    #     ${BUILD_DIR}/bin/ark --enable-an:force --gc-type=g1-gc --heap-verifier=fail_on_verification:pre:into:before_g1_concurrent:post --full-gc-bombing-frequency=0 --boot-panda-files=${BUILD_DIR}/plugins/ets/etsstdlib.abc --load-runtimes=ets --verification-mode=ahead-of-time --aot-files ${BUILD_DIR}/es2p/intermediate/${test}.ets.an --compiler-enable-jit=false --panda-files=${BUILD_DIR}/es2p/intermediate/${test}.ets.abc ${BUILD_DIR}/es2p/intermediate/${test}.ets.abc ${test}.ETSGLOBAL::main
    # done
}

function es2p_runner() {
    runner_command=(
        --ets-es-checked --es2panda-opt-level=2 --es2panda-timeout=90 --timeout=95 --gdb-timeout=5 --gc-type=g1-gc --heap-verifier=fail_on_verification:pre:into:before_g1_concurrent:post --aot --aot-args=--compiler-check-final=true --aot-args=--compiler-ignore-failures=false --ark-args=--enable-an:force --work-dir /home/jenkins/agent/workspace/Panda/Panda-RunOnly/archives/ets-es-checked --processes=16

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



exit 0

set -e

# es2p "escompat.Array::<ctor>"
direct_test
# es2p

# run_flaky es2p 2 10

# run_flaky 1 10 es2p


#         --aot-args="--log-debug=compiler" --aot-args="--compiler-log=inlining" \

# /media/share/panda/panda2/jenkins-ci/scripts/es2panda_test.sh -- \
#     --ets-es-checked --es2panda-opt-level=2 --es2panda-timeout=90 \
#     --timeout=65 --gdb-timeout=5 --gc-type=g1-gc \
#     --heap-verifier=fail_on_verification:pre:into:before_g1_concurrent:post \
#     --aot --aot-args='--compiler-check-final=true' \
#     --aot-args='--compiler-ignore-failures=false' \
#     --ark-args='--enable-an:force' \
#     --work-dir ${WORK_DIR} \
#     --processes=16

# ./es2panda_test.sh -- --ets-runtime --es2panda-opt-level=2 --es2panda-timeout=90 --timeout=60 --gc-type=g1-gc --aot --aot-args='--compiler-check-final=true' --aot-args='--compiler-ignore-failures=false' --ark-args='--enable-an:force' --test-list-arch=amd64 --work-dir /home/jenkins/agent/workspace/Panda/Pre_Merge_ETS_ARM_Tests/archives/ets-runtime --processes=16

# /media/share/panda/panda2/jenkins-ci/scripts/es_checked_setup.sh -- \
#     --ets-es-checked --es2panda-opt-level=2 --es2panda-timeout=90 --timeout=65 \
#     --gdb-timeout=5 --gc-type=g1-gc \
#     --heap-verifier=fail_on_verification:pre:into:before_g1_concurrent:post \
#     --aot --aot-args='--compiler-check-final=true' \
#     --aot-args='--compiler-ignore-failures=false' \
#     --ark-args='--enable-an:force' \
#     --work-dir ${WORK_DIR} \
#     --processes=16




# [2025-09-12T08:27:43.404Z] Program terminated with signal SIGSEGV, Segmentation fault.

# [2025-09-12T08:27:43.404Z] #0  0x00007ff37cdeb75b in kill () from /lib/x86_64-linux-gnu/libc.so.6

# [2025-09-12T08:27:43.404Z] [Current thread is 1 (Thread 0x7ff37cc15840 (LWP 113808))]

# [2025-09-12T08:27:43.404Z] #0  0x00007ff37cdeb75b in kill () from /lib/x86_64-linux-gnu/libc.so.6

# [2025-09-12T08:27:43.404Z] #1  0x00007ff37d40bac7 in ark::SignalHook::CallOldAction (signo=11, siginfo=0x7ffe489d9130, ucontextRaw=0x7ffe489d9000) at /panda_src/runtime_core/static_core/platforms/unix/libpandabase/sighook.cpp:204

# [2025-09-12T08:27:43.404Z] #2  <signal handler called>

# [2025-09-12T08:27:43.404Z] #3  std::__atomic_base<unsigned int>::load (this=0x2, __m=std::memory_order_acquire) at /usr/bin/../lib/gcc/x86_64-linux-gnu/11/../../../../include/c++/11/bits/atomic_base.h:488

# [2025-09-12T08:27:43.404Z] #4  ark::Method::IsNative (this=0x2) at /panda_src/runtime_core/static_core/runtime/include/method.h:526

# [2025-09-12T08:27:43.404Z] #5  ark::CFrame::IsNativeMethod (this=0x7ffe489d9d40) at /panda_src/runtime_core/static_core/runtime/cframe.cpp:26

# [2025-09-12T08:27:43.404Z] #6  0x00007ff37f934c45 in ark::StackWalker::CreateCFrame (this=0x7ffe489da070, ptr=0x7ffe489dbce8, npc=140683337873978, calleeSlots=0x0, prevCallees=prevCallees@entry=0x0) at /panda_src/runtime_core/static_core/runtime/stack_walker.cpp:140

# [2025-09-12T08:27:43.404Z] #7  0x00007ff37f934af2 in ark::StackWalker::GetTopFrameFromFp (this=0x7ffe489da070, ptr=<optimized out>, isFrameCompiled=<optimized out>, npc=<optimized out>) at /panda_src/runtime_core/static_core/runtime/stack_walker.cpp:64

# [2025-09-12T08:27:43.404Z] #8  ark::StackWalker::StackWalker (this=0x7ffe489da070, fp=<optimized out>, isFrameCompiled=<optimized out>, npc=<optimized out>, policy=ark::UnwindPolicy::ALL) at /panda_src/runtime_core/static_core/runtime/stack_walker.cpp:45

# [2025-09-12T08:27:43.404Z] #9  0x00007ff37f934856 in ark::StackWalker::Create (thread=0x7ff37c877ce0, policy=ark::UnwindPolicy::ALL) at /panda_src/runtime_core/static_core/runtime/stack_walker.cpp:39

# [2025-09-12T08:27:43.404Z] #10 0x00007ff37f960418 in ark::PrintStackTrace () at /panda_src/runtime_core/static_core/runtime/runtime_helpers.cpp:29

# [2025-09-12T08:27:43.404Z] #11 0x00007ff37f944f2d in ark::CrashFallbackDumpHandler::Action (this=<optimized out>, sig=<optimized out>, siginfo=<optimized out>, context=<optimized out>) at /panda_src/runtime_core/static_core/runtime/signal_handler.cpp:459

# [2025-09-12T08:27:43.404Z] #12 0x00007ff37f943411 in ark::SignalManager::SignalActionHandler (this=0x100f42b30, sig=11, info=0x7ffe489daff0, context=0x7ffe489daec0) at /panda_src/runtime_core/static_core/runtime/signal_handler.cpp:62

# [2025-09-12T08:27:43.404Z] #13 0x00007ff37d40bbcd in ark::SignalHook::SetHandlingSignal (signo=signo@entry=11, siginfo=siginfo@entry=0x7ffe489daff0, ucontextRaw=ucontextRaw@entry=0x7ffe489daec0) at /panda_src/runtime_core/static_core/platforms/unix/libpandabase/sighook.cpp:226

# [2025-09-12T08:27:43.404Z] #14 0x00007ff37d40beb7 in ark::SignalHook::Handler (signo=11, siginfo=0x7ffe489daff0, ucontextRaw=0x7ffe489daec0) at /panda_src/runtime_core/static_core/platforms/unix/libpandabase/sighook.cpp:241

# [2025-09-12T08:27:43.405Z] #15 <signal handler called>

# [2025-09-12T08:27:43.405Z] #16 0x00007ff33c380e4f in f64 escompat.Array::pushOne(escompat.Array, std.core.Object) () from /panda_src/artifacts/build/plugins/ets/etsstdlib.an

# [2025-09-12T08:27:43.405Z] #17 0x00007ff364613c6e in escompat.Iterator uint16array_copyWithin14.ETSGLOBAL::getIteratorFromIterable(std.core.Object, std.core.Type) () from /archives/ets-es-checked/intermediate/uint16array_copyWithin14.ets.an

# [2025-09-12T08:27:43.405Z] #18 0x00007ff364463623 in u1 uint16array_copyWithin14.ETSGLOBAL::__value_is_same(std.core.Object, std.core.Object) () from /archives/ets-es-checked/intermediate/uint16array_copyWithin14.ets.an

# [2025-09-12T08:27:43.405Z] #19 0x00007ff36445f229 in void uint16array_copyWithin14.ETSGLOBAL::__check_value(std.core.Object, std.core.Object) () from /archives/ets-es-checked/intermediate/uint16array_copyWithin14.ets.an

# [2025-09-12T08:27:43.405Z] #20 0x00007ff3643adfd5 in void uint16array_copyWithin14.ETSGLOBAL::test0() () from /archives/ets-es-checked/intermediate/uint16array_copyWithin14.ets.an

# [2025-09-12T08:27:43.405Z] #21 0x00007ff3643ad1c7 in void uint16array_copyWithin14.ETSGLOBAL::main() () from /archives/ets-es-checked/intermediate/uint16array_copyWithin14.ets.an

# [2025-09-12T08:27:43.405Z] #22 0x00007ff37fa9b28c in InvokeCompiledCodeWithArgArray () at /panda_src/runtime_core/static_core/runtime/bridge/arch/amd64/interpreter_to_compiled_code_bridge_amd64.S:534

# [2025-09-12T08:27:43.405Z] #23 0x00007ff37f8b4f85 in ark::Method::InvokeCompiledCode (this=0x7ff35c3d9718, this@entry=0x0, thread=0x7ff37c877ce0, thread@entry=0x7ff35c3d9718, numArgs=numArgs@entry=32766, args=args@entry=0x7ff35c3d9718) at /panda_src/runtime_core/static_core/runtime/include/method-inl.h:203

# [2025-09-12T08:27:43.405Z] #24 0x00007ff37f8b17aa in ark::Method::InvokeImpl<ark::InvokeHelperStatic, ark::Value> (this=0x7ff37cb54448, this@entry=0x7ff35c3d9718, thread=0xc3fe8, thread@entry=0x7ff37c877ce0, numActualArgs=836552, args=0x4, args@entry=0x0, proxyCall=<optimized out>) at /panda_src/runtime_core/static_core/runtime/include/method-inl.h:424

# [2025-09-12T08:27:43.405Z] #25 0x00007ff37f8ae4fa in ark::Method::Invoke (this=0x7ff35c3d9718, thread=0x7ff37c877ce0, args=0x0, proxyCall=false) at /panda_src/runtime_core/static_core/runtime/method.cpp:228

# [2025-09-12T08:27:43.405Z] #26 0x00007ff3800938c8 in ark::ets::PandaEtsVM::InvokeEntrypointImpl (this=0x7ff37c80d268, entrypoint=0x7ff35c3d9718, args=std::vector of length 0, capacity 0) at /panda_src/runtime_core/static_core/plugins/ets/runtime/ets_vm.cpp:573

# [2025-09-12T08:27:43.405Z] #27 0x00007ff37f776740 in ark::PandaVM::InvokeEntrypoint (this=0x7ff37c80d268, entrypoint=0x7ff35c3d9718, args=std::vector of length 0, capacity 0) at /panda_src/runtime_core/static_core/runtime/panda_vm.cpp:60

# [2025-09-12T08:27:43.405Z] #28 0x00007ff37f8d18a8 in ark::Runtime::Execute (this=0x100f19470, args=std::vector of length 112275813817026, capacity -35242 = {...}, entryPoint=...) at /panda_src/runtime_core/static_core/runtime/runtime.cpp:1268

# [2025-09-12T08:27:43.405Z] #29 ark::Runtime::ExecutePandaFile (this=0x100f19470, filename=..., entryPoint=..., args=std::vector of length 112275813817026, capacity -35242 = {...}) at /panda_src/runtime_core/static_core/runtime/runtime.cpp:1254

# [2025-09-12T08:27:43.405Z] #30 0x0000000100017f93 in ark::ExecutePandaFile (runtime=..., entry="uint16array_copyWithin14.ETSGLOBAL::main", arguments=std::vector of length 0, capacity 0, fileName=...) at /panda_src/runtime_core/static_core/panda/panda.cpp:145

# [2025-09-12T08:27:43.405Z] #31 ark::Main (argc=<optimized out>, argv=<optimized out>) at /panda_src/runtime_core/static_core/panda/panda.cpp:233

# [2025-09-12T08:27:43.405Z] #32 0x00007ff37cdd2d90 in ?? () from /lib/x86_64-linux-gnu/libc.so.6

# [2025-09-12T08:27:43.405Z] #33 0x00007ff37cdd2e40 in __libc_start_main () from /lib/x86_64-linux-gnu/libc.so.6

# [2025-09-12T08:27:43.405Z] #34 0x0000000100016555 in _start ()
