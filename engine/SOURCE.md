# Vendored engine source

This directory is a copy of [gufo-mimo26](https://github.com/kaka86mm/gufo-mimo26)
at tag `mimo2-0.15.0` — the tree that builds the measured production binary
`96e5afcc8d56953f9984e6a4f4e6f79e`.

Build from this directory:

```sh
cmake --preset release -DGUFO_ENABLE_TP2_RDMA=ON -DGUFO_MIMO2_HIP=ON
cmake --build --preset release --parallel 8
```

Both CMake flags are required; `GUFO_MIMO2_HIP` defaults to OFF and the link
fails on every `mimo2` symbol without it. See [MIMO26.md](MIMO26.md) for the
model files, dense-sidecar generation, runtime environment and the measured
binary hash. The standalone repository carries the commit history.
