# Copyright (c) 2022 zenywallet

type
  SeedError* = object of CatchableError

when defined(js):
  import jsffi
  import jslib

  var global {.importc, nodecl.}: JsObject

  proc isDefined[T](x: T): bool {.noSideEffect, importjs: "(typeof # !== 'undefined')".}

  proc cryptSeed*(size: int): Uint8Array =
    try:
      if window.isDefined():
        if not window.crypto.isNil and not window.crypto.getRandomValues.isNil:
          var seedData = newUint8Array(size)
          window.crypto.getRandomValues(seedData)
          result = seedData
        else:
          raise newException(SeedError, "crypto.getRandomValues is not available")
      else:
        if global.crypto.isNil:
          global.crypto = require("crypto")
        var seedData = Uint8Array.from(global.crypto.randomBytes(size)).to(Uint8Array)
        result = seedData
    except:
      raise newException(SeedError, getCurrentExceptionMsg())


  when isMainModule:
    var seedData = cryptSeed(32)
    console.log(seedData)

else:
  import ../seed_native
  import arraylib

  proc cryptSeed*(buf: ptr UncheckedArray[byte], size: int): int {.importc: "crypt_seed".}

  proc cryptSeed*(buf: openArray[byte]): int {.inline.} =
    cryptSeed(cast[ptr UncheckedArray[byte]](buf), buf.len)

  proc cryptSeed*(size: int): Array[byte] =
    var a = newArray[byte](size)
    var ret = cryptSeed(cast[ptr UncheckedArray[byte]](addr a[0]), size)
    if ret == 0:
      result = a
    else:
      raise newException(SeedError, "seed generation failed")


  when isMainModule:
    var seedData = cryptSeed(32)
    echo seedData
