# Copyright (c) 2021 zenywallet

import posix

type
  PthreadLockError* = object of CatchableError


{.push stackTrace: off.}
proc ptlockInit*(a: ptr Pthread_rwlock) =
  if pthread_rwlock_init(a, nil) != 0:
    raise newException(PthreadLockError, "pthread lock init")

proc ptlockDestroy*(a: ptr Pthread_rwlock) =
  if pthread_rwlock_destroy(a) != 0:
    raise newException(PthreadLockError, "pthread lock destroy")

proc rdlock*(a: ptr Pthread_rwlock) =
  if pthread_rwlock_rdlock(a) != 0:
    raise newException(PthreadLockError, "pthread rdlock")

proc rwlock*(a: ptr Pthread_rwlock) =
  if pthread_rwlock_wrlock(a) != 0:
    raise newException(PthreadLockError, "pthread rwlock")

proc unlock*(a: ptr Pthread_rwlock) =
  if pthread_rwlock_unlock(a) != 0:
    raise newException(PthreadLockError, "pthread unlock")

template withReadLock*(a: ptr Pthread_rwlock, body: untyped) =
  if pthread_rwlock_rdlock(a) != 0:
    raise newException(PthreadLockError, "pthread rdlock")
  {.locks: [a].}:
    try:
      body
    finally:
      if pthread_rwlock_unlock(a) != 0:
        raise newException(PthreadLockError, "pthread unlock")

template withWriteLock*(a: ptr Pthread_rwlock, body: untyped) =
  if pthread_rwlock_wrlock(a) != 0:
    raise newException(PthreadLockError, "pthread rwlock")
  {.locks: [a].}:
    try:
      body
    finally:
      if pthread_rwlock_unlock(a) != 0:
        raise newException(PthreadLockError, "pthread unlock")
{.pop.}
