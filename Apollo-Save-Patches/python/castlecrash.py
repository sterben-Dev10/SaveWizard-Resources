# Castle Crashers Remastered Save Encrypt/Decrypt
# Apollo script by Bucanero
#
# based on Castle-Crashers-Remastered-Save-Decrypt-PS4 by alfizari
# decrypt/encrypt the save file for Castle Crashers Remastered Save PS4
# Uses Blowfish with rolling xor checksum
# https://github.com/alfizari/Castle-Crashers-Remastered-Save-Decrypt-PS4
#

import apollo
import ucrypto
import ustruct as struct

MODE_ENCRYPT = ucrypto.ENCRYPT
MODE_DECRYPT = ucrypto.DECRYPT

# Keys and constants
BLOWFISH_KEY = b'\x12\xb96\xacz\x12S\x01~C\tfc\x83\xd4\x9fga>V98rr'
ROLLING_INIT = 0xD971
BLOCK_SIZE = 0x1050  # Encrypted size
DATA_LEN = 0x104C    # After decryption (without checksum)

def swap_endian(data):
    return apollo.endian_swap(data, 4)

def castlecrash_checksum(plain_data):
    state = ROLLING_INIT
    calculated_sum = 0
    for byte in plain_data:
        xor_byte = ((state >> 8) ^ byte) & 0xFF
        calculated_sum = (calculated_sum + xor_byte) & 0xFFFFFFFF
        state = ((state & 0xFFFF) + xor_byte) * 0xCE6D + 0x58BF
        state &= 0xFFFF

    return calculated_sum

def ccr_decrypt(encrypted_data):
    swap_endian(encrypted_data)  # In-place endian swap
    ucrypto.blowfish_ecb(ucrypto.DECRYPT, encrypted_data, BLOWFISH_KEY)
    swap_endian(encrypted_data)

def ccr_encrypt(plain_data):
    swap_endian(plain_data)
    ucrypto.blowfish_ecb(ucrypto.ENCRYPT, plain_data, BLOWFISH_KEY)
    swap_endian(plain_data)

def castlecrash_crypt(mode, data: bytearray):
    if BLOCK_SIZE > len(data):
        raise Exception("Error: Save size mismatch, expected {}, got {}".format(BLOCK_SIZE, len(data)))

    if mode == MODE_DECRYPT:
        ccr_decrypt(data)

        stored_sum = struct.unpack_from('<I', data, DATA_LEN)[0]
        if castlecrash_checksum(data[:DATA_LEN]) != stored_sum:
            print("Warning: Checksum mismatch, expected 0x{:08X}".format(stored_sum))

        print("Decryption complete, {} bytes".format(len(data)))

    elif mode == MODE_ENCRYPT:
        ccr_encrypt(data)
        print("Encryption complete, {} bytes".format(len(data)))

    else:
        raise Exception("Error: Unknown mode '{}', must be 'MODE_ENCRYPT' or 'MODE_DECRYPT'".format(mode))
