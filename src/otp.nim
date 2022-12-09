# Copyright (c) 2021 zenywallet

import nimcrypto
import endians
import sequtils
import strutils

type
  ALGO* = enum
    SHA1
    SHA256
    SHA512

  Totp* = ref object
    key*: string
    digit*: int
    timestep*: int
    algo*: ALGO

const DigitNum* = [uint32 1, 10, 100, 1000, 10000, 100000, 1000000, 10000000, 100000000]


proc toUint32BE(x: var byte): uint32 {.inline.} =
  bigEndian32(addr result, cast[ptr uint32](addr x))

proc newTotp*(key: string | seq[byte], digit: int = 6, timestep: int = 30, algo: ALGO = SHA1): Totp =
  result = new Totp
  result.key = cast[string](key)
  result.digit = digit
  result.timestep = timestep
  result.algo = algo

proc generateCounter*(totp: Totp, counter: uint64): string =
  var c = newSeq[byte](8)
  bigEndian64(addr c[0], unsafeAddr counter)
  var hash: seq[byte]
  case totp.algo
  of SHA1:
    hash = sha1.hmac(totp.key, c).data.toSeq
  of SHA256:
    hash = sha256.hmac(totp.key, c).data.toSeq
  of SHA512:
    hash = sha512.hmac(totp.key, c).data.toSeq
  let pos = hash[^1] and 0x0f'u8
  let code = hash[pos].toUint32BE and 0x7fffffff'u32
  let val = code mod DigitNum[totp.digit]
  result = align($val, totp.digit, '0')

proc generate*(totp: Totp, sec: uint64): string =
  let tval = sec div totp.timestep.uint64
  result = generateCounter(totp, tval)


when isMainModule:
  # https://tools.ietf.org/html/rfc6238
  var totp_sha1 = newTotp("12345678901234567890", 8, 30, SHA1)
  var totp_sha256 = newTotp("12345678901234567890123456789012", 8, 30, SHA256)
  var totp_sha512 = newTotp("1234567890123456789012345678901234567890123456789012345678901234", 8, 30, SHA512)
  echo totp_sha1.generate(59)
  echo totp_sha256.generate(59)
  echo totp_sha512.generate(59)
  echo totp_sha1.generate(1111111109)
  echo totp_sha256.generate(1111111109)
  echo totp_sha512.generate(1111111109)
  echo totp_sha1.generate(1111111111)
  echo totp_sha256.generate(1111111111)
  echo totp_sha512.generate(1111111111)
  echo totp_sha1.generate(1234567890)
  echo totp_sha256.generate(1234567890)
  echo totp_sha512.generate(1234567890)
  echo totp_sha1.generate(2000000000)
  echo totp_sha256.generate(2000000000)
  echo totp_sha512.generate(2000000000)
  echo totp_sha1.generate(20000000000'u64)
  echo totp_sha256.generate(20000000000'u64)
  echo totp_sha512.generate(20000000000'u64)
  echo "-----"

  # google authenticator test
  import times, base32
  var t = newTotp(base32.dec("testtesttesttest")) # 6, 30, SHA1
  echo t.generate(epochTime().uint64)
