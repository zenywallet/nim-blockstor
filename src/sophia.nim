# Copyright (c) 2019 zenywallet

import os, algorithm

const libsophiaPath = splitPath(currentSourcePath()).head / "../deps/sophia"
{.passL: libsophiaPath / "libsophia.a".}

type
  Sophia* = ref object
    env: pointer
    db: pointer
    name: pointer
  SophiaErr* = object of CatchableError
  int64_t* = int64

proc sp_env*(): pointer {.importc.}
proc sp_document*(a1: pointer): pointer {.importc.}
proc sp_setstring*(a1: pointer; a2: cstring; a3: pointer; a4: cint): cint {.importc.}
proc sp_setint*(a1: pointer; a2: cstring; a3: int64_t): cint {.importc.}
proc sp_getobject*(a1: pointer; a2: cstring): pointer {.importc.}
proc sp_getstring*(a1: pointer; a2: cstring; a3: ptr cint): pointer {.importc.}
proc sp_getint*(a1: pointer; a2: cstring): int64_t {.importc.}
proc sp_open*(a1: pointer): cint {.importc.}
proc sp_destroy*(a1: pointer): cint {.importc.}
proc sp_error*(a1: pointer): cint {.importc.}
proc sp_service*(a1: pointer): cint {.importc.}
proc sp_poll*(a1: pointer): pointer {.importc.}
proc sp_drop*(a1: pointer): cint {.importc.}
proc sp_set*(a1: pointer; a2: pointer): cint {.importc.}
proc sp_upsert*(a1: pointer; a2: pointer): cint {.importc.}
proc sp_delete*(a1: pointer; a2: pointer): cint {.importc.}
proc sp_get*(a1: pointer; a2: pointer): pointer {.importc.}
proc sp_cursor*(a1: pointer): pointer {.importc.}
proc sp_begin*(a1: pointer): pointer {.importc.}
proc sp_prepare*(a1: pointer): cint {.importc.}
proc sp_commit*(a1: pointer): cint {.importc.}
proc free(p: pointer) {.header: "<stdlib.h>", importc: "free".}

template checkErr(err: cint) {.dirty.} =
  if err != 0:
    if not sophia.env.isNil:
      var size: cint
      var errptr: pointer = sophia.env.sp_getstring("sophia.error", addr size)
      if size > 0:
        var errmsg = $cast[cstring](errptr)
        free(errptr)
        raise newException(SophiaErr, errmsg)
      else:
        raise newException(SophiaErr, "unknown")
    else:
      raise newException(SophiaErr, "env is nil")

template checkErr(env: pointer, err: cint) =
  if err != 0:
    if not env.isNil:
      var size: cint
      var errptr: pointer = env.sp_getstring("sophia.error", addr size)
      if size > 0:
        var errmsg = $cast[cstring](errptr)
        free(errptr)
        raise newException(SophiaErr, errmsg)
      else:
        raise newException(SophiaErr, "unknown")
    else:
      raise newException(SophiaErr, "env is nil")

proc open*(sophia: Sophia, dbpath, dbname: string) =
  sophia.env = sp_env()
  if sophia.env.isNil:
    raise newException(SophiaErr, "env is nil")
  checkErr sophia.env.sp_setstring("backup.path", "backup".cstring, 0)
  checkErr sophia.env.sp_setint("log.enable", 1)
  checkErr sophia.env.sp_setint("scheduler.threads", 4)
  checkErr sophia.env.sp_setstring("sophia.path", dbpath.cstring, 0)
  checkErr sophia.env.sp_setstring("db", dbname.cstring, 0)
  checkErr sophia.env.sp_setint(cstring("db." & dbname & ".compaction.cache"), 128 * 1024 * 1024)
  checkErr sophia.env.sp_setint(cstring("db." & dbname & ".compaction.gc_period"), 0)
  checkErr sophia.env.sp_open()
  sophia.db = sophia.env.sp_getobject(cstring("db." & dbname))
  if sophia.db.isNil:
    raise newException(SophiaErr, "db is nil")
  sophia.name = allocShared0(dbname.len + 1)
  copyMem(sophia.name, dbname.cstring, dbname.len)

proc open*(sophia: Sophia, dbpath: string) =
  var path = splitPath(dbpath)
  open(sophia, path.head, path.tail)

proc opens*(dbpath: string, dbnames: seq[string]): seq[Sophia] =
  var env = sp_env()
  if env.isNil:
    raise newException(SophiaErr, "env is nil")
  env.checkErr env.sp_setstring("backup.path", "backup".cstring, 0)
  env.checkErr env.sp_setint("log.enable", 1)
  env.checkErr env.sp_setint("scheduler.threads", 4)
  env.checkErr env.sp_setstring("sophia.path", dbpath.cstring, 0)

  for dbname in dbnames:
    env.checkErr env.sp_setstring("db", dbname.cstring, 0)
    env.checkErr env.sp_setint(cstring("db." & dbname & ".compaction.cache"), 128 * 1024 * 1024)
    env.checkErr env.sp_setint(cstring("db." & dbname & ".compaction.gc_period"), 0)
    var sophia = new Sophia
    sophia.env = env
    sophia.db = env.sp_getobject(cstring("db." & dbname))
    if sophia.db.isNil:
      raise newException(SophiaErr, "db is nil")
    sophia.name = allocShared0(dbname.len + 1)
    copyMem(sophia.name, dbname.cstring, dbname.len)
    result.add(sophia)
  env.checkErr env.sp_open()

  for dbname in dbnames:
    echo "index count ", dbname, "=", env.sp_getint(cstring("db." & dbname & ".index.count"))

proc close*(sophia: Sophia) =
  sophia.name.deallocShared()
  checkErr sophia.env.sp_destroy()

proc close*(sophias: seq[Sophia]) =
  if sophias.len > 0:
    for s in sophias:
      s.name.deallocShared()
    let sophia = sophias[0]
    checkErr sophia.env.sp_destroy()

proc checkpoint*(sophia: Sophia) =
  checkErr sophia.env.sp_setint(cstring("db." & $cast[cstring](sophia.name) & ".compaction.checkpoint"), 0)
  checkErr sophia.env.sp_setint("scheduler.run", 0)

proc backupRun*(sophia: Sophia) =
  checkErr sophia.env.sp_setint("backup.run", 0)

proc put*(sophia: Sophia, key: openarray[byte], value: openarray[byte]) =
  var o = sophia.db.sp_document()
  if o.isNil:
    raise newException(SophiaErr, "document is nil")
  checkErr o.sp_setstring("key", cast[pointer](unsafeAddr key[0]), key.len.cint)
  checkErr o.sp_setstring("value", cast[pointer](unsafeAddr value[0]), value.len.cint)
  checkErr sophia.db.sp_set(o)

proc get*(sophia: Sophia, key: openarray[byte]): seq[byte] =
  var o = sophia.db.sp_document()
  if o.isNil:
    raise newException(SophiaErr, "document is nil")
  checkErr o.sp_setstring("key", cast[pointer](unsafeAddr key[0]), key.len.cint)
  o = sophia.db.sp_get(o)
  if o.isNil:
    return
  var valsize: cint
  var valptr = o.sp_getstring("value", addr valsize)
  var valb: seq[byte] = newSeq[byte](valsize)
  if not valptr.isNil and valsize > 0:
    copyMem(addr valb[0], cast[ptr byte](valptr), valb.len)
  checkErr o.sp_destroy()
  result = valb

iterator gets*(sophia: Sophia, key: openarray[byte]): tuple[key: seq[byte], val: seq[byte]] =
  var cursor = sophia.env.sp_cursor()
  var o = sophia.db.sp_document()
  if o.isNil:
    raise newException(SophiaErr, "document is nil")
  checkErr o.sp_setstring("key", cast[pointer](unsafeAddr key[0]), key.len.cint)
  o = sp_get(cursor, o)
  block loop:
    while not o.isNil:
      var keysize: cint = 0
      var keyptr = o.sp_getstring("key", addr keysize)
      if not keyptr.isNil and keysize >= key.len:
        var keyb: seq[byte] = newSeq[byte](keysize)
        copyMem(addr keyb[0], cast[ptr byte](keyptr), keyb.len)
        var i = key.high
        while i >= 0:
          if keyb[i] != key[i]:
            break loop
          dec(i)
        var valsize: cint = 0
        var valptr = o.sp_getstring("value", addr valsize)
        var valb: seq[byte] = newSeq[byte](valsize)
        if not valptr.isNil and valsize > 0:
          copyMem(addr valb[0], cast[ptr byte](valptr), valb.len)
        yield (key: keyb, val: valb)
      else:
        break loop
      o = sp_get(cursor, o)
  checkErr cursor.sp_destroy()

iterator gets*(sophia: Sophia, startkey: openarray[byte],
              endkey: openarray[byte]): tuple[key: seq[byte], val: seq[byte]] =
  var cursor = sophia.env.sp_cursor()
  var o = sophia.db.sp_document()
  if o.isNil:
    raise newException(SophiaErr, "document is nil")
  if startkey.len != endkey.len:
    raise newException(SophiaErr, "key different lengths")
  checkErr o.sp_setstring("key", cast[pointer](unsafeAddr startkey[0]), startkey.len.cint)
  o = sp_get(cursor, o)
  block loop:
    while not o.isNil:
      var keysize: cint = 0
      var keyptr = o.sp_getstring("key", addr keysize)
      if not keyptr.isNil and keysize >= endkey.len:
        var keyb: seq[byte] = newSeq[byte](keysize)
        copyMem(addr keyb[0], cast[ptr byte](keyptr), keyb.len)
        for i in 0..endkey.high:
          if keyb[i] > endkey[i]:
            break loop
        var valsize: cint = 0
        var valptr = o.sp_getstring("value", addr valsize)
        var valb: seq[byte] = newSeq[byte](valsize)
        if not valptr.isNil and valsize > 0:
          copyMem(addr valb[0], cast[ptr byte](valptr), valb.len)
        yield (key: keyb, val: valb)
      else:
        break loop
      o = sp_get(cursor, o)
  checkErr cursor.sp_destroy()

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

iterator getsRev*(sophia: Sophia, key: openarray[byte]): tuple[key: seq[byte], val: seq[byte]] =
  var cursor = sophia.env.sp_cursor()
  var o = sophia.db.sp_document()
  if o.isNil:
    raise newException(SophiaErr, "document is nil")
  let (carry, lastkey) = key_countup(key)
  if carry:
    checkErr o.sp_setstring("order", "<=".cstring, 0)
  else:
    checkErr o.sp_setstring("order", "<".cstring, 0)
  checkErr o.sp_setstring("key", cast[pointer](unsafeAddr lastkey[0]), lastkey.len.cint)
  o = sp_get(cursor, o)
  block loop:
    while not o.isNil:
      var keysize: cint = 0
      var keyptr = o.sp_getstring("key", addr keysize)
      var keyb: seq[byte] = newSeq[byte](keysize)
      if not keyptr.isNil and keysize >= key.len:
        copyMem(addr keyb[0], cast[ptr byte](keyptr), keyb.len)
        var i = key.high
        if keyb.high < i:
          break loop
        while i >= 0:
          if keyb[i] != key[i]:
            break loop
          dec(i)
        var valsize: cint = 0
        var valptr = o.sp_getstring("value", addr valsize)
        var valb: seq[byte] = newSeq[byte](valsize)
        if not valptr.isNil and valsize > 0:
          copyMem(addr valb[0], cast[ptr byte](valptr), valb.len)
        yield (key: keyb, val: valb)
      else:
        break loop
      o = sp_get(cursor, o)
  checkErr cursor.sp_destroy()

iterator getsRev*(sophia: Sophia, startkey: openarray[byte],
                  endkey: openarray[byte]): tuple[key: seq[byte], val: seq[byte]] =
  var cursor = sophia.env.sp_cursor()
  var o = sophia.db.sp_document()
  if o.isNil:
    raise newException(SophiaErr, "document is nil")
  if startkey.len != endkey.len:
    raise newException(SophiaErr, "key different lengths")
  let (carry, lastkey) = key_countup(startkey)
  if carry:
    checkErr o.sp_setstring("order", "<=".cstring, 0)
  else:
    checkErr o.sp_setstring("order", "<".cstring, 0)
  checkErr o.sp_setstring("key", cast[pointer](unsafeAddr lastkey[0]), lastkey.len.cint)
  o = sp_get(cursor, o)
  block loop:
    while not o.isNil:
      var keysize: cint = 0
      var keyptr = o.sp_getstring("key", addr keysize)
      var keyb: seq[byte] = newSeq[byte](keysize)
      if not keyptr.isNil and keysize >= endkey.len:
        copyMem(addr keyb[0], cast[ptr byte](keyptr), keyb.len)
        for i in 0..endkey.high:
          if keyb[i] < endkey[i]:
            break loop
        var valsize: cint = 0
        var valptr = o.sp_getstring("value", addr valsize)
        var valb: seq[byte] = newSeq[byte](valsize)
        if not valptr.isNil and valsize > 0:
          copyMem(addr valb[0], cast[ptr byte](valptr), valb.len)
        yield (key: keyb, val: valb)
      else:
        break loop
      o = sp_get(cursor, o)
  checkErr cursor.sp_destroy()

proc del*(sophia: Sophia, key: openarray[byte]) =
  var o = sophia.db.sp_document()
  if o.isNil:
    raise newException(SophiaErr, "document is nil")
  checkErr o.sp_setstring("key", cast[pointer](unsafeAddr key[0]), key.len.cint)
  checkErr sophia.db.sp_delete(o)


when isMainModule:
  var db = new Sophia
  db.open("dbpath/dbname")

  block test1:
    var key = @[byte 1]
    var val = @[byte 1]
    db.put(key, val)
    echo db.get(key)
    db.del(key)
    echo db.get(key)

  block test2:
    for i in 1.byte..3.byte:
      for j in 1.byte..3.byte:
        var key = @[byte 1, i, j]
        var val = @[byte 1]
        db.put(key, val)

    var key = @[byte 1, 2]
    for d in db.gets(key):
      echo d
    for d in db.getsRev(key):
      echo d

  db.close()
