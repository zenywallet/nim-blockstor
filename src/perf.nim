# Copyright (c) 2021 zenywallet

import std/times, strFormat
import ptlock

var elapsedTimes: array[256, float]

var spinLocks: array[256, SpinLock]
for i in 0..spinLocks.high:
  spinLockInit(spinLocks[i])

template perfMonitor*(perfId: int, body: untyped) =
  let startTime = epochTime()
  body
  let endTime = epochTime()
  let elapsed = endTime - startTime
  withSpinLock spinLocks[perfId]:
    elapsedTimes[perfId] = elapsedTimes[perfId] + elapsed

template perfMonitor*(perfId: enum, body: untyped) = perfMonitor(perfId.int, body)

proc showPerfResult*(halt: bool = false) =
  for i, elapsed in elapsedTimes:
    if elapsed > 0:
      echo fmt"{i}: {elapsed:.3f}"
  if halt:
    echo "--- halt ---"
    discard readLine(stdin)


when isMainModule:
  import os

  type
    SomePerf = enum
      Perf1 = 1
      Perf2
      Perf100 = 100

  perfMonitor Perf1:
    echo Perf1
    sleep(1000)
    echo "end"

  perfMonitor Perf2:
    echo Perf2
    sleep(500)
    echo "end"

  perfMonitor Perf100:
    echo Perf100
    sleep(3111)
    echo "end"

  perfMonitor Perf1:
    echo Perf1
    sleep(123)
    echo "end"

  showPerfResult(true)
