# Copyright (c) 2021 zenywallet

import os

const uthasSrcPath = currentSourcePath().parentDir() / "../deps/uthash/src"

{.passC: "-I\"" & uthasSrcPath & "\"".}

{.emit: """
#include "uthash.h"

#undef uthash_fatal
#define uthash_fatal(msg) fatal_native(msg)

#undef HASH_INITIAL_NUM_BUCKETS
#define HASH_INITIAL_NUM_BUCKETS 65536U

#undef HASH_ADD_TO_BKT
#define HASH_ADD_TO_BKT(head,hh,addhh,oomed)                                     \
do {                                                                             \
  UT_hash_bucket *_ha_head = &(head);                                            \
  _ha_head->count++;                                                             \
  (addhh)->hh_next = _ha_head->hh_head;                                          \
  (addhh)->hh_prev = NULL;                                                       \
  if (_ha_head->hh_head != NULL) {                                               \
    _ha_head->hh_head->hh_prev = (addhh);                                        \
  }                                                                              \
  _ha_head->hh_head = (addhh);                                                   \
  if ((addhh)->tbl->num_items * 2U >= (addhh)->tbl->num_buckets) {               \
    HASH_EXPAND_BUCKETS(addhh,(addhh)->tbl, oomed);                              \
    IF_HASH_NONFATAL_OOM(                                                        \
      if (oomed) {                                                               \
        HASH_DEL_IN_BKT(head,addhh);                                             \
      }                                                                          \
    )                                                                            \
  }                                                                              \
} while (0)

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
