const
  SECP256K1_H* = true

##  These rules specify the order of arguments in API calls:
##
##  1. Context pointers go first, followed by output arguments, combined
##     output/input arguments, and finally input-only arguments.
##  2. Array lengths always immediately follow the argument whose length
##     they describe, even if this violates rule 1.
##  3. Within the OUT/OUTIN/IN groups, pointers to data that is typically generated
##     later go first. This means: signatures, public nonces, secret nonces,
##     messages, public keys, secret keys, tweaks.
##  4. Arguments that are not data pointers go last, from more complex to less
##     complex: function pointers, algorithm names, messages, void pointers,
##     counts, flags, booleans.
##  5. Opaque data pointers follow the function pointer they are to be passed to.
##
## * Opaque data structure that holds context information (precomputed tables etc.).
##
##   The purpose of context structures is to cache large precomputed data tables
##   that are expensive to construct, and also to maintain the randomization data
##   for blinding.
##
##   Do not create a new context object for each operation, as construction is
##   far slower than all other API calls (~100 times slower than an ECDSA
##   verification).
##
##   A constructed context can safely be used from multiple threads
##   simultaneously, but API calls that take a non-const pointer to a context
##   need exclusive access to it. In particular this is the case for
##   secp256k1_context_destroy, secp256k1_context_preallocated_destroy,
##   and secp256k1_context_randomize.
##
##   Regarding randomization, either do it once at creation time (in which case
##   you do not need any locking for the other calls), or use a read-write lock.
##

type
  secp256k1_context* = object #secp256k1_context_struct

## * Opaque data structure that holds rewriteable "scratch space"
##
##   The purpose of this structure is to replace dynamic memory allocations,
##   because we target architectures where this may not be available. It is
##   essentially a resizable (within specified parameters) block of bytes,
##   which is initially created either by memory allocation or TODO as a pointer
##   into some fixed rewritable space.
##
##   Unlike the context object, this cannot safely be shared between threads
##   without additional synchronization logic.
##

type
  secp256k1_scratch_space* = object #secp256k1_scratch_space_struct

## * Opaque data structure that holds a parsed and valid public key.
##
##   The exact representation of data inside is implementation defined and not
##   guaranteed to be portable between different platforms or versions. It is
##   however guaranteed to be 64 bytes in size, and can be safely copied/moved.
##   If you need to convert to a format suitable for storage, transmission, or
##   comparison, use secp256k1_ec_pubkey_serialize and secp256k1_ec_pubkey_parse.
##

type
  secp256k1_pubkey* {.bycopy.} = object
    data*: array[64, uint8]


## * Opaque data structured that holds a parsed ECDSA signature.
##
##   The exact representation of data inside is implementation defined and not
##   guaranteed to be portable between different platforms or versions. It is
##   however guaranteed to be 64 bytes in size, and can be safely copied/moved.
##   If you need to convert to a format suitable for storage, transmission, or
##   comparison, use the secp256k1_ecdsa_signature_serialize_* and
##   secp256k1_ecdsa_signature_parse_* functions.
##

type
  secp256k1_ecdsa_signature* {.bycopy.} = object
    data*: array[64, uint8]


## * A pointer to a function to deterministically generate a nonce.
##
##  Returns: 1 if a nonce was successfully generated. 0 will cause signing to fail.
##  Out:     nonce32:   pointer to a 32-byte array to be filled by the function.
##  In:      msg32:     the 32-byte message hash being verified (will not be NULL)
##           key32:     pointer to a 32-byte secret key (will not be NULL)
##           algo16:    pointer to a 16-byte array describing the signature
##                      algorithm (will be NULL for ECDSA for compatibility).
##           data:      Arbitrary data pointer that is passed through.
##           attempt:   how many iterations we have tried to find a nonce.
##                      This will almost always be 0, but different attempt values
##                      are required to result in a different nonce.
##
##  Except for test cases, this function should compute some cryptographic hash of
##  the message, the algorithm, the key and the attempt.
##

type
  secp256k1_nonce_function* = proc (nonce32: ptr uint8; msg32: ptr uint8;
                                 key32: ptr uint8; algo16: ptr uint8; data: pointer;
                                 attempt: cuint): cint {.cdecl.}

#[
when not defined(SECP256K1_GNUC_PREREQ):
  when defined(__GNUC__) and defined(__GNUC_MINOR__):
    template SECP256K1_GNUC_PREREQ*(_maj, _min: untyped): untyped =
      ((__GNUC__ shl 16) + __GNUC_MINOR__ >= ((_maj) shl 16) + (_min))

  else:
    template SECP256K1_GNUC_PREREQ*(_maj, _min: untyped): untyped =
      0

when (not defined(__STDC_VERSION__) or (__STDC_VERSION__ < 199901)):
  when SECP256K1_GNUC_PREREQ(2, 7):
    const
      SECP256K1_INLINE* = __inline__
  elif (defined(_MSC_VER)):
    const
      SECP256K1_INLINE* = __inline
  else:
    const
      SECP256K1_INLINE* = true
else:
  const
    SECP256K1_INLINE* = inline
when not defined(SECP256K1_API):
  when defined(_WIN32):
    when defined(SECP256K1_BUILD):
      template __declspec*(dllexport: untyped): void =
        nil

    else:
      const
        SECP256K1_API* = true
  elif defined(__GNUC__) and (__GNUC__ >= 4) and defined(SECP256K1_BUILD):
    const
      __attribute__* = ((visibility("default")))
  else:
    const
      SECP256K1_API* = true
## *Warning attributes
##  NONNULL is not used if SECP256K1_BUILD is set to avoid the compiler optimizing out
##  some paranoid null checks.

when defined(__GNUC__) and SECP256K1_GNUC_PREREQ(3, 4):
  const
    SECP256K1_WARN_UNUSED_RESULT* = __attribute__((__warn_unused_result__))
else:
  const
    SECP256K1_WARN_UNUSED_RESULT* = true
when not defined(SECP256K1_BUILD) and defined(__GNUC__) and
    SECP256K1_GNUC_PREREQ(3, 4):
  template SECP256K1_ARG_NONNULL*(_x: untyped): untyped =
    __attribute__((__nonnull__(_x)))

else:
  template SECP256K1_ARG_NONNULL*(_x: untyped): void =
    nil
]#

## * All flags' lower 8 bits indicate what they're for. Do not use directly.

const
  SECP256K1_FLAGS_TYPE_MASK* = ((1 shl 8) - 1)
  SECP256K1_FLAGS_TYPE_CONTEXT* = (1 shl 0)
  SECP256K1_FLAGS_TYPE_COMPRESSION* = (1 shl 1)

## * The higher bits contain the actual data. Do not use directly.

const
  SECP256K1_FLAGS_BIT_CONTEXT_VERIFY* = (1 shl 8)
  SECP256K1_FLAGS_BIT_CONTEXT_SIGN* = (1 shl 9)
  SECP256K1_FLAGS_BIT_CONTEXT_DECLASSIFY* = (1 shl 10)
  SECP256K1_FLAGS_BIT_COMPRESSION* = (1 shl 8)

## * Flags to pass to secp256k1_context_create, secp256k1_context_preallocated_size, and
##   secp256k1_context_preallocated_create.

const
  SECP256K1_CONTEXT_VERIFY* = (
    SECP256K1_FLAGS_TYPE_CONTEXT or SECP256K1_FLAGS_BIT_CONTEXT_VERIFY)
  SECP256K1_CONTEXT_SIGN* = (
    SECP256K1_FLAGS_TYPE_CONTEXT or SECP256K1_FLAGS_BIT_CONTEXT_SIGN)
  SECP256K1_CONTEXT_DECLASSIFY* = (
    SECP256K1_FLAGS_TYPE_CONTEXT or SECP256K1_FLAGS_BIT_CONTEXT_DECLASSIFY)
  SECP256K1_CONTEXT_NONE* = (SECP256K1_FLAGS_TYPE_CONTEXT)

## * Flag to pass to secp256k1_ec_pubkey_serialize.

const
  SECP256K1_EC_COMPRESSED* = (
    SECP256K1_FLAGS_TYPE_COMPRESSION or SECP256K1_FLAGS_BIT_COMPRESSION)
  SECP256K1_EC_UNCOMPRESSED* = (SECP256K1_FLAGS_TYPE_COMPRESSION)

## * Prefix byte used to tag various encoded curvepoints for specific purposes

const
  SECP256K1_TAG_PUBKEY_EVEN* = 0x00000002
  SECP256K1_TAG_PUBKEY_ODD* = 0x00000003
  SECP256K1_TAG_PUBKEY_UNCOMPRESSED* = 0x00000004
  SECP256K1_TAG_PUBKEY_HYBRID_EVEN* = 0x00000006
  SECP256K1_TAG_PUBKEY_HYBRID_ODD* = 0x00000007

## * A simple secp256k1 context object with no precomputed tables. These are useful for
##   type serialization/parsing functions which require a context object to maintain
##   API consistency, but currently do not require expensive precomputations or dynamic
##   allocations.
##

var secp256k1_context_no_precomp* {.importc.}: ptr secp256k1_context

## * Create a secp256k1 context object (in dynamically allocated memory).
##
##   This function uses malloc to allocate memory. It is guaranteed that malloc is
##   called at most once for every call of this function. If you need to avoid dynamic
##   memory allocation entirely, see the functions in secp256k1_preallocated.h.
##
##   Returns: a newly created context object.
##   In:      flags: which parts of the context to initialize.
##
##   See also secp256k1_context_randomize.
##

proc secp256k1_context_create*(flags: cuint): ptr secp256k1_context {.importc.}
## * Copy a secp256k1 context object (into dynamically allocated memory).
##
##   This function uses malloc to allocate memory. It is guaranteed that malloc is
##   called at most once for every call of this function. If you need to avoid dynamic
##   memory allocation entirely, see the functions in secp256k1_preallocated.h.
##
##   Returns: a newly created context object.
##   Args:    ctx: an existing context to copy (cannot be NULL)
##

proc secp256k1_context_clone*(ctx: ptr secp256k1_context): ptr secp256k1_context {.importc.}
## * Destroy a secp256k1 context object (created in dynamically allocated memory).
##
##   The context pointer may not be used afterwards.
##
##   The context to destroy must have been created using secp256k1_context_create
##   or secp256k1_context_clone. If the context has instead been created using
##   secp256k1_context_preallocated_create or secp256k1_context_preallocated_clone, the
##   behaviour is undefined. In that case, secp256k1_context_preallocated_destroy must
##   be used instead.
##
##   Args:   ctx: an existing context to destroy, constructed using
##                secp256k1_context_create or secp256k1_context_clone
##

proc secp256k1_context_destroy*(ctx: ptr secp256k1_context) {.importc.}
## * Set a callback function to be called when an illegal argument is passed to
##   an API call. It will only trigger for violations that are mentioned
##   explicitly in the header.
##
##   The philosophy is that these shouldn't be dealt with through a
##   specific return value, as calling code should not have branches to deal with
##   the case that this code itself is broken.
##
##   On the other hand, during debug stage, one would want to be informed about
##   such mistakes, and the default (crashing) may be inadvisable.
##   When this callback is triggered, the API function called is guaranteed not
##   to cause a crash, though its return value and output arguments are
##   undefined.
##
##   When this function has not been called (or called with fn==NULL), then the
##   default handler will be used. The library provides a default handler which
##   writes the message to stderr and calls abort. This default handler can be
##   replaced at link time if the preprocessor macro
##   USE_EXTERNAL_DEFAULT_CALLBACKS is defined, which is the case if the build
##   has been configured with --enable-external-default-callbacks. Then the
##   following two symbols must be provided to link against:
##    - void secp256k1_default_illegal_callback_fn(const char* message, void* data);
##    - void secp256k1_default_error_callback_fn(const char* message, void* data);
##   The library can call these default handlers even before a proper callback data
##   pointer could have been set using secp256k1_context_set_illegal_callback or
##   secp256k1_context_set_error_callback, e.g., when the creation of a context
##   fails. In this case, the corresponding default handler will be called with
##   the data pointer argument set to NULL.
##
##   Args: ctx:  an existing context object (cannot be NULL)
##   In:   fun:  a pointer to a function to call when an illegal argument is
##               passed to the API, taking a message and an opaque pointer.
##               (NULL restores the default handler.)
##         data: the opaque pointer to pass to fun above.
##
##   See also secp256k1_context_set_error_callback.
##

proc secp256k1_context_set_illegal_callback*(ctx: ptr secp256k1_context;
    fun: proc (message: cstring; data: pointer); data: pointer) {.importc.}
## * Set a callback function to be called when an internal consistency check
##   fails. The default is crashing.
##
##   This can only trigger in case of a hardware failure, miscompilation,
##   memory corruption, serious bug in the library, or other error would can
##   otherwise result in undefined behaviour. It will not trigger due to mere
##   incorrect usage of the API (see secp256k1_context_set_illegal_callback
##   for that). After this callback returns, anything may happen, including
##   crashing.
##
##   Args: ctx:  an existing context object (cannot be NULL)
##   In:   fun:  a pointer to a function to call when an internal error occurs,
##               taking a message and an opaque pointer (NULL restores the
##               default handler, see secp256k1_context_set_illegal_callback
##               for details).
##         data: the opaque pointer to pass to fun above.
##
##   See also secp256k1_context_set_illegal_callback.
##

proc secp256k1_context_set_error_callback*(ctx: ptr secp256k1_context;
    fun: proc (message: cstring; data: pointer); data: pointer) {.importc.}
## * Create a secp256k1 scratch space object.
##
##   Returns: a newly created scratch space.
##   Args: ctx:  an existing context object (cannot be NULL)
##   In:   size: amount of memory to be available as scratch space. Some extra
##               (<100 bytes) will be allocated for extra accounting.
##

proc secp256k1_scratch_space_create*(ctx: ptr secp256k1_context; size: csize_t): ptr secp256k1_scratch_space {.importc.}
## * Destroy a secp256k1 scratch space.
##
##   The pointer may not be used afterwards.
##   Args:       ctx: a secp256k1 context object.
##           scratch: space to destroy
##

proc secp256k1_scratch_space_destroy*(ctx: ptr secp256k1_context;
                                     scratch: ptr secp256k1_scratch_space) {.importc.}
## * Parse a variable-length public key into the pubkey object.
##
##   Returns: 1 if the public key was fully valid.
##            0 if the public key could not be parsed or is invalid.
##   Args: ctx:      a secp256k1 context object.
##   Out:  pubkey:   pointer to a pubkey object. If 1 is returned, it is set to a
##                   parsed version of input. If not, its value is undefined.
##   In:   input:    pointer to a serialized public key
##         inputlen: length of the array pointed to by input
##
##   This function supports parsing compressed (33 bytes, header byte 0x02 or
##   0x03), uncompressed (65 bytes, header byte 0x04), or hybrid (65 bytes, header
##   byte 0x06 or 0x07) format public keys.
##

proc secp256k1_ec_pubkey_parse*(ctx: ptr secp256k1_context;
                               pubkey: ptr secp256k1_pubkey; input: ptr uint8;
                               inputlen: csize_t): cint {.importc.}
## * Serialize a pubkey object into a serialized byte sequence.
##
##   Returns: 1 always.
##   Args:   ctx:        a secp256k1 context object.
##   Out:    output:     a pointer to a 65-byte (if compressed==0) or 33-byte (if
##                       compressed==1) byte array to place the serialized key
##                       in.
##   In/Out: outputlen:  a pointer to an integer which is initially set to the
##                       size of output, and is overwritten with the written
##                       size.
##   In:     pubkey:     a pointer to a secp256k1_pubkey containing an
##                       initialized public key.
##           flags:      SECP256K1_EC_COMPRESSED if serialization should be in
##                       compressed format, otherwise SECP256K1_EC_UNCOMPRESSED.
##

proc secp256k1_ec_pubkey_serialize*(ctx: ptr secp256k1_context; output: ptr uint8;
                                   outputlen: ptr csize_t;
                                   pubkey: ptr secp256k1_pubkey; flags: cuint): cint {.importc.}
## * Parse an ECDSA signature in compact (64 bytes) format.
##
##   Returns: 1 when the signature could be parsed, 0 otherwise.
##   Args: ctx:      a secp256k1 context object
##   Out:  sig:      a pointer to a signature object
##   In:   input64:  a pointer to the 64-byte array to parse
##
##   The signature must consist of a 32-byte big endian R value, followed by a
##   32-byte big endian S value. If R or S fall outside of [0..order-1], the
##   encoding is invalid. R and S with value 0 are allowed in the encoding.
##
##   After the call, sig will always be initialized. If parsing failed or R or
##   S are zero, the resulting sig value is guaranteed to fail validation for any
##   message and public key.
##

proc secp256k1_ecdsa_signature_parse_compact*(ctx: ptr secp256k1_context;
    sig: ptr secp256k1_ecdsa_signature; input64: ptr uint8): cint {.importc.}
## * Parse a DER ECDSA signature.
##
##   Returns: 1 when the signature could be parsed, 0 otherwise.
##   Args: ctx:      a secp256k1 context object
##   Out:  sig:      a pointer to a signature object
##   In:   input:    a pointer to the signature to be parsed
##         inputlen: the length of the array pointed to be input
##
##   This function will accept any valid DER encoded signature, even if the
##   encoded numbers are out of range.
##
##   After the call, sig will always be initialized. If parsing failed or the
##   encoded numbers are out of range, signature validation with it is
##   guaranteed to fail for every message and public key.
##

proc secp256k1_ecdsa_signature_parse_der*(ctx: ptr secp256k1_context;
    sig: ptr secp256k1_ecdsa_signature; input: ptr uint8; inputlen: csize_t): cint {.importc.}
## * Serialize an ECDSA signature in DER format.
##
##   Returns: 1 if enough space was available to serialize, 0 otherwise
##   Args:   ctx:       a secp256k1 context object
##   Out:    output:    a pointer to an array to store the DER serialization
##   In/Out: outputlen: a pointer to a length integer. Initially, this integer
##                      should be set to the length of output. After the call
##                      it will be set to the length of the serialization (even
##                      if 0 was returned).
##   In:     sig:       a pointer to an initialized signature object
##

proc secp256k1_ecdsa_signature_serialize_der*(ctx: ptr secp256k1_context;
    output: ptr uint8; outputlen: ptr csize_t; sig: ptr secp256k1_ecdsa_signature): cint {.importc.}
## * Serialize an ECDSA signature in compact (64 byte) format.
##
##   Returns: 1
##   Args:   ctx:       a secp256k1 context object
##   Out:    output64:  a pointer to a 64-byte array to store the compact serialization
##   In:     sig:       a pointer to an initialized signature object
##
##   See secp256k1_ecdsa_signature_parse_compact for details about the encoding.
##

proc secp256k1_ecdsa_signature_serialize_compact*(ctx: ptr secp256k1_context;
    output64: ptr uint8; sig: ptr secp256k1_ecdsa_signature): cint {.importc.}
## * Verify an ECDSA signature.
##
##   Returns: 1: correct signature
##            0: incorrect or unparseable signature
##   Args:    ctx:       a secp256k1 context object, initialized for verification.
##   In:      sig:       the signature being verified (cannot be NULL)
##            msghash32: the 32-byte message hash being verified (cannot be NULL).
##                       The verifier must make sure to apply a cryptographic
##                       hash function to the message by itself and not accept an
##                       msghash32 value directly. Otherwise, it would be easy to
##                       create a "valid" signature without knowledge of the
##                       secret key. See also
##                       https://bitcoin.stackexchange.com/a/81116/35586 for more
##                       background on this topic.
##            pubkey:    pointer to an initialized public key to verify with (cannot be NULL)
##
##  To avoid accepting malleable signatures, only ECDSA signatures in lower-S
##  form are accepted.
##
##  If you need to accept ECDSA signatures from sources that do not obey this
##  rule, apply secp256k1_ecdsa_signature_normalize to the signature prior to
##  validation, but be aware that doing so results in malleable signatures.
##
##  For details, see the comments for that function.
##

proc secp256k1_ecdsa_verify*(ctx: ptr secp256k1_context;
                            sig: ptr secp256k1_ecdsa_signature;
                            msghash32: ptr uint8; pubkey: ptr secp256k1_pubkey): cint {.importc.}
## * Convert a signature to a normalized lower-S form.
##
##   Returns: 1 if sigin was not normalized, 0 if it already was.
##   Args: ctx:    a secp256k1 context object
##   Out:  sigout: a pointer to a signature to fill with the normalized form,
##                 or copy if the input was already normalized. (can be NULL if
##                 you're only interested in whether the input was already
##                 normalized).
##   In:   sigin:  a pointer to a signature to check/normalize (cannot be NULL,
##                 can be identical to sigout)
##
##   With ECDSA a third-party can forge a second distinct signature of the same
##   message, given a single initial signature, but without knowing the key. This
##   is done by negating the S value modulo the order of the curve, 'flipping'
##   the sign of the random point R which is not included in the signature.
##
##   Forgery of the same message isn't universally problematic, but in systems
##   where message malleability or uniqueness of signatures is important this can
##   cause issues. This forgery can be blocked by all verifiers forcing signers
##   to use a normalized form.
##
##   The lower-S form reduces the size of signatures slightly on average when
##   variable length encodings (such as DER) are used and is cheap to verify,
##   making it a good choice. Security of always using lower-S is assured because
##   anyone can trivially modify a signature after the fact to enforce this
##   property anyway.
##
##   The lower S value is always between 0x1 and
##   0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0,
##   inclusive.
##
##   No other forms of ECDSA malleability are known and none seem likely, but
##   there is no formal proof that ECDSA, even with this additional restriction,
##   is free of other malleability. Commonly used serialization schemes will also
##   accept various non-unique encodings, so care should be taken when this
##   property is required for an application.
##
##   The secp256k1_ecdsa_sign function will by default create signatures in the
##   lower-S form, and secp256k1_ecdsa_verify will not accept others. In case
##   signatures come from a system that cannot enforce this property,
##   secp256k1_ecdsa_signature_normalize must be called before verification.
##

proc secp256k1_ecdsa_signature_normalize*(ctx: ptr secp256k1_context;
    sigout: ptr secp256k1_ecdsa_signature; sigin: ptr secp256k1_ecdsa_signature): cint {.importc, discardable.}
## * An implementation of RFC6979 (using HMAC-SHA256) as nonce generation function.
##  If a data pointer is passed, it is assumed to be a pointer to 32 bytes of
##  extra entropy.
##

var secp256k1_nonce_function_rfc6979*: secp256k1_nonce_function

## * A default safe nonce generation function (currently equal to secp256k1_nonce_function_rfc6979).

var secp256k1_nonce_function_default*: secp256k1_nonce_function

## * Create an ECDSA signature.
##
##   Returns: 1: signature created
##            0: the nonce generation function failed, or the secret key was invalid.
##   Args:    ctx:       pointer to a context object, initialized for signing (cannot be NULL)
##   Out:     sig:       pointer to an array where the signature will be placed (cannot be NULL)
##   In:      msghash32: the 32-byte message hash being signed (cannot be NULL)
##            seckey:    pointer to a 32-byte secret key (cannot be NULL)
##            noncefp:   pointer to a nonce generation function. If NULL, secp256k1_nonce_function_default is used
##            ndata:     pointer to arbitrary data used by the nonce generation function (can be NULL)
##
##  The created signature is always in lower-S form. See
##  secp256k1_ecdsa_signature_normalize for more details.
##

proc secp256k1_ecdsa_sign*(ctx: ptr secp256k1_context;
                          sig: ptr secp256k1_ecdsa_signature;
                          msghash32: ptr uint8; seckey: ptr uint8;
                          noncefp: secp256k1_nonce_function; ndata: pointer): cint {.importc.}
## * Verify an ECDSA secret key.
##
##   A secret key is valid if it is not 0 and less than the secp256k1 curve order
##   when interpreted as an integer (most significant byte first). The
##   probability of choosing a 32-byte string uniformly at random which is an
##   invalid secret key is negligible.
##
##   Returns: 1: secret key is valid
##            0: secret key is invalid
##   Args:    ctx: pointer to a context object (cannot be NULL)
##   In:      seckey: pointer to a 32-byte secret key (cannot be NULL)
##

proc secp256k1_ec_seckey_verify*(ctx: ptr secp256k1_context; seckey: ptr uint8): cint {.importc.}
## * Compute the public key for a secret key.
##
##   Returns: 1: secret was valid, public key stores
##            0: secret was invalid, try again
##   Args:   ctx:        pointer to a context object, initialized for signing (cannot be NULL)
##   Out:    pubkey:     pointer to the created public key (cannot be NULL)
##   In:     seckey:     pointer to a 32-byte secret key (cannot be NULL)
##

proc secp256k1_ec_pubkey_create*(ctx: ptr secp256k1_context;
                                pubkey: ptr secp256k1_pubkey; seckey: ptr uint8): cint {.importc.}
## * Negates a secret key in place.
##
##   Returns: 0 if the given secret key is invalid according to
##            secp256k1_ec_seckey_verify. 1 otherwise
##   Args:   ctx:    pointer to a context object
##   In/Out: seckey: pointer to the 32-byte secret key to be negated. If the
##                   secret key is invalid according to
##                   secp256k1_ec_seckey_verify, this function returns 0 and
##                   seckey will be set to some unspecified value. (cannot be
##                   NULL)
##

proc secp256k1_ec_seckey_negate*(ctx: ptr secp256k1_context; seckey: ptr uint8): cint {.importc.}
## * Same as secp256k1_ec_seckey_negate, but DEPRECATED. Will be removed in
##   future versions.

proc secp256k1_ec_privkey_negate*(ctx: ptr secp256k1_context; seckey: ptr uint8): cint {.importc.}
## * Negates a public key in place.
##
##   Returns: 1 always
##   Args:   ctx:        pointer to a context object
##   In/Out: pubkey:     pointer to the public key to be negated (cannot be NULL)
##

proc secp256k1_ec_pubkey_negate*(ctx: ptr secp256k1_context;
                                pubkey: ptr secp256k1_pubkey): cint {.importc.}
## * Tweak a secret key by adding tweak to it.
##
##   Returns: 0 if the arguments are invalid or the resulting secret key would be
##            invalid (only when the tweak is the negation of the secret key). 1
##            otherwise.
##   Args:    ctx:   pointer to a context object (cannot be NULL).
##   In/Out: seckey: pointer to a 32-byte secret key. If the secret key is
##                   invalid according to secp256k1_ec_seckey_verify, this
##                   function returns 0. seckey will be set to some unspecified
##                   value if this function returns 0. (cannot be NULL)
##   In:    tweak32: pointer to a 32-byte tweak. If the tweak is invalid according to
##                   secp256k1_ec_seckey_verify, this function returns 0. For
##                   uniformly random 32-byte arrays the chance of being invalid
##                   is negligible (around 1 in 2^128) (cannot be NULL).
##

proc secp256k1_ec_seckey_tweak_add*(ctx: ptr secp256k1_context; seckey: ptr uint8;
                                   tweak32: ptr uint8): cint {.importc.}
## * Same as secp256k1_ec_seckey_tweak_add, but DEPRECATED. Will be removed in
##   future versions.

proc secp256k1_ec_privkey_tweak_add*(ctx: ptr secp256k1_context; seckey: ptr uint8;
                                    tweak32: ptr uint8): cint {.importc.}
## * Tweak a public key by adding tweak times the generator to it.
##
##   Returns: 0 if the arguments are invalid or the resulting public key would be
##            invalid (only when the tweak is the negation of the corresponding
##            secret key). 1 otherwise.
##   Args:    ctx:   pointer to a context object initialized for validation
##                   (cannot be NULL).
##   In/Out: pubkey: pointer to a public key object. pubkey will be set to an
##                   invalid value if this function returns 0 (cannot be NULL).
##   In:    tweak32: pointer to a 32-byte tweak. If the tweak is invalid according to
##                   secp256k1_ec_seckey_verify, this function returns 0. For
##                   uniformly random 32-byte arrays the chance of being invalid
##                   is negligible (around 1 in 2^128) (cannot be NULL).
##

proc secp256k1_ec_pubkey_tweak_add*(ctx: ptr secp256k1_context;
                                   pubkey: ptr secp256k1_pubkey;
                                   tweak32: ptr uint8): cint {.importc.}
## * Tweak a secret key by multiplying it by a tweak.
##
##   Returns: 0 if the arguments are invalid. 1 otherwise.
##   Args:   ctx:    pointer to a context object (cannot be NULL).
##   In/Out: seckey: pointer to a 32-byte secret key. If the secret key is
##                   invalid according to secp256k1_ec_seckey_verify, this
##                   function returns 0. seckey will be set to some unspecified
##                   value if this function returns 0. (cannot be NULL)
##   In:    tweak32: pointer to a 32-byte tweak. If the tweak is invalid according to
##                   secp256k1_ec_seckey_verify, this function returns 0. For
##                   uniformly random 32-byte arrays the chance of being invalid
##                   is negligible (around 1 in 2^128) (cannot be NULL).
##

proc secp256k1_ec_seckey_tweak_mul*(ctx: ptr secp256k1_context; seckey: ptr uint8;
                                   tweak32: ptr uint8): cint {.importc.}
## * Same as secp256k1_ec_seckey_tweak_mul, but DEPRECATED. Will be removed in
##   future versions.

proc secp256k1_ec_privkey_tweak_mul*(ctx: ptr secp256k1_context; seckey: ptr uint8;
                                    tweak32: ptr uint8): cint {.importc.}
## * Tweak a public key by multiplying it by a tweak value.
##
##   Returns: 0 if the arguments are invalid. 1 otherwise.
##   Args:    ctx:   pointer to a context object initialized for validation
##                   (cannot be NULL).
##   In/Out: pubkey: pointer to a public key object. pubkey will be set to an
##                   invalid value if this function returns 0 (cannot be NULL).
##   In:    tweak32: pointer to a 32-byte tweak. If the tweak is invalid according to
##                   secp256k1_ec_seckey_verify, this function returns 0. For
##                   uniformly random 32-byte arrays the chance of being invalid
##                   is negligible (around 1 in 2^128) (cannot be NULL).
##

proc secp256k1_ec_pubkey_tweak_mul*(ctx: ptr secp256k1_context;
                                   pubkey: ptr secp256k1_pubkey;
                                   tweak32: ptr uint8): cint  {.importc.}
## * Updates the context randomization to protect against side-channel leakage.
##   Returns: 1: randomization successfully updated or nothing to randomize
##            0: error
##   Args:    ctx:       pointer to a context object (cannot be NULL)
##   In:      seed32:    pointer to a 32-byte random seed (NULL resets to initial state)
##
##  While secp256k1 code is written to be constant-time no matter what secret
##  values are, it's possible that a future compiler may output code which isn't,
##  and also that the CPU may not emit the same radio frequencies or draw the same
##  amount power for all values.
##
##  This function provides a seed which is combined into the blinding value: that
##  blinding value is added before each multiplication (and removed afterwards) so
##  that it does not affect function results, but shields against attacks which
##  rely on any input-dependent behaviour.
##
##  This function has currently an effect only on contexts initialized for signing
##  because randomization is currently used only for signing. However, this is not
##  guaranteed and may change in the future. It is safe to call this function on
##  contexts not initialized for signing; then it will have no effect and return 1.
##
##  You should call this after secp256k1_context_create or
##  secp256k1_context_clone (and secp256k1_context_preallocated_create or
##  secp256k1_context_clone, resp.), and you may call this repeatedly afterwards.
##

proc secp256k1_context_randomize*(ctx: ptr secp256k1_context; seed32: ptr uint8): cint {.importc.}
## * Add a number of public keys together.
##
##   Returns: 1: the sum of the public keys is valid.
##            0: the sum of the public keys is not valid.
##   Args:   ctx:        pointer to a context object
##   Out:    out:        pointer to a public key object for placing the resulting public key
##                       (cannot be NULL)
##   In:     ins:        pointer to array of pointers to public keys (cannot be NULL)
##           n:          the number of public keys to add together (must be at least 1)
##

proc secp256k1_ec_pubkey_combine*(ctx: ptr secp256k1_context;
                                 `out`: ptr secp256k1_pubkey;
                                 ins: ptr ptr secp256k1_pubkey; n: csize_t): cint {.importc.}


import os

when defined(emscripten):
  {.passL: currentSourcePath().parentDir() / "../deps/wasm-secp256k1/.libs/libsecp256k1.a".}
else:
  {.passL: currentSourcePath().parentDir() / "../deps/secp256k1/.libs/libsecp256k1.a".}
