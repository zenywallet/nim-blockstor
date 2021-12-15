# Copyright (c) 2019 zenywallet

import ed25519
import serpent
import yespower
import nimcrypto
import algorithm

const USE_LZ4 = true

when USE_LZ4:
  import lz4
  const DICT_SIZE = 64 * 1024
else:
  import brotli

type
  DeoxyEncrypt* = object
    enc_iv: array[16, byte]
    dec_iv: array[16, byte]
    l_key: array[140, uint32]
    when USE_LZ4:
      streamComp: ptr LZ4_stream_t
      encDict: ptr UncheckedArray[byte]
      decDict: ptr UncheckedArray[byte]

  DeoxySalt* = array[32, byte]

  DeoxyError* = object of CatchableError


proc countup(val: var array[16, byte]) =
  for i in val.low..val.high:
    val[i] = (val[i] + 1) and 0xff
    if val[i] != 0:
      break

proc create*(): ptr DeoxyEncrypt {.exportc: "deoxy_create".} =
  when USE_LZ4:
    let p = cast[ptr UncheckedArray[byte]](allocShared0(sizeof(DeoxyEncrypt) + DICT_SIZE * 2))
    result = cast[ptr DeoxyEncrypt](p)
    result.streamComp = LZ4_createStream()
    if result.streamComp.isnil:
      raise newException(DeoxyError, "create stream failed")
    result.encDict = cast[ptr UncheckedArray[byte]](addr p[sizeof(DeoxyEncrypt)])
    result.decDict = cast[ptr UncheckedArray[byte]](addr p[sizeof(DeoxyEncrypt) + DICT_SIZE])
  else:
    result = cast[ptr DeoxyEncrypt](allocShared0(sizeof(DeoxyEncrypt)))

proc free*(p: pointer) {.exportc: "deoxy_free".} =
  when USE_LZ4:
    let deoxyEncrypt = cast[ptr DeoxyEncrypt](p)
    discard deoxyEncrypt.streamComp.LZ4_freeStream()
  deallocShared(p)

proc yespower(data: array[32, byte]): YespowerHash =
  var hash: YespowerHash
  if yespower_n2r8(cast[ptr UncheckedArray[byte]](unsafeAddr data[0]), 32, hash) != 0:
    raise newException(DeoxyError, "yespower failed")
  hash

proc `xor`[I, T](a: array[I, T], b: array[I, T] or ptr array[I, T] or ref array[I, T]): array[I, T] =
  for i in a.low..a.high:
    result[i] = a[i] xor b[i]

proc setKey*(deoxyEncrypt: ptr DeoxyEncrypt, shared: Ed25519SharedSecret,
            myself: DeoxySalt, friend: DeoxySalt) {.exportc: "deoxy_setkey".} =
  let shared_sha256 = sha256.digest(shared)
  let shared_key = yespower(shared_sha256.data)
  let salt_myself = cast[ptr array[32, byte]](unsafeAddr myself[0])
  let salt_friend = cast[ptr array[32, byte]](unsafeAddr friend[0])
  let iv_myself_sha256 = sha256.digest(shared_key xor salt_myself)
  let iv_friend_sha256 = sha256.digest(shared_key xor salt_friend)
  let iv_myself = yespower(iv_myself_sha256.data)
  let iv_friend = yespower(iv_friend_sha256.data)
  copyMem(addr deoxyEncrypt.enc_iv[0], unsafeAddr iv_myself[0], sizeof(DeoxyEncrypt.enc_iv))
  copyMem(addr deoxyEncrypt.dec_iv[0], unsafeAddr iv_friend[0], sizeof(DeoxyEncrypt.dec_iv))
  setKey(cast[ptr uint32](unsafeAddr shared_key[0]), shared_key.len * 8,
        cast[ptr array[140, uint32]](addr deoxyEncrypt.l_key[0]))

proc encrypt*(deoxyEncrypt: ptr DeoxyEncrypt, in_blk: ptr UncheckedArray[byte], out_blk: ptr UncheckedArray[byte]) =
  var enc: array[16, byte]
  encrypt(cast[ptr array[140, uint32]](addr deoxyEncrypt.l_key[0]),
          cast[ptr array[4, uint32]](addr deoxyEncrypt.enc_iv[0]),
          cast[ptr array[4, uint32]](addr enc[0]))
  let enc_u32p = cast[ptr array[4, uint32]](addr enc[0])
  let in_u32p = cast[ptr array[4, uint32]](in_blk)
  let out_u32p = cast[ptr array[4, uint32]](out_blk)
  for i in 0..3:
    out_u32p[i] = in_u32p[i] xor enc_u32p[i]
  countup(deoxyEncrypt.enc_iv)

proc decrypt*(deoxyEncrypt: ptr DeoxyEncrypt, in_blk: ptr UncheckedArray[byte], out_blk: ptr UncheckedArray[byte]) =
  var dec: array[16, byte]
  encrypt(cast[ptr array[140, uint32]](addr deoxyEncrypt.l_key[0]),
          cast[ptr array[4, uint32]](addr deoxyEncrypt.dec_iv[0]),
          cast[ptr array[4, uint32]](addr dec[0]))
  let dec_u32p = cast[ptr array[4, uint32]](addr dec[0])
  let in_u32p = cast[ptr array[4, uint32]](in_blk)
  let out_u32p = cast[ptr array[4, uint32]](out_blk)
  for i in 0..3:
    out_u32p[i] = in_u32p[i] xor dec_u32p[i]
  countup(deoxyEncrypt.dec_iv)

when USE_LZ4:
  proc enc*(deoxyEncrypt: ptr DeoxyEncrypt, indata: ptr UncheckedArray[byte], insize: uint,
          outdata: ptr UncheckedArray[byte], outsize: uint): int {.exportc: "deoxy_enc".} =
    var outsize: int = deoxyEncrypt.streamComp.LZ4_compress_fast_continue(cast[cstring](addr indata[0]),
                        cast[cstring](addr outdata[0]), insize.cint, outsize.cint, 1.cint)
    if outsize <= 0:
      raise newException(DeoxyError, "compress failed")
    discard deoxyEncrypt.streamComp.LZ4_saveDict(cast[cstring](addr deoxyEncrypt.encDict[0]), DICT_SIZE.cint)
    var pos: uint = 0
    var next_pos: uint = 16
    while next_pos < outsize.uint:
      deoxyEncrypt.encrypt(cast[ptr UncheckedArray[byte]](addr outdata[pos]),
                          cast[ptr UncheckedArray[byte]](addr outdata[pos]))
      pos = next_pos
      inc(next_pos, 16)
    if pos < outsize.uint:
      var src: array[16, byte]
      var enc: array[16, byte]
      var plen = outsize.uint - pos
      src.fill(cast[byte](plen))
      copyMem(addr src[0], addr outdata[pos], plen)
      deoxyEncrypt.encrypt(cast[ptr UncheckedArray[byte]](addr src[0]),
                          cast[ptr UncheckedArray[byte]](addr enc[0]))
      copyMem(addr outdata[pos], addr enc[0], plen)
    result = outsize

  proc dec*(deoxyEncrypt: ptr DeoxyEncrypt, indata: ptr UncheckedArray[byte], insize: uint,
          outdata: ptr UncheckedArray[byte], outsize: uint): int {.exportc: "deoxy_dec".} =
    # warning: indata will be changed
    var pos: uint = 0
    var next_pos: uint = 16
    while next_pos < insize:
      deoxyEncrypt.decrypt(cast[ptr UncheckedArray[byte]](addr indata[pos]),
                          cast[ptr UncheckedArray[byte]](addr indata[pos]))
      pos = next_pos
      inc(next_pos, 16)
    if pos < insize:
      var src: array[16, byte]
      var dec: array[16, byte]
      var plen = insize - pos
      src.fill(cast[byte](plen))
      copyMem(addr src[0], addr indata[pos], plen)
      deoxyEncrypt.decrypt(cast[ptr UncheckedArray[byte]](addr src[0]),
                          cast[ptr UncheckedArray[byte]](addr dec[0]))
      copyMem(addr indata[pos], addr dec[0], plen)
    var outsize: int = LZ4_decompress_safe_usingDict(cast[cstring](addr indata[0]),
                        cast[cstring](addr outdata[0]), insize.cint,
                        outsize.cint, cast[cstring](addr deoxyEncrypt.decDict[0]), DICT_SIZE.cint)
    if outsize > DICT_SIZE:
      copyMem(addr deoxyEncrypt.decDict[0], addr outdata[outsize - DICT_SIZE], DICT_SIZE)
    elif outsize > 0:
      let size = DICT_SIZE - outsize
      copyMem(addr deoxyEncrypt.decDict[0], addr deoxyEncrypt.decDict[outsize], size)
      copyMem(addr deoxyEncrypt.decDict[size], addr outdata[0], outsize)
    else:
      raise newException(DeoxyError, "decompress failed")
    result = outsize

else:
  proc enc*(deoxyEncrypt: ptr DeoxyEncrypt, indata: ptr UncheckedArray[byte], insize: uint,
          outdata: ptr ptr UncheckedArray[byte], outsize: ptr uint) {.exportc: "deoxy_enc".} =
    brotli.comp(indata, insize, outdata, outsize)
    var pos: uint = 0
    var next_pos: uint = 16
    while next_pos < outsize[]:
      deoxyEncrypt.encrypt(cast[ptr UncheckedArray[byte]](addr outdata[][pos]),
                          cast[ptr UncheckedArray[byte]](addr outdata[][pos]))
      pos = next_pos
      inc(next_pos, 16)
    if pos < outsize[]:
      var src: array[16, byte]
      var enc: array[16, byte]
      var plen = outsize[] - pos
      src.fill(cast[byte](plen))
      copyMem(addr src[0], addr outdata[][pos], plen)
      deoxyEncrypt.encrypt(cast[ptr UncheckedArray[byte]](addr src[0]),
                          cast[ptr UncheckedArray[byte]](addr enc[0]))
      copyMem(addr outdata[][pos], addr enc[0], plen)

  proc dec*(deoxyEncrypt: ptr DeoxyEncrypt, indata: ptr UncheckedArray[byte], insize: uint,
          outdata: ptr ptr UncheckedArray[byte], outsize: ptr uint) {.exportc: "deoxy_dec".} =
    # warning: indata will be changed
    var pos: uint = 0
    var next_pos: uint = 16
    while next_pos < insize:
      deoxyEncrypt.decrypt(cast[ptr UncheckedArray[byte]](addr indata[pos]),
                          cast[ptr UncheckedArray[byte]](addr indata[pos]))
      pos = next_pos
      inc(next_pos, 16)
    if pos < insize:
      var src: array[16, byte]
      var dec: array[16, byte]
      var plen = insize - pos
      src.fill(cast[byte](plen))
      copyMem(addr src[0], addr indata[pos], plen)
      deoxyEncrypt.decrypt(cast[ptr UncheckedArray[byte]](addr src[0]),
                          cast[ptr UncheckedArray[byte]](addr dec[0]))
      copyMem(addr indata[pos], addr dec[0], plen)
    brotli.decomp(indata, insize, outdata, outsize)
