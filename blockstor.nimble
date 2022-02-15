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
requires "templates"



task debug, "Debug build, and Run":
  exec "nim c -r --threads:on -d:DYNAMIC_FILES src/blockstor.nim"

task deps, "Build deps":
  exec "nim c -r src/sophia_patch.nim"
  withDir "deps/sophia":
    if fileExists("sophia/std/ss_lz4filter.c"):
      exec "rm sophia/std/ss_lz4filter.c"
    if fileExists("sophia/std/ss_zstdfilter.c"):
      exec "rm sophia/std/ss_zstdfilter.c"
    exec "make -j$(nproc)"

  withDir "deps/openssl":
    exec "./Configure"
    exec "make -j$(nproc)"

  withDir "deps/libressl":
    exec "git checkout master"
    exec "./autogen.sh"
    exec "./configure"
    exec "make -j$(nproc)"

  withDir "deps/secp256k1":
    exec "./autogen.sh"
    exec "./configure"
    exec "make -j$(nproc)"

  withDir "deps/wasm-secp256k1":
    exec "./autogen.sh"
    exec "emconfigure ./configure"
    exec "sed -i 's/\\.\\/\\$(gen_context_BIN)/\\.\\.\\/secp256k1\\/\\$(gen_context_BIN)/' Makefile"
    exec "emmake make -j$(nproc)"

  withDir "deps/zbar":
    exec "sed -i \"s/ -Werror//\" $(pwd)/configure.ac"
    exec "autoreconf -vfi"
    exec "emconfigure ./configure CPPFLAGS=-DNDEBUG=1 --without-x --without-jpeg --without-imagemagick --without-npapi --without-gtk --without-python --without-qt --without-xshm --disable-video --disable-pthread --enable-codes=all"
    exec "emmake make -j$(nproc)"

  withDir "deps/rocksdb":
    exec "DEBUG_LEVEL=0 make liblz4.a -j$(nproc)"
    exec "PLUS_INCLUDE_PATH=./lz4-1.9.3/lib ROCKSDB_DISABLE_ZLIB=1 ROCKSDB_DISABLE_BZIP=1 ROCKSDB_DISABLE_SNAPPY=1 ROCKSDB_DISABLE_ZSTD=1 make static_lib -j$(nproc)"

task ui, "Build ui":
  if dirExists("preload_tmp"):
    exec "rm -rf preload_tmp"
  exec "mkdir preload_tmp"
  exec "cp deps/fonts/Play/Play-Regular.ttf preload_tmp/"
  exec "cp deps/fonts/Share_Tech_Mono/ShareTechMono-Regular.ttf preload_tmp/"
  exec "cp deps/fonts/themify-icons/fonts/themify.ttf preload_tmp/"
  exec "nim js -d:release -o:src/ui_loader.js src/ui_loader.nim"
  exec "nim js -d:release -d:nodejs -o:src/ui_externs.js src/ui_externs.nim"
  exec "nim c -d:release -d:emscripten -o:public/ui.js_tmp --noMain:on --gc:orc src/ui.nim"
  exec "nim c -r src/ui_patch.nim"
  exec """
if [ -x "$(command -v google-closure-compiler)" ]; then
  closure_compiler="google-closure-compiler"
else
  closure_compiler="java -jar $(ls closure-compiler-*.jar | sort -r | head -n1)"
fi
echo "use $closure_compiler"
$closure_compiler --compilation_level ADVANCED --jscomp_off=checkVars --jscomp_off=checkTypes --jscomp_off=uselessCode --js_output_file=public/ui.js --externs src/ui_externs.js public/ui.js_tmp 2>&1 | cut -c 1-240
"""
  exec "nim c -r --hints:off src/web_index.nim > public/index.html"
  exec "rm src/web_index"
  exec "rm public/ui.js_tmp"
  exec "rm src/ui_externs.js"
  exec "rm src/ui_loader.js"
  exec "rm -rf preload_tmp"

task uidebug, "Build ui for debug":
  if dirExists("preload_tmp"):
    exec "rm -rf preload_tmp"
  exec "mkdir preload_tmp"
  exec "cp deps/fonts/Play/Play-Regular.ttf preload_tmp/"
  exec "cp deps/fonts/Share_Tech_Mono/ShareTechMono-Regular.ttf preload_tmp/"
  exec "cp deps/fonts/themify-icons/fonts/themify.ttf preload_tmp/"
  exec "nim js -d:release -o:src/ui_loader.js src/ui_loader.nim"
  exec "nim js -d:release -d:nodejs -o:src/ui_externs.js src/ui_externs.nim"
  exec "nim c -d:emscripten -o:public/ui.js --noMain:on --gc:orc src/ui.nim"
  exec "nim c -r src/ui_patch.nim"
  exec "nim c -r --hints:off src/web_index.nim > public/index.html"
  exec "rm src/web_index"
  exec "rm src/ui_externs.js"
  exec "rm src/ui_loader.js"
  exec "rm -rf preload_tmp"

task webminer, "Build web miner":
  exec "nim js -d:release -o:src/web_miner_loader.js src/web_miner_loader.nim"
  exec "nim c -d:release -d:emscripten -o:public/miner.js --gc:orc src/web_miner.nim"
  exec "rm src/web_miner_loader.js"
