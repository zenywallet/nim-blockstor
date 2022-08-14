# Copyright (c) 2022 zenywallet

import jsffi
import jslib
import asyncjs
import macros
import times

type
  Lock = object
    id: int

var mutex = JsObject{}

var lockId {.compileTime.} = 0

macro getLockId(): untyped =
  inc(lockId)
  newLit(lockId)

template newLock*(): Lock =
  var lock: Lock
  lock.id = getLockId()
  mutex[lock.id] = [].toJs
  lock

type ReqId = cstring

proc getReqId(): ReqId = Math.random().to(cstring) & "-" & $epochTime()

proc acquireLock(id: int, reqId: ReqId) {.async, discardable.} =
  mutex[id].push(reqId.toJs)
  while mutex[id][0] != reqId.toJs:
    sleep(10)

proc releaseLock(id: int) =
  mutex[id].shift()

template lock*(lock: Lock; body: untyped) =
  let reqId = getReqId()
  await acquireLock(lock.id, reqId)
  try:
    proc bodyMain() {.async, discardable.} = body
    await bodyMain()
  finally:
    releaseLock(lock.id)


when isMainModule:
  var a1 = newLock()
  var a2 = newLock()

  proc test1() {.async, discardable.} =
    lock a1:
      echo "test1-1"
      sleep(500)
      lock a2:
        echo "test1-2"
        sleep(500)

  proc test2() {.async, discardable.} =
    lock a1:
      echo "test2-1"
      sleep(500)
      lock a2:
        echo "test2-2"
        sleep(500)

  test1()
  test2()
