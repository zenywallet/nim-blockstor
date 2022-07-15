# Copyright (c) 2021 zenywallet

import address
import bytes

{.used.}

var strtmp {.threadvar.}: string

proc address_init*() {.exportc.} = discard

proc get_address*(networkId: int, hash160: ptr UncheckedArray[byte], size: cint,
                addressType: uint8): cstring {.exportc.} =
  strtmp = getAddress(getNetwork(networkId.NetworkId), hash160.toBytes(size).Hash160, addressType.AddressType) & "\0"
  result = strtmp.cstring

proc get_address_from_hex*(networkId: int, hash160_hex: cstring, addressType: uint8): cstring {.exportc.} =
  strtmp = getAddress(getNetwork(networkId.NetworkId), ($hash160_hex).Hex.toBytes.Hash160, addressType.AddressType) & "\0"
  result = strtmp.cstring

proc check_address*(address: cstring): bool {.exportc.} = checkAddress($address)

proc get_hash160_hex*(networkId: int, address: cstring): cstring {.exportc.} =
  var hash160 = getHash160(getNetwork(networkId.NetworkId), $address)
  result = hash160.toBytes.toHex.cstring

#[
void address_init();
char* get_address(int nid, char* hash160, int size, uint8_t address_type);
char* get_address_from_hex(int nid, char* hash160_hex, uint8_t address_type);
bool* check_address(char* address);
char* get_hash160_hex(int nid, char* address);
]#
