#
# Dead or Alive 5 (PS3/PS4/Vita) decrypter & checksum fixer by Bucanero
# based on doa5.py by https://github.com/alfizari
#

import gc
import ucrypto
import ustruct as struct

ENCRYPT = ucrypto.ENCRYPT
DECRYPT = ucrypto.DECRYPT


def next_seed(seed):
    return ((seed << 4) + (seed >> 4)) & 0xFFFFFFFF


def crypt_block(block, seed, byte_order):
    print("* Processing {} bytes ...".format(len(block)))

    for i in range(0, len(block), 4):
        word = struct.unpack_from(byte_order + "I", block, i)[0]
        struct.pack_into(byte_order + "I", block, i, word ^ seed)
        seed = next_seed(seed)

    return


def calc_checksum(data):
    return sum(data) & 0xFFFFFFFF


def decrypt_save(data, byte_order):
    offset = 0

    # Stop when there is no room left for a block header (DOA5 Last Round PS3 saves have a 4-byte trailer)
    while offset + 16 <= len(data):
        magic, size, checksum, seed = struct.unpack_from(byte_order + "IIII", data, offset)

        print("Decrypting Block At Offset 0x{:X}".format(offset))
#        print(" - Block Magic: 0x{:08X} Size: 0x{:08X} Checksum: 0x{:08X} Seed: 0x{:08X}".format(magic, size, checksum, seed))

        if size == 0:
            size = len(data) - offset

        if size < 16 or size > len(data) - offset:
            print("[!] Invalid block size 0x{:X}".format(size))
            break

        section = data[(offset+16):(offset+size)]

        if calc_checksum(section) != checksum:
            print("[!] Warning: Checksum mismatch for block! Expected 0x{:08X}".format(checksum))

        crypt_block(section, seed, byte_order)
        data[(offset+16):(offset+size)] = section
        offset += size

    return


def encrypt_save(data, byte_order):
    offset = 0

    # Stop when there is no room left for a block header (DOA5 Last Round PS3 saves have a 4-byte trailer)
    while offset + 16 <= len(data):
        magic, size, checksum, seed = struct.unpack_from(byte_order + "IIII", data, offset)

        print("Encrypting Block At Offset 0x{:X}".format(offset))
#        print(" - Block Magic: 0x{:08X} Size: 0x{:08X} Checksum: 0x{:08X} Seed: 0x{:08X}".format(magic, size, checksum, seed))

        if size == 0:
            size = len(data) - offset

        if size < 16 or size > len(data) - offset:
            print("[!] Invalid block size 0x{:X}".format(size))
            break

        section = data[(offset+16):(offset+size)]

        crypt_block(section, seed, byte_order)
        data[(offset+16):(offset+size)] = section

        checksum = calc_checksum(section) 
        struct.pack_into(byte_order + "I", data, offset+8, checksum)
        print("* New Block Checksum {:08X}".format(checksum))

        offset += size

    return


def doa5_crypt(mode, data: bytearray):
    """Main function to handle decryption/encryption of the save file"""

    byteorder = ">" if (data[:3] == b"\x00\x00\x00" and data[4] == 0 and data[5] == 0) else "<"

    if mode == DECRYPT:
        decrypt_save(data, byteorder)
        print("Decryption complete, {} bytes".format(len(data)))

    elif mode == ENCRYPT:
        encrypt_save(data, byteorder)
        print("Encryption complete, {} bytes".format(len(data)))

    else:
        raise Exception("Error: Unknown mode '{}', must be 'ENCRYPT' or 'DECRYPT'".format(mode))

    # Clean up
    gc.collect()
