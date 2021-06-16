# Package

version       = "0.2.0"
author        = "zenywallet"
description   = "Block Explorer API for Wallet Service"
license       = "MIT"
srcDir        = "src"
bin           = @["blockstor"]



# Dependencies

requires "nim >= 1.2.0"
requires "nimcrypto"
requires "libcurl"
requires "zip"



task debug, "Debug build, and Run":
  exec "nim c -r --threads:on src/blockstor.nim"

task deps, "Build deps":
  withDir "deps/sophia":
    if fileExists("sophia/std/ss_lz4filter.c"):
      exec "rm sophia/std/ss_lz4filter.c"
    if fileExists("sophia/std/ss_zstdfilter.c"):
      exec "rm sophia/std/ss_zstdfilter.c"
    exec "make"

  withDir "deps/openssl":
    exec "./Configure"
    exec "make"

  withDir "deps/libressl":
    exec "./autogen.sh"
    exec "./configure"
    exec "make"
