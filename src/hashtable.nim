# Copyright (c) 2021 zenywallet

type
  HashTableDataObj*[Key, Val] {.packed.} = object
    key*: Key
    val*: Val

  HashTableData*[Key, Val] = ptr HashTableDataObj[Key, Val]

  HashTable*[Key, Val] = object
    bitmap*: ptr UncheckedArray[byte]
    bitmapSize*: int

    table*: ptr UncheckedArray[HashTableDataObj[Key, Val]]
    tableSize*: int

    tableBuf*: ptr UncheckedArray[byte]
    tableBufSize*: int

    dataSize*: int
    dataLen*: int
    dataCount*: int

  HashTableError* = object of CatchableError


template loadHashTableModules*() {.dirty.} =
  import std/bitops

  when not declared(DISABLE_HASHTABLEDATA_DELETE):
    const DISABLE_HASHTABLEDATA_DELETE = defined(DISABLE_HASHTABLEDATA_DELETE)
  when not DISABLE_HASHTABLEDATA_DELETE:
    when not declared(empty):
      {.warning: "missing custom proc empty*(pair: HashTableData): bool".}
      proc empty*(pair: HashTableData): bool = false
    when not declared(setEmpty):
      {.warning: "missing custom proc setEmpty*(pair: HashTableData)".}
      proc setEmpty*(pair: HashTableData) = discard
    when not declared(empty) or not declared(setEmpty):
      {.hint: "to disable hashtable data deletion, define DISABLE_HASHTABLEDATA_DELETE".}

  proc newHashTable*[Key, Val](dataLen: int): var HashTable[Key, Val] =
    var hashTable = cast[ptr HashTable[Key, Val]](allocShared0(sizeof(HashTable[Key, Val])))
    hashTable.dataSize = sizeof(HashTableDataObj[Key, Val])
    hashTable.dataLen = dataLen
    hashTable.bitmapSize = (hashTable.dataLen + 7) div 8
    hashTable.tableSize = hashTable.dataSize * dataLen
    hashTable.tableBufSize = hashTable.bitmapSize + hashTable.tableSize
    hashTable.tableBuf = cast[ptr UncheckedArray[byte]](allocShared0(hashTable.tableBufSize))
    hashTable.bitmap = hashTable.tableBuf
    hashTable.table = cast[ptr UncheckedArray[HashTableDataObj[Key, Val]]](addr hashTable.tableBuf[hashTable.bitmapSize])
    result = hashTable[]

  proc delete*(hashTable: var HashTable) =
    hashTable.tableBuf.deallocShared()
    hashTable.addr.deallocShared()

  proc setBitmap*(hashTable: var HashTable, pos: int) =
    let bitPos = pos div 8
    let bitOffset = pos.uint8 and 0x7'u8
    hashTable.bitmap[bitPos].setBit(bitOffset)

  proc getBitmap*(hashTable: var HashTable, pos: int): uint8 =
    let bitPos = pos div 8
    let bitOffset = pos.uint8 and 0x7'u8
    result = hashTable.bitmap[bitPos].testBit(bitOffset).uint8

  proc countBitmap*(hashTable: var HashTable): int =
    let uint64len = hashTable.bitmapSize div 8
    let u8start = hashTable.bitmapSize - (hashTable.bitmapSize.uint8 and 0x7'u8).int
    let bitmap64 = cast[ptr UncheckedArray[uint64]](addr hashTable.bitmap[0])
    for i in 0..<uint64len:
      result = result + countSetBits(bitmap64[i])
    for i in u8start..<hashTable.bitmapSize:
      result = result + countSetBits(hashTable.bitmap[i])

  proc set*(pair: HashTableData, key: HashTableData.Key, val: HashTableData.Val) {.inline.} = pair.key = key; pair.val = val
  proc set*(pair: HashTableData, src: HashTableData) {.inline.} = pair[] = src[]
  proc setKey*(pair: HashTableData, key: HashTableData.Key) {.inline.} = pair.key = key
  proc setVal*(pair: HashTableData, val: HashTableData.Val) {.inline.} = pair.val = val

  proc set*(hashTable: var HashTable, key: HashTable.Key, val: HashTable.Val) =
    var hash = (key.toUint64 mod hashTable.dataLen.uint64).int
    let startHash = hash
    while true:
      let used = hashTable.getBitmap(hash)
      let hashData = addr hashTable.table[hash]
      if used == 0:
        hashTable.setBitmap(hash)
        hashData.set(key, val)
        inc(hashTable.dataCount)
      else:
        when not DISABLE_HASHTABLEDATA_DELETE and declared(empty):
          if hashData.empty:
            hashData.set(key, val)
            inc(hashTable.dataCount)
            break
        if hashData.key == key:
          hashData.setVal(val)
          break
        else:
          inc(hash)
          if hash >= hashTable.dataLen:
            hash = 0
          if hash == startHash:
            raise newException(HashTableError, "hashtable data full")

  proc get*[Key, Val](hashTable: var HashTable[Key, Val], key: Key): HashTableData[Key, Val] =
    var hash = (key.toUint64 mod hashTable.dataLen.uint64).int
    let startHash = hash
    while true:
      let used = hashTable.getBitmap(hash)
      if used == 1:
        let hashData = addr hashTable.table[hash]
        when not DISABLE_HASHTABLEDATA_DELETE and declared(empty):
          if not hashData.empty:
            let hashData = addr hashTable.table[hash]
            if hashData.key == key:
              return hashData
        else:
          if hashData.key == key:
            return hashData
        inc(hash)
        if hash >= hashTable.dataLen:
          hash = 0
        if hash == startHash:
          return nil
      else:
        return nil

  when not DISABLE_HASHTABLEDATA_DELETE and declared(setEmpty):
    proc del*(hashTable: var HashTable, key: HashTable.Key) =
      let pair = hashTable.get(key)
      if pair != nil:
        pair.setEmpty()
        dec(hashTable.dataCount)
  else:
    template del*(hashTable: var HashTable, key: HashTable.Key) = discard

  proc copy*(srcHashTable: var HashTable, dstHashTable: var HashTable) =
    if srcHashTable.dataCount > dstHashTable.dataLen:
      raise newException(HashTableError, "dst is small src=" & $srcHashTable.dataCount & " dst=" & $dstHashTable.dataLen)

    for hash in 0..<srcHashTable.dataLen:
      let used = srcHashTable.getBitmap(hash)
      if used != 0:
        let hashData = addr srcHashTable.table[hash]
        when not DISABLE_HASHTABLEDATA_DELETE and declared(empty):
          if not hashData.empty:
            dstHashTable.set(hashData.key, hashData.val)
        else:
          dstHashTable.set(hashData.key, hashData.val)


when isMainModule:
  import utils, bytes

  #const DISABLE_HASHTABLEDATA_DELETE = false
  proc empty*(pair: HashTableData): bool = pair.val == -1
  proc setEmpty*(pair: HashTableData) = pair.val = -1
  loadHashTableModules()

  proc `$`(data: array[32, byte]): string = data.toBytes.toHex

  var hashTable = newHashTable[array[32, byte], int](30)

  for i in 0..<20:
    hashTable.set(sha256s(i.toBytes), i)

  for i in 0..<20:
    if i mod 2 == 0:
      hashTable.del(sha256s(i.toBytes))

  for i in 0..<20:
    var pair = hashTable.get(sha256s(i.toBytes))
    if not pair.isNil and pair.val == i:
      echo i, " OK ", pair.key
    else:
      if i mod 2 == 0:
        echo i, " OK deleted"
      else:
        echo i, " Error"

  echo "dataCount=", hashTable.dataCount, " bitmapCount=", hashTable.countBitmap()

  var hashTable2 = newHashTable[array[32, byte], int](hashTable.dataCount * 3 div 2)
  echo "hashTable2.dataLen=", hashTable2.dataLen
  hashTable.copy(hashTable2)

  for i in 0..<20:
    hashTable.set(sha256s(i.toBytes), i)

  for i in 0..<20:
    var pair = hashTable.get(sha256s(i.toBytes))
    if not pair.isNil and pair.val == i:
      echo i, " OK ", pair.key
    else:
      echo i, " Error"

  echo "dataCount=", hashTable.dataCount, " bitmapCount=", hashTable.countBitmap()

  for i in 0..<20:
    var pair = hashTable2.get(sha256s(i.toBytes))
    if not pair.isNil and pair.val == i:
      echo i, " OK ", pair.key
    else:
      if i mod 2 == 0:
        echo i, " OK deleted"
      else:
        echo i, " Error"

  hashTable2.delete()
  hashTable.delete()
