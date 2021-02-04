# Copyright (c) 2020 zenywallet

import bytes

type
  Reader* = ref object
    data*: seq[byte]
    pos*: int

  ReaderError* = object of CatchableError


proc newReader*(data: seq[byte]): Reader =
  Reader(data: data, pos: 0)

proc getUint64*(r: Reader): uint64 =
  if r.data.len < r.pos + 8:
    raise newException(ReaderError, "uint64: out of range")
  result = r.data[r.pos].toUint64
  inc(r.pos, 8)

proc getUint32*(r: Reader): uint32 =
  if r.data.len < r.pos + 4:
    raise newException(ReaderError, "uint32: out of range")
  result = r.data[r.pos].toUint32
  inc(r.pos, 4)

proc getUint16*(r: Reader): uint16 =
  if r.data.len < r.pos + 2:
    raise newException(ReaderError, "uint16: out of range")
  result = r.data[r.pos].toUint16
  inc(r.pos, 2)

proc getUint8*(r: Reader): uint8 =
  if r.data.len < r.pos + 1:
    raise newException(ReaderError, "uint8: out of range")
  result = r.data[r.pos].toUint8
  inc(r.pos)

template getInt64*(r: Reader): int64 = cast[int64](getUint64(r))

template getInt32*(r: Reader): int32 = cast[int32](getUint32(r))

template getInt16*(r: Reader): int16 = cast[int16](getUint16(r))

template getInt8*(r: Reader): int8 = cast[int8](getUint8(r))

proc skip*(r: Reader, skipByte: int) =
  if r.data.len < r.pos + skipByte:
    raise newException(ReaderError, "skip: out of range")
  inc(r.pos, skipByte)

proc getVarInt*(r: Reader): int =
  var u8 = r.getUint8
  if u8 < 0xfd:
    result = u8.int
  elif u8 == 0xfd:
    result = r.getUint16.int
  elif u8 == 0xfe:
    var u32 = r.getUint32
    when uint32.high.uint64 > int.high.uint64:
      if u32.uint64 > int.high.uint64:
        raise newException(ReaderError, "varint: out of range")
    result = u32.int
  elif u8 == 0xff:
    var u64 = r.getUint64
    if u64 > int.high.uint64:
      raise newException(ReaderError, "varint: out of range")
    result = u64.int

proc getBytes*(r: Reader, size: int): seq[byte] =
  if r.data.len < r.pos + size:
    raise newException(ReaderError, "bytes: out of range")
  result = r.data[r.pos..<r.pos+size]
  inc(r.pos, size)

proc getVarStr*(r: Reader): string =
  var len = r.getVarInt
  var data = r.getBytes(len)
  result = data.toString
    
proc readable*(r: Reader): bool = r.data.len > r.pos

proc left*(r: Reader): int = r.data.len - r.pos

proc len*(r: Reader): int = r.data.len
