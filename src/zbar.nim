# cd deps/zbar
# sed -i "s/ -Werror//" $(pwd)/configure.ac
# autoreconf -vfi
# emconfigure ./configure CPPFLAGS=-DNDEBUG=1 --without-x --without-jpeg --without-imagemagick --without-npapi --without-gtk --without-python --without-qt --without-xshm --disable-video --disable-pthread --enable-codes=all
# emmake make
# see https://github.com/Naahuel/zbar-wasm-barcode-reader

import os
when defined(nimHasUsed): {.used.}

const zbarPath = splitPath(currentSourcePath()).head & "/../deps/zbar"
{.passL: zbarPath & "/zbar/.libs/libzbar.a".}
