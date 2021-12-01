import
  secp256k1

## * A pointer to a function that hashes an EC point to obtain an ECDH secret
##
##   Returns: 1 if the point was successfully hashed.
##            0 will cause secp256k1_ecdh to fail and return 0.
##            Other return values are not allowed, and the behaviour of
##            secp256k1_ecdh is undefined for other return values.
##   Out:     output:     pointer to an array to be filled by the function
##   In:      x32:        pointer to a 32-byte x coordinate
##            y32:        pointer to a 32-byte y coordinate
##            data:       arbitrary data pointer that is passed through
##

type
  secp256k1_ecdh_hash_function* = proc (output: ptr uint8; x32: ptr uint8;
                                     y32: ptr uint8; data: pointer): cint {.cdecl.}

## * An implementation of SHA256 hash function that applies to compressed public key.
##  Populates the output parameter with 32 bytes.

var secp256k1_ecdh_hash_function_sha256* {.importc.}: secp256k1_ecdh_hash_function

## * A default ECDH hash function (currently equal to secp256k1_ecdh_hash_function_sha256).
##  Populates the output parameter with 32 bytes.

var secp256k1_ecdh_hash_function_default* {.importc.}: secp256k1_ecdh_hash_function

## * Compute an EC Diffie-Hellman secret in constant time
##
##   Returns: 1: exponentiation was successful
##            0: scalar was invalid (zero or overflow) or hashfp returned 0
##   Args:    ctx:        pointer to a context object (cannot be NULL)
##   Out:     output:     pointer to an array to be filled by hashfp
##   In:      pubkey:     a pointer to a secp256k1_pubkey containing an
##                        initialized public key
##            seckey:     a 32-byte scalar with which to multiply the point
##            hashfp:     pointer to a hash function. If NULL, secp256k1_ecdh_hash_function_sha256 is used
##                        (in which case, 32 bytes will be written to output)
##            data:       arbitrary data pointer that is passed through to hashfp
##

proc secp256k1_ecdh*(ctx: ptr secp256k1_context; output: ptr uint8;
                    pubkey: ptr secp256k1_pubkey; seckey: ptr uint8;
                    hashfp: secp256k1_ecdh_hash_function; data: pointer): cint {.importc.}
