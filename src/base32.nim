# Copyright (c) 2021 zenywallet

const base32Chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567" # (pad) =
const base32Map = [int8 -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
                        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
                        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
                        -1, -1, 26, 27, 28, 29, 30, 31, -1, -1, -1, -1, -1, -1, -1, -1,
                        -1,  0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14,
                        15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, -1, -1, -1, -1, -1,
                        -1,  0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14,
                        15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, -1, -1, -1, -1, -1,
                        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
                        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
                        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
                        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
                        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
                        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
                        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
                        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1]


proc enc*(data: seq[byte] | string): string =
  var pos = 0
  result = newStringOfCap(((data.len + 4) / 5).int * 8)
  while pos < data.len:
    let c0 = data[pos].byte shr 3
    result.add(base32Chars[c0])

    let c10 = data[pos].byte shl 2 and 0x1f'u8
    inc(pos)
    if pos >= data.len:
      result.add(base32Chars[c10] & "======")
      break
    let c11 = data[pos].byte shr 6
    let c1 = c10 or c11
    result.add(base32Chars[c1])

    let c2 = data[pos].byte shr 1 and 0x1f'u8
    result.add(base32Chars[c2])

    let c30 = data[pos].byte shl 4 and 0x1f'u8
    inc(pos)
    if pos >= data.len:
      result.add(base32Chars[c30] & "====")
      break
    let c31 = data[pos].byte shr 4
    let c3 = c30 or c31
    result.add(base32Chars[c3])

    let c40 = data[pos].byte shl 1 and 0x1f'u8
    inc(pos)
    if pos >= data.len:
      result.add(base32Chars[c40] & "===")
      break
    let c41 = data[pos].byte shr 7
    let c4 = c40 or c41
    result.add(base32Chars[c4])

    let c5 = data[pos].byte shr 2 and 0x1f'u8
    result.add(base32Chars[c5])

    let c60 = data[pos].byte shl 3 and 0x1f'u8
    inc(pos)
    if pos >= data.len:
      result.add(base32Chars[c60] & "=")
      break
    let c61 = data[pos].byte shr 5
    let c6 = c60 or c61
    result.add(base32Chars[c6])

    let c7 = data[pos].byte and 0x1f'u8
    result.add(base32Chars[c7])
    inc(pos)

proc dec*(data: string): seq[byte] =
  var pos = 0
  result = newSeqOfCap[byte]((data.len * 5 / 8).int)
  while pos < data.len:
    let m0 = base32Map[data[pos].uint8]
    if m0 < 0:
      break
    let c0 = m0.byte

    inc(pos)
    if pos >= data.len:
      break
    let m1 = base32Map[data[pos].uint8]
    if m1 < 0:
      break
    let c1 = m1.byte

    let b0 = c0 shl 3 or c1 shr 2
    result.add(b0)

    inc(pos)
    if pos >= data.len:
      break
    let m2 = base32Map[data[pos].uint8]
    if m2 < 0:
      break
    let c2 = m2.byte

    inc(pos)
    if pos >= data.len:
      break
    let m3 = base32Map[data[pos].uint8]
    if m3 < 0:
      break
    let c3 = m3.byte

    let b1 = c1 shl 6 or c2 shl 1 or c3 shr 4
    result.add(b1)

    inc(pos)
    if pos >= data.len:
      break
    let m4 = base32Map[data[pos].uint8]
    if m4 < 0:
      break
    let c4 = m4.byte

    let b2 = c3 shl 4 or c4 shr 1
    result.add(b2)

    inc(pos)
    if pos >= data.len:
      break
    let m5 = base32Map[data[pos].uint8]
    if m5 < 0:
      break
    let c5 = m5.byte

    inc(pos)
    if pos >= data.len:
      break
    let m6 = base32Map[data[pos].uint8]
    if m6 < 0:
      break
    let c6 = m6.byte

    let b3 = c4 shl 7 or c5 shl 2 or c6 shr 3
    result.add(b3)

    inc(pos)
    if pos >= data.len:
      break
    let m7 = base32Map[data[pos].uint8]
    if m7 < 0:
      break
    let c7 = m7.byte

    let b4 = c6 shl 5 or c7
    result.add(b4)

    inc(pos)


const base32Pad = '='
type
  Base32Error* = object of CatchableError

proc decStrict*(data: string): seq[byte] =
  var pos = 0
  try:
    if data.len mod 8 != 0:
      raise

    result = newSeqOfCap[byte]((data.len * 5 / 8).int)
    while pos < data.len:
      let m0 = base32Map[data[pos].uint8]
      if m0 < 0:
        raise
      let c0 = m0.byte

      inc(pos)
      let m1 = base32Map[data[pos].uint8]
      if m1 < 0:
        raise
      let c1 = m1.byte

      let b0 = c0 shl 3 or c1 shr 2
      result.add(b0)

      inc(pos)
      let m2 = base32Map[data[pos].uint8]
      if m2 < 0:
        if data[pos] == base32Pad:
          break
        raise
      let c2 = m2.byte

      inc(pos)
      let m3 = base32Map[data[pos].uint8]
      if m3 < 0:
        raise
      let c3 = m3.byte

      let b1 = c1 shl 6 or c2 shl 1 or c3 shr 4
      result.add(b1)

      inc(pos)
      let m4 = base32Map[data[pos].uint8]
      if m4 < 0:
        if data[pos] == base32Pad:
          break
        raise
      let c4 = m4.byte

      let b2 = c3 shl 4 or c4 shr 1
      result.add(b2)

      inc(pos)
      let m5 = base32Map[data[pos].uint8]
      if m5 < 0:
        if data[pos] == base32Pad:
          break
        raise
      let c5 = m5.byte

      inc(pos)
      let m6 = base32Map[data[pos].uint8]
      if m6 < 0:
        raise
      let c6 = m6.byte

      let b3 = c4 shl 7 or c5 shl 2 or c6 shr 3
      result.add(b3)

      inc(pos)
      let m7 = base32Map[data[pos].uint8]
      if m7 < 0:
        if data[pos] == base32Pad:
          break
        raise
      let c7 = m7.byte

      let b4 = c6 shl 5 or c7
      result.add(b4)

      inc(pos)
  except:
    raise newException(Base32Error, "invalid")


when isMainModule:
  echo enc("")
  echo enc("f")
  echo enc("fo")
  echo enc("foo")
  echo enc("foob")
  echo enc("fooba")
  echo enc("foobar")

  assert enc("") == ""
  assert enc("f") == "MY======"
  assert enc("fo") == "MZXQ===="
  assert enc("foo") == "MZXW6==="
  assert enc("foob") == "MZXW6YQ="
  assert enc("fooba") == "MZXW6YTB"
  assert enc("foobar") == "MZXW6YTBOI======"

  proc toString(s: seq[byte]): string = cast[string](s)

  echo dec("").toString
  echo dec("MY======").toString
  echo dec("MZXQ====").toString
  echo dec("MZXW6===").toString
  echo dec("MZXW6YQ=").toString
  echo dec("MZXW6YTB").toString
  echo dec("MZXW6YTBOI======").toString

  assert dec("").toString == ""
  assert dec("MY======").toString == "f"
  assert dec("MZXQ====").toString == "fo"
  assert dec("MZXW6===").toString == "foo"
  assert dec("MZXW6YQ=").toString == "foob"
  assert dec("MZXW6YTB").toString == "fooba"
  assert dec("MZXW6YTBOI======").toString == "foobar"

  echo dec("").toString
  echo dec("MY").toString
  echo dec("MZXQ").toString
  echo dec("MZXW6").toString
  echo dec("MZXW6YQ").toString
  echo dec("MZXW6YTB").toString
  echo dec("MZXW6YTBOI").toString

  echo decStrict("").toString
  echo decStrict("MY======").toString
  echo decStrict("MZXQ====").toString
  echo decStrict("MZXW6===").toString
  echo decStrict("MZXW6YQ=").toString
  echo decStrict("MZXW6YTB").toString
  echo decStrict("MZXW6YTBOI======").toString

  template checkExcept*(body: untyped) =
    try:
      body
    except:
      let e = getCurrentException()
      echo e.name, ": ", e.msg

  checkExcept: echo decStrict("").toString
  checkExcept: echo decStrict("my").toString
  checkExcept: echo decStrict("mzxq").toString
  checkExcept: echo decStrict("mzxw6").toString
  checkExcept: echo decStrict("mzxw6yq").toString
  checkExcept: echo decStrict("mzxw6ytb").toString
  checkExcept: echo decStrict("mzxw6ytboi").toString
