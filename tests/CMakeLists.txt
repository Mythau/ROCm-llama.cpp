include("cmake/common.cmake")

llama_add_compile_flags()

function(llama_build source)
    get_filename_component(target ${source} NAME_WE)
    add_executable(${target} ${source} ${ARGN})
    target_link_libraries(${target} PRIVATE llama llama-common)
    if (LLAMA_TESTS_INSTALL)
        install(TARGETS ${target} RUNTIME)
    endif()
endfunction()

function(llama_build_and_test source)
    llama_build(${source} ${ARGN})
    get_filename_component(target ${source} NAME_WE)
    add_test(NAME ${target} COMMAND $<TARGET_FILE:${target}>)
    set_property(TEST ${target} PROPERTY LABELS main)
endfunction()

# Delta-net state rollback is kept for the Qwen3.5 runtime, but is not
# registered because it requires an external model fixture.
llama_build(test-recurrent-state-rollback.cpp)

llama_build_and_test(test-backend-ops.cpp)
llama_build_and_test(test-speculative-control.cpp)
llama_build_and_test(test-batch-alloc.cpp)
llama_build_and_test(test-arg-parser.cpp)

add_executable(
    test-cohort-batching-contracts
    test-cohort-batching-contracts.cpp
    ${PROJECT_SOURCE_DIR}/tools/server/inference-admission.cpp
    ${PROJECT_SOURCE_DIR}/tools/server/inference-batching.cpp
    ${PROJECT_SOURCE_DIR}/tools/server/server-execution.cpp
    ${PROJECT_SOURCE_DIR}/tools/server/server-inference.cpp
    ${PROJECT_SOURCE_DIR}/tools/server/server-inference-snapshot.cpp
    ${PROJECT_SOURCE_DIR}/tools/server/server-progress-comparator.cpp
)
target_include_directories(test-cohort-batching-contracts PRIVATE ${PROJECT_SOURCE_DIR}/tools/server)
target_compile_features(test-cohort-batching-contracts PRIVATE cxx_std_17)
target_compile_definitions(test-cohort-batching-contracts PRIVATE LLAMA_COHORT_DIAGNOSTICS)
target_link_libraries(test-cohort-batching-contracts PRIVATE llama llama-common)
add_test(NAME test-cohort-batching-contracts COMMAND $<TARGET_FILE:test-cohort-batching-contracts>)
set_property(TEST test-cohort-batching-contracts PROPERTY LABELS main)

if (TARGET cpp-httplib)
    add_library(gguf-model-data STATIC gguf-model-data.cpp)
    target_link_libraries(gguf-model-data PRIVATE llama-common cpp-httplib)
    target_include_directories(gguf-model-data PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
endif()
