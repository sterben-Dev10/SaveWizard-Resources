#
# Dying Light 2 Save Checksum Fixer
# Apollo script by Bucanero
# based on https://github.com/B-a-t-a-n-g/Dying_Light_2_Checksum/ by Batang
#

import uhashlib
import ustruct as struct

STRUCT_SIZE = 20
MAGIC_SGDS  = b'SGDS'
MAGIC_SGDD  = b'SGDD'

TARGET_MAGICS = {MAGIC_SGDS, MAGIC_SGDD}

CRC64_POLY = 0xAD93D23594C935A9
CRC64_INIT = 0xFFFFFFFFFFFFFFFF
CRC64_XOROUT = 0xFFFFFFFFFFFFFFFF


def crc64(data: bytes) -> int:
    crc = uhashlib.crc(data, uhashlib.CRC_64_BITS, CRC64_POLY, CRC64_INIT, CRC64_XOROUT, 1, 1)
    return struct.unpack('>Q', crc)[0]


def dyinglight2_checksum(data: bytearray) -> int:
    file_size = len(data)
    found = 0
    fixed = 0
    offset = 0

    while offset <= file_size - STRUCT_SIZE:
        magic = data[offset:offset + 4]

        if magic != MAGIC_SGDS and magic != MAGIC_SGDD:
            offset += 1
            continue

        try:
            magic_val, seg_type, stored_crc, size = struct.unpack_from('<IIQI', data, offset)

            segment_offset = offset + STRUCT_SIZE
            segment_end    = segment_offset + size

            if segment_end > file_size:
                offset += 4
                continue

            segment = data[segment_offset:segment_end]

            print("-" * 50)
            print("{} @ 0x{:08X}".format(magic, offset))
            print("Type          : {}".format(seg_type))
            print("Size          : {}".format(size))
            print("CRC range     : 0x{:08X} - 0x{:08X}".format(segment_offset, segment_end))
            print("Stored        : {:016X}".format((stored_crc)))

            if seg_type == 1:
                print("CRC           : SKIPPED")

            elif seg_type == 2:
                calc_crc = crc64(segment)

                print("Calc          : {:016X}".format((calc_crc)))

                if (calc_crc == stored_crc):
                    print("Result        : OK")
                else:
                    print("Result        : MISMATCH")
                    print("[i] CRC Fixed")
                    struct.pack_into('<Q', data, offset + 8, calc_crc)
                    fixed += 1

            else:
                print("CRC           : UNKNOWN TYPE (no check)")

            found += 1

        except Exception as e:
            print("Error at 0x{0:X}: {1}".format(offset, e))

        offset += 4

    if found == 0:
        print("No segments found.")
    else:
        print("\nDone — {} segment(s) scanned, {} fixed.".format(found, fixed))

    return fixed
