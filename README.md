# Experimental ROCm patch fork

This branch is an experimental, minimally maintained collection of ROCm changes
for RDNA 3 (`gfx1100`) and RDNA 4 (`gfx1201`), a unified-KV prompt-cache
restore fix, and occupancy-driven dynamic MTP/ngram admission. It is published for home-server users and for selective
cherry-picking. It is not an official llama.cpp build or a supported downstream
distribution. See [ROCM_FORK.md](ROCM_FORK.md) before using it.

The custom commit stack is explicitly catalogued in
[PATCHES.md](PATCHES.md), including provenance, hardware/workload labels and
dependencies.

Dynamic speculation behavior, invocation, validation and limitations are in
[DYNAMIC_SPECULATION_PATCH_NOTES.md](DYNAMIC_SPECULATION_PATCH_NOTES.md).

# llama.cpp

## Contributing

- Contributors can open PRs
- Collaborators will be invited based on contributions
- Maintainers can push to branches in the `llama.cpp` repo and merge PRs into the `master` branch
- Any help with managing issues, PRs and projects is very appreciated!
- Read the [CONTRIBUTING.md](CONTRIBUTING.md) for more information

## Acknowledgements

- [yhirose/cpp-httplib](https://github.com/yhirose/cpp-httplib) - Single-header HTTP server, used by `llama-server` - MIT license
- [stb-image](https://github.com/nothings/stb) - Single-header image format decoder, used by multimodal subsystem - Public domain
- [nlohmann/json](https://github.com/nlohmann/json) - Single-header JSON library, used by various tools/examples - MIT License
- [miniaudio.h](https://github.com/mackron/miniaudio) - Single-header audio format decoder, used by multimodal subsystem - Public domain
- [subprocess.h](https://github.com/sheredom/subprocess.h) - Single-header process launching solution for C and C++ - Public domain
