import os

const libbtcPath = splitPath(currentSourcePath()).head / "../deps/libbtc"

{.passC: "-I\"" & libbtcPath / "include\"".}
{.compile: libbtcPath / "src/segwit_addr.c".}

#const BTC_ECKEY_UNCOMPRESSED_LENGTH* = 65
const BTC_ECKEY_COMPRESSED_LENGTH* = 33
#const BTC_ECKEY_PKEY_LENGTH* = 32
#const BTC_HASH_LENGTH* = 32

type
  uint8_t = uint8

## * Encode a SegWit address
##
##   Out: output:   Pointer to a buffer of size 73 + strlen(hrp) that will be
##                  updated to contain the null-terminated address.
##   In:  hrp:      Pointer to the null-terminated human readable part to use
##                  (chain/network specific).
##        ver:      Version of the witness program (between 0 and 16 inclusive).
##        prog:     Data bytes for the witness program (between 2 and 40 bytes).
##        prog_len: Number of data bytes in prog.
##   Returns 1 if successful.
##

proc segwit_addr_encode*(output: cstring; hrp: cstring; ver: cint; prog: ptr uint8_t;
                        prog_len: csize_t): cint {.importc.}

## * Decode a SegWit address
##
##   Out: ver:      Pointer to an int that will be updated to contain the witness
##                  program version (between 0 and 16 inclusive).
##        prog:     Pointer to a buffer of size 40 that will be updated to
##                  contain the witness program bytes.
##        prog_len: Pointer to a size_t that will be updated to contain the length
##                  of bytes in prog.
##        hrp:      Pointer to the null-terminated human readable part that is
##                  expected (chain/network specific).
##        addr:     Pointer to the null-terminated address.
##   Returns 1 if successful.
##

proc segwit_addr_decode*(ver: ptr cint; prog: ptr uint8_t; prog_len: ptr csize_t;
                        hrp: cstring; `addr`: cstring): cint {.importc.}

## * Encode a Bech32 string
##
##   Out: output:  Pointer to a buffer of size strlen(hrp) + data_len + 8 that
##                 will be updated to contain the null-terminated Bech32 string.
##   In: hrp :     Pointer to the null-terminated human readable part.
##       data :    Pointer to an array of 5-bit values.
##       data_len: Length of the data array.
##   Returns 1 if successful.
##

proc bech32_encode*(output: cstring; hrp: cstring; data: ptr uint8_t; data_len: csize_t): cint {.importc.}

## * Decode a Bech32 string
##
##   Out: hrp:      Pointer to a buffer of size strlen(input) - 6. Will be
##                  updated to contain the null-terminated human readable part.
##        data:     Pointer to a buffer of size strlen(input) - 8 that will
##                  hold the encoded 5-bit data values.
##        data_len: Pointer to a size_t that will be updated to be the number
##                  of entries in data.
##   In: input:     Pointer to a null-terminated Bech32 string.
##   Returns 1 if succesful.
##

proc bech32_decode*(hrp: cstring; data: ptr uint8_t; data_len: ptr csize_t;
                   input: cstring): cint {.importc.}
