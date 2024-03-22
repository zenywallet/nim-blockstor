# Copyright (c) 2021 zenywallet

import uthash_native
export uthash_native

type
  UT_hash_bucket* = object
    hh_head: pointer # ptr UT_hash_handle
    count: cuint
    expand_mult: cuint

  UT_hash_table* = object
    buckets: ptr UT_hash_bucket
    num_buckets, log2_num_buckets: cuint
    num_items: cuint
    tail: pointer # ptr UT_hash_handle
    # ...

  UT_hash_handle* = object
    tbl*: ptr UT_hash_table
    prev*: pointer
    next*: pointer
    hh_prev*: ptr UT_hash_handle
    hh_next*: ptr UT_hash_handle
    key*: pointer
    keylen*: cuint
    hashv*: cuint

  KVDataObj* = object
    size*: cint
    data*: UncheckedArray[byte]

  KVData* = ptr KVDataObj

  KVPairObj*[T] = object
    hh*: UT_hash_handle
    val*: T
    key*: KVDataObj

  KVPair*[T] = ptr KVPairObj[T]
  KVHandle*[T] = ptr KVPairObj[T]


converter KVHandleToVar*[T](p: ptr KVHandle[T]): var KVHandle[T] {.inline.} = p[]

template loadUthashModules*() {.dirty.} =
  proc newKVPair*[T](key: openArray[byte], val: T): KVPair[T] =
    let kvpair = cast[KVPair[T]](allocShared0(sizeof(KVPairObj[T]) + key.len))
    kvpair.key.size = key.len.cint
    copyMem(addr kvpair.key.data, unsafeAddr key[0], key.len)
    kvpair.val = val
    result = kvpair

  when not declared(freeVal):
    {.warning: "missing custom proc freeVal*[T](val: T)".}
    proc freeVal[T](val: T) = discard

  proc free*(pair: KVPair) =
    pair.val.freeVal()
    pair.deallocShared()

  proc add*[T](kv: var KVHandle[T], key: openArray[byte], val: T) =
    var keyval = newKVPair[T](key, val)
    kv.addr.hash_add(keyval)

  proc addRet*[T](kv: var KVHandle[T], key: openArray[byte], val: T): KVPair[T] =
    var keyval = newKVPair[T](key, val)
    kv.addr.hash_add(keyval)
    result = keyval

  proc `[]=`*[T](kv: var KVHandle[T], key: openArray[byte], val: T) =
    var pair = cast[KVPair[T]](kv.addr.hash_find(cast[ptr UncheckedArray[byte]](unsafeAddr key[0]), key.len.cint))
    if pair.isNil:
      var keyval = newKVPair[T](key, val)
      kv.addr.hash_add(keyval)
    else:
      var oldval = pair.val
      pair.val = val
      oldval.freeVal()

  proc `[]`*[T](kv: var KVHandle[T], key: openArray[byte]): T =
    var pair = cast[KVPair[T]](kv.addr.hash_find(cast[ptr UncheckedArray[byte]](unsafeAddr key[0]), key.len.cint))
    if not pair.isNil:
      result = pair.val

  proc len*(kv: var KVHandle): int = kv.addr.hash_count().int

  proc del*[T](kv: var KVHandle[T], pair: KVPair[T]) =
    if not pair.isNil:
      kv.addr.hash_delete(pair)
      pair.free()

  proc del*[T](kv: var KVHandle[T], key: openArray[byte]) =
    var pair = cast[KVPair[T]](kv.addr.hash_find(cast[ptr UncheckedArray[byte]](unsafeAddr key[0]), key.len.cint))
    while not pair.isNil:
      let next = cast[KVPair[T]](pair.hh.hh_next)
      let hkey = (addr pair.key.data).toBytes(pair.key.size.int)
      if hkey == key:
        kv.addr.hash_delete(pair)
        pair.free()
      pair = next

  proc del*[T](kv: var KVHandle[T], key: openArray[byte], pred: proc (x: T): bool {.gcsafe.}) =
    var pair = cast[KVPair[T]](kv.addr.hash_find(cast[ptr UncheckedArray[byte]](unsafeAddr key[0]), key.len.cint))
    while not pair.isNil:
      let next = cast[KVPair[T]](pair.hh.hh_next)
      let hkey = (addr pair.key.data).toBytes(pair.key.size.int)
      if hkey == key and pred(pair.val):
        kv.addr.hash_delete(pair)
        pair.free()
      pair = next

  iterator items*[T](kv: var KVHandle[T]): tuple[key: seq[byte], val: T] =
    var h = cast[KVPair[T]](kv)
    while not h.isNil:
      var next = cast[KVPair[T]](h.hh.next)
      yield(key: (addr h.key.data).toBytes(h.key.size.int), val: h.val)
      h = next

  iterator items*[T](kv: var KVHandle[T], key: openArray[byte]): tuple[key: seq[byte], val: T] =
    var h = cast[KVPair[T]](kv.addr.hash_find(cast[ptr UncheckedArray[byte]](unsafeAddr key[0]), key.len.cint))
    if not h.isNil:
      while true:
        let next = cast[KVPair[T]](h.hh.hh_next)
        if next.isNil:
          break
        h = next
      while true:
        let prev = cast[KVPair[T]](h.hh.hh_prev)
        let hkey = (addr h.key.data).toBytes(h.key.size.int)
        if hkey == key:
          yield(key: hkey, val: h.val)
        if prev.isNil:
          break
        h = prev

  iterator itemsRev*[T](kv: var KVHandle[T], key: openArray[byte]): tuple[key: seq[byte], val: T] =
    var h = cast[KVPair[T]](kv.addr.hash_find(cast[ptr UncheckedArray[byte]](unsafeAddr key[0]), key.len.cint))
    while not h.isNil:
      let next = cast[KVPair[T]](h.hh.hh_next)
      let hkey = (addr h.key.data).toBytes(h.key.size.int)
      if hkey == key:
        yield(key: hkey, val: h.val)
      h = next

  proc clear*[T](kv: var KVHandle[T]) =
    var h = cast[KVPair[T]](kv)
    while not h.isNil:
      var next = cast[KVPair[T]](h.hh.next)
      kv.addr.hash_delete(h)
      h.free()
      h = next

  proc itemExists*[T](kv: var KVHandle[T]): bool =
    var h = cast[KVPair[T]](kv)
    if not h.isNil:
      return true
    return false

  proc itemExists*[T](kv: var KVHandle[T], key: openArray[byte]): bool =
    var h = cast[KVPair[T]](kv.addr.hash_find(cast[ptr UncheckedArray[byte]](unsafeAddr key[0]), key.len.cint))
    while not h.isNil:
      let next = cast[KVPair[T]](h.hh.hh_next)
      let hkey = (addr h.key.data).toBytes(h.key.size.int)
      if hkey == key:
        return true
      h = next
    return false

  type
    SortFunc*[T] = proc (a, b: KVPair[T]): cint {.cdecl.}

  proc sort*[T](kv: var KVHandle[T], sortFunc: SortFunc[T]) =
    kv.addr.hash_sort(cast[SortFuncNative](sortFunc))


when isMainModule:
  import bytes

  type
    TestValObj = object
      a: int
      b: int

    TestVal = ptr TestValObj

  type
    TestVal2Obj = object
      len: int
      s: UncheckedArray[byte]

    TestVal2 = ptr TestVal2Obj

  proc newTestVal(a, b: int): TestVal =
    let t1 = cast[TestVal](allocShared0(sizeof(TestValObj)))
    t1.a = a
    t1.b = b
    result = t1

  proc newTestVal2(s: string): TestVal2 =
    let t2 = cast[TestVal2](allocShared0(sizeof(TestVal2Obj) + s.len))
    copyMem(addr t2.s, unsafeAddr s[0], s.len)
    t2.len = s.len
    result = t2

  proc `$`(val: TestVal2): string =
    cast[ptr UncheckedArray[byte]](addr val.s).toString(val.len)

  proc freeVal[T](val: T) =
    when T is TestVal:
      val.deallocShared()
    elif T is TestVal2:
      val.deallocShared()

  loadUthashModules()

  var kv: KVHandle[TestVal]
  var kv2: KVHandle[TestVal2]

  for i in 1..5:
    kv[i.toBytesBE] = newTestVal(i, 0)

  for i in 1..5:
    kv[i.toBytesBE] = newTestVal(i, i)

  for d in kv.items:
    echo d
  echo "len=", kv.len

  kv.sort(proc (a, b: KVPair[TestVal]): cint {.cdecl.} =
    result = (b.val.a - a.val.a).cint
  )

  for d in kv.items:
    echo d
  echo "len=", kv.len

  kv.clear()
  echo "len=", kv.len

  for i in 1..5:
    kv2[i.toBytesBE] = newTestVal2("test" & $i)

  for d in kv2.items:
    echo d
  echo "len=", kv2.len

  kv2.sort(proc (a, b: KVPair[TestVal2]): cint {.cdecl.} =
    result = cmp($b.val, $a.val).cint
  )

  for d in kv2.items:
    echo d
  echo "len=", kv2.len

  kv2.clear()
  echo "len=", kv2.len

  for j in 0..4:
    for i in 1..5:
      kv.add(i.toBytesBE, newTestVal(i, i + j * 5))

  for d in kv.items:
    echo d
  echo "len=", kv.len

  echo kv[1.toBytesBE]
  for d in kv.items(1.toBytesBE):
    echo d

  echo "exists"
  echo kv.itemExists()
  echo kv.itemExists(1.toBytesBE)
  echo kv.itemExists(6.toBytesBE)

  echo "del"
  kv.del(3.toBytesBE)

  for d in kv.items:
    echo d
