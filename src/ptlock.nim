# Copyright (c) 2021 zenywallet

import posix

type
  RWLock* = Pthread_rwlock

  PthreadLockError* = object of CatchableError


{.push stackTrace: off.}
proc ptlockInit*(a: ptr RWLock) =
  if pthread_rwlock_init(a, nil) != 0:
    raise newException(PthreadLockError, "pthread lock init")

proc ptlockDestroy*(a: ptr RWLock) =
  if pthread_rwlock_destroy(a) != 0:
    raise newException(PthreadLockError, "pthread lock destroy")

proc rdlock*(a: ptr RWLock) =
  if pthread_rwlock_rdlock(a) != 0:
    raise newException(PthreadLockError, "pthread rdlock")

proc wrlock*(a: ptr RWLock) =
  if pthread_rwlock_wrlock(a) != 0:
    raise newException(PthreadLockError, "pthread wrlock")

proc unlock*(a: ptr RWLock) =
  if pthread_rwlock_unlock(a) != 0:
    raise newException(PthreadLockError, "pthread unlock")

template withReadLock*(a: ptr RWLock, body: untyped) =
  if pthread_rwlock_rdlock(a) != 0:
    raise newException(PthreadLockError, "pthread rdlock")
  {.locks: [a].}:
    try:
      body
    finally:
      if pthread_rwlock_unlock(a) != 0:
        raise newException(PthreadLockError, "pthread unlock")

template withWriteLock*(a: ptr RWLock, body: untyped) =
  if pthread_rwlock_wrlock(a) != 0:
    raise newException(PthreadLockError, "pthread wrlock")
  {.locks: [a].}:
    try:
      body
    finally:
      if pthread_rwlock_unlock(a) != 0:
        raise newException(PthreadLockError, "pthread unlock")
{.pop.}
