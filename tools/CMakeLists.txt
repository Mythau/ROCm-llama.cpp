# dependencies

find_package(Threads REQUIRED)

# third-party

# ...

# flags

llama_add_compile_flags()

# tools

if (EMSCRIPTEN)
else()
    add_subdirectory(llama-bench)
    add_subdirectory(quantize)
    if (LLAMA_BUILD_SERVER)
        add_subdirectory(ui)
        add_subdirectory(server)
    endif()
    add_subdirectory(mtmd)
endif()
