# Copyright (c) 2019 zenywallet

import rocksdb, cpuinfo, algorithm

type
  RocksDb* = ref object
    db: rocksdb_t
    dbpath: cstring
    dbpathBackup: cstring
    options: rocksdb_options_t
    readOptions*: rocksdb_readoptions_t
    writeOptions*: rocksdb_writeoptions_t
    be: rocksdb_backup_engine_t
    err: cstring

  KeyType = openarray[byte]
  ValueType = openarray[byte]

  RocksDbErr* = object of CatchableError

  ResultKeyValue* = object
    key*: seq[byte]
    val*: seq[byte]

template rocksdb_checkerr* {.dirty.} =
  if not rocks.err.isNil:
    let err_msg: string = $rocks.err
    rocksdb_free(rocks.err)
    raise newException(RocksDbErr, err_msg)

proc open*(rocks: RocksDb, dbpath: cstring, dbpathBackup: cstring = "",
          total_threads: int32 = cpuinfo.countProcessors().int32) =
  rocks.options = rocksdb_options_create()
  rocksdb_options_increase_parallelism(rocks.options, total_threads)
  rocksdb_options_set_create_if_missing(rocks.options, 1)
  rocksdb_options_set_compression(rocks.options, rocksdb_lz4_compression)
  rocks.readOptions = rocksdb_readoptions_create()
  rocks.writeOptions = rocksdb_writeoptions_create()
  rocks.dbpath = dbpath
  rocks.db = rocksdb_open(rocks.options, rocks.dbpath, rocks.err.addr)
  rocksdb_checkerr
  if dbpathBackup.len > 0:
    rocks.be = rocksdb_backup_engine_open(rocks.options, dbpathBackup, rocks.err.addr)
    rocksdb_checkerr
    rocksdb_backup_engine_create_new_backup(rocks.be, rocks.db, rocks.err.addr)
    rocksdb_checkerr

proc close*(rocks: RocksDb) =
  if not rocks.err.isNil:
    rocksdb_free(rocks.err)
    rocks.err = nil
  if not rocks.writeOptions.isNil:
    rocksdb_writeoptions_destroy(rocks.writeOptions)
    rocks.writeOptions = nil
  if not rocks.readOptions.isNil:
    rocksdb_readoptions_destroy(rocks.readOptions)
    rocks.readOptions = nil
  if not rocks.options.isNil:
    rocksdb_options_destroy(rocks.options)
    rocks.options = nil
  if not rocks.be.isNil:
    rocksdb_backup_engine_close(rocks.be)
    rocks.be = nil
  if not rocks.db.isNil:
    rocksdb_close(rocks.db)
    rocks.db = nil

proc put*(rocks: RocksDb, key: KeyType, val: ValueType) =
  rocksdb_put(rocks.db,
    rocks.writeOptions,
    cast[cstring](unsafeAddr key[0]), key.len.csize_t,
    cast[cstring](if val.len > 0: unsafeAddr val[0] else: nil), val.len.csize_t,
    rocks.err.addr)
  rocksdb_checkerr

proc get*(rocks: RocksDb, key: KeyType): seq[byte] =
  var len: csize_t
  var data = rocksdb_get(rocks.db, rocks.readOptions,
    cast[cstring](unsafeAddr key[0]), key.len.csize_t,
    addr len, rocks.err.addr)
  rocksdb_checkerr
  var s: seq[byte] = newSeq[byte](len)
  if not data.isNil and len > 0:
    copyMem(addr s[0], unsafeAddr data[0], s.len)
  result = s

proc del*(rocks: RocksDb, key: KeyType) =
  rocksdb_delete(rocks.db, rocks.writeOptions, cast[cstring](unsafeAddr key[0]),
                key.len.csize_t, rocks.err.addr)
  rocksdb_checkerr

proc get_iter_key_value(iter: rocksdb_iterator_t): ResultKeyValue =
  var key_str, value_str: cstring
  var key_len, value_len: csize_t
  key_str = rocksdb_iter_key(iter, addr key_len)
  value_str = rocksdb_iter_value(iter, addr value_len)
  var key_seq: seq[byte] = newSeq[byte](key_len)
  var value_seq: seq[byte] = newSeq[byte](value_len)
  if key_len > 0:
    copyMem(addr key_seq[0], unsafeAddr key_str[0], key_seq.len)
  if value_len > 0:
    copyMem(addr value_seq[0], unsafeAddr value_str[0], value_seq.len)
  result = ResultKeyValue(key: key_seq, val: value_seq)

proc gets*(rocks: RocksDb, key: KeyType): seq[ResultKeyValue] =
  var iter: rocksdb_iterator_t = rocksdb_create_iterator(rocks.db, rocks.readOptions)
  rocksdb_iter_seek(iter, cast[cstring](unsafeAddr key[0]), key.len.csize_t)
  block next:
    while cast[bool](rocksdb_iter_valid(iter)):
      let kv = get_iter_key_value(iter)
      var i = key.high
      if kv.key.high < i:
        break next
      while i >= 0:
        if kv.key[i] != key[i]:
          break next
        dec(i)
      result.add(get_iter_key_value(iter))
      rocksdb_iter_next(iter)
  rocksdb_iter_destroy(iter)

iterator gets*(rocks: RocksDb, key: KeyType): ResultKeyValue =
  var iter: rocksdb_iterator_t
  try:
    iter = rocksdb_create_iterator(rocks.db, rocks.readOptions)
    rocksdb_iter_seek(iter, cast[cstring](unsafeAddr key[0]), key.len.csize_t)
    block next:
      while cast[bool](rocksdb_iter_valid(iter)):
        let kv = get_iter_key_value(iter)
        var i = key.high
        if kv.key.high < i:
          break next
        while i >= 0:
          if kv.key[i] != key[i]:
            break next
          dec(i)
        yield kv
        rocksdb_iter_next(iter)
  finally:
    if not iter.isNil:
      rocksdb_iter_destroy(iter)
      iter = nil

iterator gets_nobreak*(rocks: RocksDb, key: KeyType): ResultKeyValue =
  var iter: rocksdb_iterator_t
  try:
    iter = rocksdb_create_iterator(rocks.db, rocks.readOptions)
    rocksdb_iter_seek(iter, cast[cstring](unsafeAddr key[0]), key.len.csize_t)
    while cast[bool](rocksdb_iter_valid(iter)):
      let kv = get_iter_key_value(iter)
      yield kv
      rocksdb_iter_next(iter)
  finally:
    if not iter.isNil:
      rocksdb_iter_destroy(iter)
      iter = nil

proc dels*(rocks: RocksDb, key: KeyType) =
  for d in rocks.gets(key):
    rocks.del(d.key)

proc key_countup(key: openarray[byte]): tuple[carry: bool, key: seq[byte]] =
  var k = newSeq[byte](key.len)
  var carry = true
  for i in countdown(key.high, 0):
    if carry:
      k[i] = (key[i] + 1) and 0xff
      if k[i] != 0:
        carry = false
    else:
      k[i] = key[i]
  if carry:
    k.fill(0xff)
  (carry, k)

proc getsRev*(rocks: RocksDb, key: KeyType): seq[ResultKeyValue] =
  var iter: rocksdb_iterator_t = rocksdb_create_iterator(rocks.db, rocks.readOptions)
  let (carry, lastkey) = key_countup(key)
  if carry:
    rocksdb_iter_seek(iter, cast[cstring](unsafeAddr lastkey[0]), lastkey.len.csize_t)
  else:
    rocksdb_iter_seek_for_prev(iter, cast[cstring](unsafeAddr lastkey[0]), lastkey.len.csize_t)
  block prev:
    if cast[bool](rocksdb_iter_valid(iter)):
      let kv = get_iter_key_value(iter)
      var i = key.high
      if kv.key.high < i:
        break prev
      if kv.key.high != lastkey.high or kv.key != lastkey:
        while i >= 0:
          if kv.key[i] != key[i]:
            break prev
          dec(i)
        result.add(get_iter_key_value(iter))
      rocksdb_iter_prev(iter)
    while cast[bool](rocksdb_iter_valid(iter)):
      let kv = get_iter_key_value(iter)
      var i = key.high
      if kv.key.high < i:
        break prev
      while i >= 0:
        if kv.key[i] != key[i]:
          break prev
        dec(i)
      result.add(get_iter_key_value(iter))
      rocksdb_iter_prev(iter)
  rocksdb_iter_destroy(iter)

iterator getsRev*(rocks: RocksDb, key: KeyType): ResultKeyValue =
  var iter: rocksdb_iterator_t
  try:
    iter = rocksdb_create_iterator(rocks.db, rocks.readOptions)
    let (carry, lastkey) = key_countup(key)
    if carry:
      rocksdb_iter_seek(iter, cast[cstring](unsafeAddr lastkey[0]), lastkey.len.csize_t)
    else:
      rocksdb_iter_seek_for_prev(iter, cast[cstring](unsafeAddr lastkey[0]), lastkey.len.csize_t)
    block prev:
      if cast[bool](rocksdb_iter_valid(iter)):
        let kv = get_iter_key_value(iter)
        var i = key.high
        if kv.key.high < i:
          break prev
        if kv.key.high != lastkey.high or kv.key != lastkey:
          while i >= 0:
            if kv.key[i] != key[i]:
              break prev
            dec(i)
          yield kv
        rocksdb_iter_prev(iter)
      while cast[bool](rocksdb_iter_valid(iter)):
        let kv = get_iter_key_value(iter)
        var i = key.high
        if kv.key.high < i:
          break prev
        while i >= 0:
          if kv.key[i] != key[i]:
            break prev
          dec(i)
        yield kv
        rocksdb_iter_prev(iter)
  finally:
    if not iter.isNil:
      rocksdb_iter_destroy(iter)
      iter = nil

iterator getsRev_nobreak*(rocks: RocksDb, key: KeyType): ResultKeyValue =
  var iter: rocksdb_iterator_t
  try:
    iter = rocksdb_create_iterator(rocks.db, rocks.readOptions)
    rocksdb_iter_seek(iter, cast[cstring](unsafeAddr key[0]), key.len.csize_t)
    let (carry, lastkey) = key_countup(key)
    if carry:
      rocksdb_iter_seek(iter, cast[cstring](unsafeAddr lastkey[0]), lastkey.len.csize_t)
    else:
      rocksdb_iter_seek_for_prev(iter, cast[cstring](unsafeAddr lastkey[0]), lastkey.len.csize_t)
    if cast[bool](rocksdb_iter_valid(iter)):
      let kv = get_iter_key_value(iter)
      if kv.key.high != lastkey.high or kv.key != lastkey:
        yield kv
      rocksdb_iter_prev(iter)
    while cast[bool](rocksdb_iter_valid(iter)):
      let kv = get_iter_key_value(iter)
      yield kv
      rocksdb_iter_prev(iter)
  finally:
    #rocksdb_iter_destroy(iter)
    # 1.4.2 don't work
    # 1.2.8 don't work
    # 1.2.6 work
    # 1.2.0 work

    # workaround
    # destroy is called twice in nim 1.2.8 and above

    if not iter.isNil:
      rocksdb_iter_destroy(iter)
      iter = nil

iterator gets*(rocks: RocksDb, startkey: openarray[byte],
              endkey: openarray[byte]): ResultKeyValue =
  var iter: rocksdb_iterator_t
  if startkey.len != endkey.len:
    raise newException(RocksDbErr, "key different lengths")
  try:
    iter = rocksdb_create_iterator(rocks.db, rocks.readOptions)
    rocksdb_iter_seek(iter, cast[cstring](unsafeAddr startkey[0]), startkey.len.csize_t)
    block next:
      while cast[bool](rocksdb_iter_valid(iter)):
        let kv = get_iter_key_value(iter)
        if kv.key.high < endkey.high:
          break next
        for i in 0..endkey.high:
          if kv.key[i] > endkey[i]:
            break next
        yield kv
        rocksdb_iter_next(iter)
  finally:
    if not iter.isNil:
      rocksdb_iter_destroy(iter)
      iter = nil

iterator getsRev*(rocks: RocksDb, startkey: openarray[byte],
                  endkey: openarray[byte]): ResultKeyValue =
  var iter: rocksdb_iterator_t
  if startkey.len != endkey.len:
    raise newException(RocksDbErr, "key different lengths")
  try:
    iter = rocksdb_create_iterator(rocks.db, rocks.readOptions)
    let (carry, lastkey) = key_countup(startkey)
    if carry:
      rocksdb_iter_seek(iter, cast[cstring](unsafeAddr lastkey[0]), lastkey.len.csize_t)
    else:
      rocksdb_iter_seek_for_prev(iter, cast[cstring](unsafeAddr lastkey[0]), lastkey.len.csize_t)
    block prev:
      if cast[bool](rocksdb_iter_valid(iter)):
        let kv = get_iter_key_value(iter)
        if kv.key.high < endkey.high:
          break prev
        for i in 0..endkey.high:
          if kv.key[i] < endkey[i]:
            break prev
        if kv.key.high != lastkey.high or kv.key != lastkey:
          yield kv
        rocksdb_iter_prev(iter)
      while cast[bool](rocksdb_iter_valid(iter)):
        let kv = get_iter_key_value(iter)
        if kv.key.high < endkey.high:
          break prev
        for i in 0..endkey.high:
          if kv.key[i] < endkey[i]:
            break prev
        yield kv
        rocksdb_iter_prev(iter)
  finally:
    if not iter.isNil:
      rocksdb_iter_destroy(iter)
      iter = nil
