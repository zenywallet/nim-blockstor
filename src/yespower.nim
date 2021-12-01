## -
##  Copyright 2009 Colin Percival
##  Copyright 2013-2018 Alexander Peslyak
##  All rights reserved.
##
##  Redistribution and use in source and binary forms, with or without
##  modification, are permitted provided that the following conditions
##  are met:
##  1. Redistributions of source code must retain the above copyright
##     notice, this list of conditions and the following disclaimer.
##  2. Redistributions in binary form must reproduce the above copyright
##     notice, this list of conditions and the following disclaimer in the
##     documentation and/or other materials provided with the distribution.
##
##  THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
##  ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
##  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
##  ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
##  FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
##  DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
##  OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
##  HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
##  LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
##  OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
##  SUCH DAMAGE.
##
##  This file was originally written by Colin Percival as part of the Tarsnap
##  online backup system.
##

## *
##  Internal type used by the memory allocator.  Please do not use it directly.
##  Use yespower_local_t instead.
##

type
  yespower_region_t {.bycopy.} = object
    base: pointer
    aligned: pointer
    base_size: csize_t
    aligned_size: csize_t


## *
##  Type for thread-local (RAM) data structure.
##

type
  yespower_local_t* = yespower_region_t

##
##  Type for yespower algorithm version numbers.
##

type
  yespower_version_t* = enum
    YESPOWER_0_5 = 5
    YESPOWER_1_0 = 10


## *
##  yespower parameters combined into one struct.
##

type
  uint32_t* = uint32
  uint8_t* = uint8

  yespower_params_t* {.bycopy.} = object
    version*: yespower_version_t
    N*: uint32_t
    r*: uint32_t
    pers*: cstring # ptr uint8_t
    perslen*: csize_t


## *
##  A 256-bit yespower hash.
##

type
  yespower_binary_t* {.bycopy.} = object
    uc*: array[32, uint8]


## *
##  yespower_init_local(local):
##  Initialize the thread-local (RAM) data structure.  Actual memory allocation
##  is currently fully postponed until a call to yespower().
##
##  Return 0 on success; or -1 on error.
##
##  MT-safe as long as local is local to the thread.
##

proc yespower_init_local*(local: ptr yespower_local_t): cint {.importc.}
## *
##  yespower_free_local(local):
##  Free memory that may have been allocated for an initialized thread-local
##  (RAM) data structure.
##
##  Return 0 on success; or -1 on error.
##
##  MT-safe as long as local is local to the thread.
##

proc yespower_free_local*(local: ptr yespower_local_t): cint {.importc.}
## *
##  yespower(local, src, srclen, params, dst):
##  Compute yespower(src[0 .. srclen - 1], N, r), to be checked for "< target".
##  local is the thread-local data structure, allowing to preserve and reuse a
##  memory allocation across calls, thereby reducing processing overhead.
##
##  Return 0 on success; or -1 on error.
##
##  local must be initialized with yespower_init_local().
##
##  MT-safe as long as local and dst are local to the thread.
##

proc yespower*(local: ptr yespower_local_t; src: ptr uint8_t; srclen: csize_t;
              params: ptr yespower_params_t; dst: ptr yespower_binary_t): cint {.importc.}
## *
##  yespower_tls(src, srclen, params, dst):
##  Compute yespower(src[0 .. srclen - 1], N, r), to be checked for "< target".
##  The memory allocation is maintained internally using thread-local storage.
##
##  Return 0 on success; or -1 on error.
##
##  MT-safe as long as dst is local to the thread.
##

proc yespower_tls*(src: ptr uint8_t; srclen: csize_t; params: ptr yespower_params_t;
                  dst: ptr yespower_binary_t): cint {.importc.}


import os

const yespowerPath = currentSourcePath().parentDir() / "../deps/yespower"

{.passC: "-I\"" & yespowerPath & "\" -DNDEBUG".}
{.compile: yespowerPath / "sha256.c".}
{.compile: yespowerPath / "yespower-opt.c".}


const params = yespower_params_t(version: YESPOWER_0_5,
                                N: 2048,
                                r: 8,
                                pers: "Client Key".cstring,
                                perslen: "Client Key".len.csize_t)

const params_n2r8 = yespower_params_t(version: YESPOWER_1_0,
                                      N: 2048,
                                      r: 8,
                                      pers: nil,
                                      perslen: 0)

const params_n4r16 = yespower_params_t(version: YESPOWER_1_0,
                                      N: 4096,
                                      r: 16,
                                      pers: nil,
                                      perslen: 0)

const params_n4r32 = yespower_params_t(version: YESPOWER_1_0,
                                      N: 4096,
                                      r: 32,
                                      pers: nil,
                                      perslen: 0)

type
  YespowerHash* = array[32, byte]

var local {.threadvar.}: yespower_local_t

proc yespower_init*(): int {.inline, discardable.} =
  yespower_init_local(addr local)

proc yespower_free*(): int {.inline, discardable.} =
  yespower_free_local(addr local)

proc yespower_hash*(input: ptr UncheckedArray[byte], input_size: uint, output: var YespowerHash): int {.inline.} =
  yespower(addr local, cast[ptr uint8_t](input), input_size.csize_t, cast[ptr yespower_params_t](unsafeAddr params),
          cast[ptr yespower_binary_t](addr output))

proc yespower_n2r8*(input: ptr UncheckedArray[byte], input_size: uint, output: var YespowerHash): int {.inline.} =
  yespower(addr local, cast[ptr uint8_t](input), input_size.csize_t, cast[ptr yespower_params_t](unsafeAddr params_n2r8),
          cast[ptr yespower_binary_t](addr output))

proc yespower_n4r16*(input: ptr UncheckedArray[byte], input_size: uint, output: var YespowerHash): int {.inline.} =
  yespower(addr local, cast[ptr uint8_t](input), input_size.csize_t, cast[ptr yespower_params_t](unsafeAddr params_n4r16),
              cast[ptr yespower_binary_t](addr output))

proc yespower_n4r32*(input: ptr UncheckedArray[byte], input_size: uint, output: var YespowerHash): int {.inline.} =
  yespower(addr local, cast[ptr uint8_t](input), input_size.csize_t, cast[ptr yespower_params_t](unsafeAddr params_n4r32),
          cast[ptr yespower_binary_t](addr output))

proc yespower_hash_tls*(input: ptr UncheckedArray[byte], input_size: uint, output: var YespowerHash): int {.inline.} =
  yespower_tls(cast[ptr uint8_t](input), input_size.csize_t, cast[ptr yespower_params_t](unsafeAddr params),
              cast[ptr yespower_binary_t](addr output))

proc yespower_n2r8_tls*(input: ptr UncheckedArray[byte], input_size: uint, output: var YespowerHash): int {.inline.} =
  yespower_tls(cast[ptr uint8_t](input), input_size.csize_t, cast[ptr yespower_params_t](unsafeAddr params_n2r8),
              cast[ptr yespower_binary_t](addr output))

proc yespower_n4r16_tls*(input: ptr UncheckedArray[byte], input_size: uint, output: var YespowerHash): int {.inline.} =
  yespower_tls(cast[ptr uint8_t](input), input_size.csize_t, cast[ptr yespower_params_t](unsafeAddr params_n4r16),
              cast[ptr yespower_binary_t](addr output))

proc yespower_n4r32_tls*(input: ptr UncheckedArray[byte], input_size: uint, output: var YespowerHash): int {.inline.} =
  yespower_tls(cast[ptr uint8_t](input), input_size.csize_t, cast[ptr yespower_params_t](unsafeAddr params_n4r32),
              cast[ptr yespower_binary_t](addr output))

proc export_yespower_init(): int {.exportc: "yespower_init".} = yespower_init()

proc export_yespower_free(): int {.exportc: "yespower_free".} = yespower_free()

proc export_yespower_hash(input: ptr UncheckedArray[byte], input_size: uint,
                          output: var YespowerHash): int {.exportc: "yespower_hash".} =
  yespower_hash(input, input_size, output)

proc export_yespower_n2r8(input: ptr UncheckedArray[byte], input_size: uint,
                          output: var YespowerHash): int {.exportc: "yespower_n2r8".} =
  yespower_n2r8(input, input_size, output)

proc export_yespower_n4r16(input: ptr UncheckedArray[byte], input_size: uint,
                          output: var YespowerHash): int {.exportc: "yespower_n4r16".} =
  yespower_n4r16(input, input_size, output)

proc export_yespower_n4r32(input: ptr UncheckedArray[byte], input_size: uint,
                          output: var YespowerHash): int {.exportc: "yespower_n4r32".} =
  yespower_n4r32(input, input_size, output)


when isMainModule:
  var a: array[80, byte]
  var b: YespowerHash
  for i in 0..<80:
    a[i] = i.byte

  yespower_init()
  for i in 0..<1000:
    discard yespower_hash(cast[ptr UncheckedArray[byte]](addr a[0]), 80, b)
  echo a
  echo b
  yespower_free()
