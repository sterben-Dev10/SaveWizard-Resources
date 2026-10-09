"""
JUMP FORCE (PS4) save-file decrypter
====================================

Decrypt and re-encrypt JUMP FORCE save files (e.g. ``JFSaveData``, ``JFReplay``).

Apollo script by Bucanero, based on python script by brotherguns5624

The scheme (reverse-engineered from JFeboot.elf)
------------------------------------------------
Decrypt / verify : FUN_03ccdde0  (vaddr 0x03ccdde0)
Hash (MD5)       : FUN_03ccdad0  (vaddr 0x03ccdad0)

File layout::

    [ body of length L ][ 16-byte MD5 tag, woven into the body tail ]

1. CIPHER -- a Marsaglia xorshift128 keystream XORed byte-by-byte over the
   plaintext body. Stream cipher, so body length is arbitrary (not block-aligned).

2. SEED_CONST -- a per-slot 32-bit constant baked into the game (the literal
   first argument at each decrypt call site):
       0x0007CB61  -> JFSaveData
       0x443B294F  -> JFReplay (the other slot)

3. INTEGRITY TAG -- 16 bytes = MD5(plaintext). It is woven into the tail of the
   body in (body_len // 17)-sized strides, and obfuscated with a keystream
   seeded from SEED_CONST. On load the game extracts + de-obfuscates the tag,
   decrypts the body with a keystream seeded from (SEED_CONST XOR tag_words),
   recomputes MD5(plaintext), and rejects the save if it does not match. This
   codec performs that same check, so a successful decrypt is self-verifying.

WHY THE LOOPS LOOK THE WAY THEY DO
----------------------------------
The two keystream loops (``_tag_keystream_xor`` and ``_body_keystream_xor``)
are a LITERAL, variable-for-variable transcription of the decompiled recurrence.
The four-word rotation order is load-bearing -- do NOT refactor them into a
generic xorshift128 step, or the keystream drifts by a word and the MD5 check
fails. (Ask me how I know.)

"""


import uhashlib
import ustruct as struct
import ucrypto

ENCRYPT = ucrypto.ENCRYPT
DECRYPT = ucrypto.DECRYPT


# --------------------------------------------------------------------------- #
# Constants recovered from the binary
# --------------------------------------------------------------------------- #

M = 0xFFFFFFFF
FOOTER_LEN = 16
STRIDE_DIVISOR = 17

SEED_JFSAVEDATA = 0x0007CB61
SEED_JFREPLAY = 0x443B294F
KNOWN_SLOTS = {"JFSaveData": SEED_JFSAVEDATA, "JFReplay": SEED_JFREPLAY}

FOLD_ADD = 0xE55D9141
MASK_X = 0x075BCD15       # 123456789  (canonical xorshift128 seeds, XOR-masked)
MASK_Y = 0x05491333       #  88675123
MASK_Z = 0x1F123BB5       # 521288629
MASK_W = 0x159A55E5       # 362436069


def rol(value: int, count: int) -> int:
    """Rotate a 32-bit value left by ``count`` bits."""
    value &= M
    return ((value << count) | (value >> (32 - count))) & M


def md5_tag(plaintext: bytes) -> bytes:
    """The 16-byte integrity tag is a plain MD5 of the decrypted body."""
    return uhashlib.md5(plaintext)


# --------------------------------------------------------------------------- #
# The two keystream passes (verbatim transcriptions of FUN_03ccdde0)
# --------------------------------------------------------------------------- #

def _tag_keystream_xor(tag: bytearray, seed_const: int) -> None:
    """XOR the 16-byte tag in place with the tag keystream (seeded by SEED_CONST).

    XOR is symmetric, so this both obfuscates (encrypt) and de-obfuscates
    (decrypt). The state is initialised exactly as in the binary; note byte 0
    uses a single pre-step before the 1..15 loop.
    """
    uVar14 = (seed_const + FOLD_ADD) & M
    uVar6 = (rol(uVar14, 16) ^ MASK_Y) & M
    pre = (uVar14 ^ MASK_X) & M
    uVar8 = ((pre << 11) ^ pre) & M
    uVar9 = ((uVar8 >> 8) ^ uVar6 ^ uVar8 ^ (uVar6 >> 19)) & M
    tag[0] ^= uVar9 & 0xFF

    uVar10 = (rol(uVar14, 8) ^ MASK_W) & M
    uVar8 = (rol(uVar14, 24) ^ MASK_Z) & M
    for lv in range(1, FOOTER_LEN):
        uVar14 = uVar6
        uVar6 = uVar9
        uVar10 = ((uVar10 << 11) ^ uVar10) & M
        uVar9 = ((uVar10 >> 8) ^ uVar6 ^ uVar10 ^ (uVar6 >> 19)) & M
        tag[lv] ^= uVar9 & 0xFF
        uVar10 = uVar8
        uVar8 = uVar14


def _body_keystream_xor(buf: bytearray, seed_const: int, tag: bytes) -> None:
    """XOR the body in place with the main keystream.

    The seed folds the de-obfuscated MD5 tag into SEED_CONST. Symmetric XOR, so
    this both encrypts and decrypts the body.
    """
    w0, w1, w2, w3 = struct.unpack("<4I", tag)
    uVar8 = (seed_const ^ w0 ^ w1 ^ w2 ^ w3) + FOLD_ADD & M
    uVar10 = (uVar8 ^ MASK_X) & M
    uVar9 = (rol(uVar8, 24) ^ MASK_Z) & M
    uVar6 = (rol(uVar8, 8) ^ MASK_W) & M
    uVar8 = (rol(uVar8, 16) ^ MASK_Y) & M
    for i in range(len(buf)):
        uVar16 = uVar9
        uVar10 = ((uVar10 << 11) ^ uVar10) & M
        uVar14 = ((uVar10 >> 8) ^ uVar8 ^ uVar10 ^ (uVar8 >> 19)) & M
        buf[i] ^= uVar14 & 0xFF
        uVar10 = uVar6
        uVar9 = uVar8
        uVar6 = uVar16
        uVar8 = uVar14


# --------------------------------------------------------------------------- #
# Footer weaving (16 tag bytes interleaved into the body tail)
# --------------------------------------------------------------------------- #

def _stride(body_len: int) -> int:
    return body_len // STRIDE_DIVISOR


def _head_keep(body_len: int) -> int:
    """Leading bytes kept in place before the first woven tag byte.

    The binary computes this with a reciprocal-multiply: it divides body_len by
    17 (the magic constant 0xF0F0F0F1) and rounds that down to a multiple of 16,
    then subtracts from body_len. Transcribed literally so it matches exactly.
    """
    return body_len - (((body_len * 0xF0F0F0F1) >> 32) & 0xFFFFFFF0)


def _deinterleave(blob: bytes) -> tuple[bytearray, bytearray]:
    """Split a stored file into (still-encrypted body, obfuscated 16-byte tag)."""
    body_len = len(blob) - FOOTER_LEN
    stride = _stride(body_len)
    keep = _head_keep(body_len)

    body = bytearray(body_len)
    tag = bytearray(FOOTER_LEN)

    out = 0
    body[out:out + keep] = blob[0:keep]
    out += keep
    cur = keep

    for tag_index in range(0xF, 0x0, -1):     # tag bytes stored high-index first
        tag[tag_index] = blob[cur]
        body[out:out + stride] = blob[cur + 1:cur + 1 + stride]
        out += stride
        cur += 1 + stride

    tag[0] = blob[cur]
    body[out:out + stride] = blob[cur + 1:cur + 1 + stride]
    out += stride
    body[out:out + stride] = blob[cur + 1 + stride:cur + 1 + 2 * stride]
    out += stride
    if out < body_len:
        rem = body_len - out
        body[out:body_len] = blob[cur + 1 + 2 * stride:cur + 1 + 2 * stride + rem]

    return body, tag


def _interleave(body: bytes, tag: bytes) -> bytearray:
    """Weave the 16 tag bytes into the body tail (inverse of _deinterleave)."""
    body_len = len(body)
    stride = _stride(body_len)
    keep = _head_keep(body_len)

    blob = bytearray()
    inp = 0
    blob += body[0:keep]
    inp += keep

    for tag_index in range(0xF, 0x0, -1):
        blob.append(tag[tag_index])
        blob += body[inp:inp + stride]
        inp += stride

    blob.append(tag[0])
    blob += body[inp:inp + stride]
    inp += stride
    blob += body[inp:inp + stride]
    inp += stride
    if inp < body_len:
        blob += body[inp:body_len]

    assert len(blob) == body_len + FOOTER_LEN
    return blob


# --------------------------------------------------------------------------- #
# Public API
# --------------------------------------------------------------------------- #

def decrypt(blob: bytes, seed_const: int | None = None) -> tuple[bytes, int]:
    """Decrypt a save file.

    Returns ``(plaintext, seed_const)``. Raises ValueError if no slot constant
    yields a body whose MD5 matches the stored integrity tag.
    """
    if len(blob) < FOOTER_LEN:
        raise ValueError("file too small to contain a footer")

    candidates = [seed_const] if seed_const is not None else list(KNOWN_SLOTS.values())
    encrypted_body, stored_tag = _deinterleave(blob)

    for cand in candidates:
        tag = bytearray(stored_tag)
        _tag_keystream_xor(tag, cand)             # de-obfuscate the 16-byte tag
        plain = bytearray(encrypted_body)
        _body_keystream_xor(plain, cand, bytes(tag))
        if md5_tag(bytes(plain)) == bytes(tag):   # self-verify
            return bytes(plain), cand

    raise ValueError(
        "integrity check failed for every known slot constant -- "
        "the file may be corrupt or use a different slot"
    )


def encrypt(plaintext: bytes, seed_const: int) -> bytes:
    """Encrypt a plaintext save body back into the game's on-disk format."""
    tag = md5_tag(plaintext)           # integrity tag = MD5(plaintext)

    body = bytearray(plaintext)
    _body_keystream_xor(body, seed_const, tag)    # uses the clean tag

    _tag_keystream_xor(tag, seed_const)           # obfuscate the tag, then weave
    return bytes(_interleave(bytes(body), tag))


def jumpforce_crypt(mode, seed, data: bytearray):

    print("Using slot seed 0x{:08X}".format(seed))

    if mode == DECRYPT:
        plain, used = decrypt(data, seed)
        data[:] = plain + md5_tag(plain)  # append the tag for round-trip self-check
        print("decrypted OK (slot 0x{:08X}) -> ({} bytes)".format(used, len(plain)))

    elif mode == ENCRYPT:
        blob = encrypt(data[:-16], seed)
        data[:] = blob
        print("encrypted OK (slot 0x{:08X}) -> ({} bytes)".format(seed, len(blob)))

    else:
        raise Exception("Error: Unknown mode '{}', must be 'ENCRYPT' or 'DECRYPT'".format(mode))
