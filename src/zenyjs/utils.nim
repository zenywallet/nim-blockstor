# Copyright (c) 2020 zenywallet

import json, strutils, nimcrypto
import arraylib

proc toJson*(val: uint64): JsonNode =
  if val > 9007199254740991'u64:
    newJString($val)
  else:
    newJInt(BiggestInt(val))

proc toUint64*(val: JsonNode): uint64 =
  case val.kind
  of JString:
    result = val.getStr.parseBiggestUInt.uint64
  of JInt:
    result = val.getInt.uint64
  else:
    raiseAssert("toUint64 unexpected " & $val.kind)

proc sha256d*(data: openarray[byte]): array[32, byte] {.inline.} =
  sha256.digest(sha256.digest(data).data).data

proc sha256s*(data: openarray[byte]): array[32, byte] {.inline.} =
  sha256.digest(data).data

proc sha256d*(data: Array[byte]): array[32, byte] {.inline.} =
  sha256.digest(sha256.digest(cast[ptr byte](data.data), data.len.uint).data).data

proc sha256s*(data: Array[byte]): array[32, byte] {.inline.} =
  sha256.digest(cast[ptr byte](data.data), data.len.uint).data
