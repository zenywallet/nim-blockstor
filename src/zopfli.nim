# Copyright (c) 2020 zenywallet

import zopfli_native

proc zopfli_comp*(inbuf: ptr cuchar; insize: csize_t; outbuf: ptr ptr cuchar; outsize: ptr csize_t) {.importc.}
proc zopfli_free*(p: pointer) {.importc.}

proc comp*(data: seq[byte] | string): seq[byte] =
  var outBuf: ptr UncheckedArray[byte]
  var outSize: csize_t
  zopfli_comp(cast[ptr cuchar](unsafeAddr data[0]), data.len.csize_t,
              cast[ptr ptr cuchar](addr outBuf), cast[ptr csize_t](addr outSize))
  var b = newSeqUninitialized[byte](outSize)
  copyMem(addr b[0], addr outBuf[0], outSize)
  zopfli_free(outBuf)
  result = b

when isMainModule:
  import os
  import zip/zlib
  import bytes

  if paramCount() >= 2:
    var srcFile = paramStr(1)
    var destFile = paramStr(2)
    var data = readFile(srcFile)
    var zopfliComp = zopfli.comp(data)
    writeFile(destFile, zopfliComp)
  else:
    var zopfliCompData = comp("hellohellohello")
    echo zopfliCompData
    echo uncompress(zopfliCompData.toString, stream = RAW_DEFLATE)
