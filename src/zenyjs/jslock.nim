# Copyright (c) 2022 zenywallet

import jsffi
import jslib
import asyncjs
import macros

type
  Lock = object
    id: int

var lockId {.compileTime.} = 0

macro getLockId(): untyped =
  inc(lockId)
  newLit(lockId)

template newLock*(): Lock =
  var lock: Lock
  lock.id = getLockId()
  lock

var mutex = [].toJs

proc sleep_async(ms: int): Future[void] {.discardable.} =
  return newPromise do (resolve: proc()):
    setTimeout(resolve, ms)

template sleep(ms: int) = await sleep_async(ms)

proc acquireLock(id: int) {.async, discardable.} =
  mutex.push(id.toJs)
  while mutex[0] != id.toJs:
    sleep(10)

proc releaseLock() =
  mutex.shift()

template lock*(lock: Lock; body: untyped) =
  await acquireLock(lock.id)
  try:
    proc bodyMain() {.async, discardable.} = body
    await bodyMain()
  finally:
    releaseLock()


when isMainModule:
  proc test1() {.async, discardable.} =
    var a1 = newLock()
    echo a1
    lock a1:
      echo "test1"
    lock a1:
      echo "test1"
    lock a1:
      echo "test1-1"
      lock a1:
        echo "test1-2"
      echo "test1-3"

  proc test2() {.async, discardable.} =
    var a2 = newLock()
    echo a2
    lock a2:
      echo "test2"
    lock a2:
      echo "test2"

  test1()
  test2()
