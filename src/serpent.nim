# Copyright (c) 2019 zenywallet

import os

{.compile: currentSourcePath().parentDir() / "../deps/serpent/serpent_threadsafe.c".}

proc cipher_name*(): cstringArray {.importc: "serpent_cipher_name".}
proc set_key*(in_key: ptr uint32; key_len: uint32, l_key: ptr array[140, uint32]): ptr uint32 {.importc: "serpent_set_key", discardable.}
proc encrypt*(l_key: ptr array[140, uint32], in_blk: ptr array[4, uint32]; out_blk: ptr array[4, uint32]) {.importc: "serpent_encrypt".}
proc decrypt*(l_key: ptr array[140, uint32], in_blk: ptr array[4, uint32]; out_blk: ptr array[4, uint32]) {.importc: "serpent_decrypt".}
