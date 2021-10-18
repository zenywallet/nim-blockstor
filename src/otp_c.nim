# Copyright (c) 2021 zenywallet

import otp, base32

{.used.}

proc call_totp*(key: cstring, sec: uint64, digit: int = 6, timestep: int = 30, algo: int): cstring {.exportc.} =
  var totp = newTotp(base32.dec($key), digit, timestep, algo.ALGO)
  result = totp.generate(sec) & "\0"

#[
char *call_totp(char* key, uint64_t sec, int digit, int timestep, int algo);
]#
