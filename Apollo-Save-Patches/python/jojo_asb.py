"""
JoJo's Bizarre Adventure: All-Star Battle R — PS4 Save Tool
============================================================
Handles decryption, encryption, and editing of JOJOASB.S save files.

Original author: @brotherguns5624
Apollo script by Bucanero

Reverse engineered from eboot.elf (CUSA28770):
  - PRNG cipher:  sub_9EE170
  - PRNG key:     0x4FC36442  (sub_923BC8 @ 0x923BC8)
  - Checksum:     CRC-32/BZIP2 stored at the last 4 bytes of the save
"""

import gc
import ucrypto
import ustruct as struct
import uhashlib


ENCRYPT = ucrypto.ENCRYPT
DECRYPT = ucrypto.DECRYPT

# ─────────────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────────────

SAVE_SIZE  = 0x227DE8   # Total save file size in bytes
CRC_OFFSET = 0x227DE4   # CRC covers bytes [0 : CRC_OFFSET]

# PRNG constants reversed from eboot.elf
PRNG_KEY   = 0x4FC36442
PRNG_MAGIC = 0x1DA597
PRNG_C1    = 0x85C9C2   # added during PRNG state init (step 2)
PRNG_C2    = 0x10B9384  # added during PRNG state init (step 3) — address literal, not dereferenced
PRNG_C3    = 0x1915D46  # added during PRNG state init (step 4)

# Unlock flag values found in the save's gallery/character block
FLAG_LOCKED   = 0x00020000
FLAG_UNLOCKED = 0x00020040
FLAG_BLOCK_START = 0x001CB8
FLAG_BLOCK_END   = 0x1E5B44  # exclusive

# Gold offsets (two separate currency slots that both hold the same value)
GOLD_OFFSETS = [0x207DD4, 0x207DD8]


# ─────────────────────────────────────────────────────────────────────────────
# PRNG XOR stream cipher  (encrypt == decrypt — same operation)
# ─────────────────────────────────────────────────────────────────────────────

def _u32(x):
    return x & 0xFFFFFFFF


def _prng_init(key):
    """Seed the four-word PRNG state from a 32-bit key."""
    s0 = _u32(_u32(PRNG_MAGIC * key) ^ _u32(key >> 5))
    s1 = _u32(_u32(PRNG_MAGIC * s0)  ^ _u32(_u32(s0 >> 5) + PRNG_C1))
    s2 = _u32(_u32(PRNG_MAGIC * s1)  ^ _u32(_u32(s1 >> 5) + PRNG_C2))
    s3 = _u32(_u32(PRNG_MAGIC * s2)  ^ _u32(_u32(s2 >> 5) + PRNG_C3))
    return s0, s1, s2, s3


def _prng_step(s0, s1, s2, s3):
    """Advance the PRNG by one word and return the new state (s0, s1, s2, s3).
    The keystream word is the new s3 (last element of the returned tuple).
    State rotation: s0←s1, s1←s2, s2←old_s3, s3←new_keystream_word.
    """
    t      = _u32(s0 ^ _u32(s0 << 11))
    new_s3 = _u32(t ^ s3 ^ _u32(s3 >> 19) ^ _u32(t >> 8))
    return s1, s2, s3, new_s3


def _xor_stream(data: bytes) -> bytes:
    """Apply the PRNG keystream to data (works for both encrypt and decrypt)."""
    s0, s1, s2, s3 = _prng_init(PRNG_KEY)
    out = bytearray(len(data))
    i, n = 0, len(data)
    while i < n:
        s0, s1, s2, s3 = _prng_step(s0, s1, s2, s3)
        chunk = min(4, n - i)
        for j in range(chunk):
            out[i + j] = data[i + j] ^ ((s3 >> (8 * j)) & 0xFF)
        i += chunk

        if i % 0x40000 == 0:
            print("[*] Processed {} %".format(i * 100 // n))

    return bytes(out)


# ─────────────────────────────────────────────────────────────────────────────
# Checksum  (CRC-32/BZIP2 — non-reflected, poly 0x04C11DB7)
# ─────────────────────────────────────────────────────────────────────────────

def _verify_crc(data: bytes) -> bool:
    computed = struct.unpack(">I", uhashlib.crc32big(data[:CRC_OFFSET]))[0]
    stored   = struct.unpack_from("<I", data, CRC_OFFSET)[0]
    return computed == stored


# ─────────────────────────────────────────────────────────────────────────────
# Commands
# ─────────────────────────────────────────────────────────────────────────────

def jojo_decrypt(enc):
    """Decrypt a save and write the raw decrypted binary."""

    if len(enc) != SAVE_SIZE:
        raise Exception("[!] Unexpected file size: {actual:#x} (expected {expected:#x})".format(actual=len(enc), expected=SAVE_SIZE))

    print("[*] Decrypting...")
    dec = _xor_stream(enc)

    if _verify_crc(dec):
        crc = struct.unpack_from("<I", dec, CRC_OFFSET)[0]
        print("[+] CRC verified: {crc:#010x}".format(crc=crc))
    else:
        print("[-] CRC mismatch — decryption may have failed, check your key constants")

    print("[+] Processed 100%")
    enc[:] = dec  # overwrite input buffer with decrypted data


def jojo_encrypt(data):
    """Encrypt a decrypted save, ready to put back on PS4."""

    if len(data) != SAVE_SIZE:
        raise Exception("[!] Unexpected file size: {actual:#x} (expected {expected:#x})".format(actual=len(data), expected=SAVE_SIZE))

    print("[*] Encrypting...")
    enc = _xor_stream(bytes(data))

    print("[+] Processed 100%")
    data[:] = enc  # overwrite input buffer with encrypted data


def jojo_unlock_all(data):
    """Edit a decrypted save: unlock all gallery flags."""

    if len(data) != SAVE_SIZE:
        raise Exception("[!] Unexpected file size: {actual:#x} (expected {expected:#x})".format(actual=len(data), expected=SAVE_SIZE))

    count = 0
    for offset in range(FLAG_BLOCK_START, FLAG_BLOCK_END, 4):
        if struct.unpack_from("<I", data, offset)[0] == FLAG_LOCKED:
            struct.pack_into("<I", data, offset, FLAG_UNLOCKED)
            count += 1

    print("[+] Unlocked {} gallery/character flags".format(count))


# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

def jojo_crypt(mode, data: bytearray):
    """Main function to handle decryption/encryption of the save file"""

    if mode == DECRYPT:
        jojo_decrypt(data)
        print("Decryption complete, {} bytes".format(len(data)))

    elif mode == ENCRYPT:
        jojo_encrypt(data)
        print("Encryption complete, {} bytes".format(len(data)))

    else:
        raise Exception("Error: Unknown mode '{}', must be 'ENCRYPT' or 'DECRYPT'".format(mode))

    # Clean up
    gc.collect()
