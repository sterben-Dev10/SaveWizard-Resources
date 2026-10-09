# Sword Art Online: Fatal Bullet - HMAC-SHA1 checksum fix - Apollo script by Bucanero
# Based on the work of alfazari911
# https://discord.com/channels/347662863986327555/1097201528466587678/1496957572530438264

import uhashlib
import ubinascii
import apollo

HMAC_KEY = b"1FB00CC8D8D94CD0A94C847C2F04A921"

def find_hash_offset(data):
    search_range = data[-0x1000:]
    
    first_off = apollo.search(search_range, b'\x00\x00\x00\x00\x14\x00\x00\x00')

    if first_off is None:
        print("checksum not required")
        return

    absolute_offset = len(data) - 0x1000 + first_off + 4 # +4 to skip the 0x14 00 00 00
    print("Target offset: 0x{:08X}".format(absolute_offset))

    return absolute_offset

def sao_fb_checksum(data):
    """This function takes the save data as input, checks if it needs to be patched, and if so, computes the new HMAC-SHA1 checksum."""
    hash_offset = find_hash_offset(data)

    if hash_offset is None:
        print("No patching needed (save most likely at base version)")
        return 0

    new_hash = uhashlib.hmac_sha1(HMAC_KEY, data[:hash_offset])
    data[hash_offset+4:hash_offset+24] = new_hash
    
    print("New HMAC-SHA1: {}".format(ubinascii.hexlify(new_hash).decode().upper()))

    return 1
