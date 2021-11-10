# Copyright (c) 2021 zenywallet

import posix

type
  RWLock* = Pthread_rwlock

  PthreadLockError* = object of CatchableError


{.push stackTrace: off.}
proc rwlockInit*(a: var RWLock) =
  if pthread_rwlock_init(addr a, nil) != 0:
    raise newException(PthreadLockError, "pthread lock init")

proc rwlockDestroy*(a: var RWLock) =
  if pthread_rwlock_destroy(addr a) != 0:
    raise newException(PthreadLockError, "pthread lock destroy")

proc rdlock*(a: var RWLock) =
  if pthread_rwlock_rdlock(addr a) != 0:
    raise newException(PthreadLockError, "pthread rdlock")

proc wrlock*(a: var RWLock) =
  if pthread_rwlock_wrlock(addr a) != 0:
    raise newException(PthreadLockError, "pthread wrlock")

proc unlock*(a: var RWLock) =
  if pthread_rwlock_unlock(addr a) != 0:
    raise newException(PthreadLockError, "pthread unlock")

template withReadLock*(a: var RWLock, body: untyped) =
  if pthread_rwlock_rdlock(addr a) != 0:
    raise newException(PthreadLockError, "pthread rdlock")
  {.locks: [a].}:
    try:
      body
    finally:
      if pthread_rwlock_unlock(addr a) != 0:
        raise newException(PthreadLockError, "pthread unlock")

template withWriteLock*(a: var RWLock, body: untyped) =
  if pthread_rwlock_wrlock(addr a) != 0:
    raise newException(PthreadLockError, "pthread wrlock")
  {.locks: [a].}:
    try:
      body
    finally:
      if pthread_rwlock_unlock(addr a) != 0:
        raise newException(PthreadLockError, "pthread unlock")
{.pop.}
