# Copyright (c) 2021 zenywallet

import base58
import bytes

{.used.}

var strtmp {.threadvar.}: string

proc base58_enc*(buf: ptr UncheckedArray[byte], size: cint): cstring {.exportc.} =
  strtmp = base58.enc(buf.toBytes(size)) & "\0"
  result = strtmp.cstring

proc base58_enc_from_hex*(hex: cstring): cstring {.exportc.} =
   strtmp = base58.enc(($hex).Hex.toBytes) & "\0"
   result = strtmp.cstring

proc base58_dec*(s: cstring, buf: ptr UncheckedArray[byte], size: cint): cint {.exportc.} =
  var d = base58.dec($s)
  if size >= d.len.cint:
    copyMem(buf, addr d[0], d.len)
    result = d.len.cint
  else:
    result = -1.cint

proc base58_dec_to_hex*(s: cstring): cstring {.exportc.} =
  var d = base58.dec($s)
  strtmp = d.toHex
  result = strtmp.cstring

#[
char* base58_enc(char* buf, int size);
char* base58_enc_from_hex(char* hex);
int base58_dec(char* s, char* buf, int size);
char* base58_dec_to_hex(char* s);
]#