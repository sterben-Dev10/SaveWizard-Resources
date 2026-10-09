"""
Goat Simulator 3 - PS4 Save Decrypt/Re-encrypt Tool

Apollo script by Bucanero, based on python script by brotherguns5624

HOW THE SAVE IS STRUCTURED
---------------------------

  Bytes 0-7   : Magic constant  0x1a4777924f98f282  (plaintext, little-endian)
  Bytes 8-11  : Uncompressed size (little-endian uint32)
  Bytes 12-15 : Ciphertext size  (little-endian uint32)
  Bytes 16+   : AES-256-ECB encrypted payload

The encrypted payload decrypts to a zlib-compressed UE4 GVAS binary.

CIPHER DETAILS (from EBOOT.ELF reverse engineering)
-----------------------------------------------------
  Algorithm : AES-256-ECB  (no IV, no CBC chaining)
  Key       : hardcoded 32 bytes at VA 0x06efa6d0 in EBOOT.ELF
              (file offset 0x6efe6d0)
  Padding   : PKCS7 to 16-byte boundary
  After AES : zlib decompress -> raw GVAS

The AES implementation is a custom 4-table lookup (not OpenSSL).
Key schedule lives in FUN_02f3b890, encrypt in FUN_023af540,
decrypt in FUN_02f3b9e0.
"""

import ucrypto
import uzlib as zlib
import ustruct as struct

ENCRYPT = ucrypto.ENCRYPT
DECRYPT = ucrypto.DECRYPT

# Hardcoded AES-256 key from EBOOT.ELF (VA 0x06efa6d0)
AES256_KEY = b'L\x08Tq:Q\xa1\x04\xfe\x9b\x1fu"u\xd26O`\x06D\xb6\xdeOTs\xdb[\x92\'>\xc0\xaf'

# Save file magic (first 8 bytes, stored little-endian)
MAGIC = 0x82f2984f9277471a  # = 0x1a4777924f98f282 as bytes in file


def goats3_decrypt(data, cipher_size):
    """
    Decrypt a GS3 PS4 save file -> raw GVAS binary.
    """
    ciphertext  = data[16:16 + cipher_size]

    # AES-256-ECB decrypt
    plain = ucrypto.aes_ecb(DECRYPT, ciphertext, AES256_KEY)

    # Strip PKCS7 padding (last byte tells you how many pad bytes to remove)
    pad   = plain[-1]
    plain = plain[:-pad]

    # zlib decompress -> GVAS
    out = zlib.decompress(plain)

    print("Decrypted + unpacked {} bytes".format(len(out)))
    return data[:16] + out


def goats3_encrypt(data, decomp_size):
    """
    Re-encrypt a modified GVAS back into a GS3 PS4 save file.
    """
    plain = data[16:16 + decomp_size]

    # zlib compress
    compressed = zlib.compress(plain)

    # PKCS7 pad to 16-byte boundary
    pad        = 16 - (len(compressed) % 16)
    compressed += bytes([pad]) * pad

    cipher_size = len(compressed)

    # AES-256-ECB encrypt
    ciphertext = ucrypto.aes_ecb(ENCRYPT, compressed, AES256_KEY)

    # Write header + ciphertext
    header = struct.pack('<QII', MAGIC, decomp_size, cipher_size)

    print("Encrypted + compressed {} bytes".format(cipher_size))
    return header + ciphertext


def gs3_crypt(mode, data: bytearray):
    # Verify magic
    magic, decomp_size, cipher_size = struct.unpack_from('<QII', data, 0)
    if magic != MAGIC:
        raise ValueError("Not a GS3 save - bad magic: {}".format(magic))

    if mode == DECRYPT:
        data[:] = goats3_decrypt(data, cipher_size)

        if (len(data) - 16) != decomp_size:
            raise ValueError("Decompress size mismatch, expected: {}".format(decomp_size))

        print("Decryption complete, {} bytes".format(len(data)))

    elif mode == ENCRYPT:
        data[:] = goats3_encrypt(data, decomp_size)
        print("Encryption complete, {} bytes".format(len(data)))

    else:
        raise Exception("Error: Unknown mode '{}', must be 'ENCRYPT' or 'DECRYPT'".format(mode))
