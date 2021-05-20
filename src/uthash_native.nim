# Copyright (c) 2021 zenywallet

import os

const uthasSrcPath = currentSourcePath().parentDir() / "../deps/uthash/src"

{.passC: "-I\"" & uthasSrcPath & "\"".}

{.emit: """
#include "uthash.h"

#undef uthash_fatal
#define uthash_fatal(msg) fatal_native(msg)

typedef struct KVDataObj {
  int size;
  char data[];
} KVData, *PKVData;

typedef struct KVPairObj {
  UT_hash_handle hh;
  PKVData val;
  KVData key;
} *PKVPair, *PKVHandle;

void hash_add(PKVHandle *kv, PKVPair pair) {
  HASH_ADD_KEYPTR(hh, *kv, pair->key.data, pair->key.size, pair);
}

PKVPair hash_find(PKVHandle *kv, char *key, int keyLen) {
  PKVPair p;
  HASH_FIND(hh, *kv, key, keyLen, p);
  return p;
}

int hash_count(PKVHandle *kv) {
  return HASH_COUNT(*kv);
}

void hash_delete(PKVHandle *kv, PKVPair pair) {
  HASH_DEL(*kv, pair);
}

void hash_sort(PKVHandle *kv, int (*sort_function)(PKVPair a, PKVPair b)) {
  HASH_SORT(*kv, sort_function);
}
""".}

type
  UthashError* = object of CatchableError

proc fatal_native(msg: cstring) {.exportc.} =
  raise newException(UthashError, $msg)

proc hash_add*(kv: pointer, pair: pointer) {.importc.}

proc hash_find*(kv: pointer, key: ptr UncheckedArray[byte], keyLen: cint): pointer {.importc.}

proc hash_count*(kv: pointer): cint {.importc.}

proc hash_delete*(kv: pointer, pair: pointer) {.importc.}

type
  SortFuncNative* = proc (a, b: pointer): cint {.cdecl.}

proc hash_sort*(kv: pointer, sort_function: SortFuncNative) {.importc.}
