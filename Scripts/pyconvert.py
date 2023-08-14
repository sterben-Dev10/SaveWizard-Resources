#!/usr/bin/env python3
# ChatGPT Generated Script.

import sys
import struct
import argparse

format_byte_size = {
    'B': 2,
    'H': 4,
    'I': 8,
    'Q': 16,
    'f': 8,
    'd': 16
}

format_bounds = {
    'B': (0, 255),
    'H': (0, 65535),
    'I': (0, 4294967295),
    'Q': (0, 18446744073709551615),
    'f': (-3.4028235e+38, 3.4028235e+38),
    'd': (-1.7976931348623157e+308, 1.7976931348623157e+308)
}

def half_float_to_float(i, little_endian):
    if little_endian:
        i = ((i & 0xFF) << 8) | ((i & 0xFF00) >> 8)
        
    sign = (i >> 15) & 0x1
    exponent = (i >> 10) & 0x1F
    fraction = i & 0x3FF

    if exponent == 0:
        if fraction == 0:
            return (-1) ** sign * 0.0
        else:
            # Subnormal number
            return (-1) ** sign * (fraction / 1024.0) * 2 ** (-14)
    elif exponent == 31:
        if fraction == 0:
            return float('-inf') if sign else float('inf')
        else:
            return float('nan')
    else:
        # Normalized number
        return (-1) ** sign * (1.0 + fraction / 1024.0) * 2 ** (exponent - 15)

def float_to_half_float(f, little_endian):
    s = struct.pack('>f', f)
    i = struct.unpack('>I', s)[0]
    
    sign = (i >> 31) & 0x1
    exponent = (i >> 23) & 0xFF
    fraction = i & 0x007FFFFF
    
    if exponent == 0:
        return 0  # zero
    elif exponent == 255:
        return (sign << 15) | 0x7C00  # inf/nan
    
    new_exp = exponent - 127 + 15
    if new_exp >= 31:  # overflow
        return (sign << 15) | 0x7C00  # inf
    elif new_exp <= 0:  # underflow
        return (sign << 15)
    else:
        hex_value = (sign << 15) | (new_exp << 10) | (fraction >> 13)
        if little_endian:
            hex_value = ((hex_value & 0xFF) << 8) | ((hex_value & 0xFF00) >> 8)
        return hex_value

def generic_conversion(value, format_str, little_endian, to_hex=True):
    byte_order = '<' if little_endian else '>'
    
    # Check if the value is hexadecimal
    is_hex = '0x' in value or all(c in '0123456789ABCDEFabcdef' for c in value)
    
    try:
        if format_str in ['f', 'd']:  # Handling floats and doubles
            if to_hex:
                packed_value = struct.pack(byte_order + format_str, float(value))
                hex_value = hex(struct.unpack(byte_order + format_str.replace("f", "I").replace("d", "Q"), packed_value)[0])[2:].upper()
                if little_endian:
                    hex_value = ''.join(reversed([hex_value[i:i+2] for i in range(0, len(hex_value), 2)]))
            else:
                if is_hex:
                    int_val = int(value, 16)
                    if little_endian:
                        value = ''.join(reversed([value[i:i+2] for i in range(2, len(value), 2)]))
                        int_val = int(value, 16)
                    unpacked_value = struct.unpack(byte_order + format_str, struct.pack(byte_order + format_str.replace("f", "I").replace("d", "Q"), int_val))
                    return unpacked_value[0]
                else:
                    packed_value = struct.pack(byte_order + format_str, float(value))
                    hex_value = hex(struct.unpack(byte_order + format_str.replace("f", "I").replace("d", "Q"), packed_value)[0])[2:].upper()
        else:  # Handling other integer types
            if to_hex:
                packed_value = struct.pack(byte_order + format_str, int(value))
                hex_value = hex(struct.unpack(byte_order + format_str.upper(), packed_value)[0])[2:].upper()
            else:
                if is_hex:
                    if little_endian:
                        value = '0x' + ''.join(reversed([value[i:i+2] for i in range(2, len(value), 2)]))
                    packed_value = struct.pack(byte_order + format_str.upper(), int(value, 16))
                else:
                    packed_value = struct.pack(byte_order + format_str, int(value))
                return struct.unpack(byte_order + format_str, packed_value)[0]

    except Exception as e:
        raise ValueError(f"Error when processing value {value} with format string {format_str}. Error: {e}")
    
    # Adjust hex representation for byte size
    hex_value = hex_value.zfill(format_byte_size[format_str])

    # Return formatted string
    return f"Hex: {hex_value}"

def check_bounds(value, format_str):
    lower, upper = format_bounds[format_str]
    if not lower <= value <= upper:
        raise ValueError(f"Value out of bounds for format {format_str}. Allowed range: {lower} to {upper}.")

def main():
    parser = argparse.ArgumentParser(description="Convert decimal and hex values.")
    parser.add_argument("value", help="Value to be converted")
    parser.add_argument("-hf", "--halffloat", action="store_true", help="Convert to/from half float")
    parser.add_argument("-fl", "--float", action="store_true", help="Convert to/from float")
    parser.add_argument("-df", "--doublefloat", action="store_true", help="Convert to/from double float")
    parser.add_argument("-ui8", "--ubyte", action="store_true", help="Convert to/from unsigned byte")
    parser.add_argument("-ui16", "--ushort", action="store_true", help="Convert to/from unsigned short")
    parser.add_argument("-ui32", "--uint", action="store_true", help="Convert to/from unsigned int")
    parser.add_argument("-ui64", "--uint64", action="store_true", help="Convert to/from unsigned 64-bit int")
    parser.add_argument("--little", "-ltl", action="store_true", help="Use little-endian format")

    args = parser.parse_args()
    
    to_hex = not args.value.startswith('0x')
    little_endian = args.little

    if args.halffloat:
        if to_hex:
            hex_value = hex(float_to_half_float(float(args.value), little_endian))[2:].upper()
            print(f"Hex: {hex_value.zfill(4)}")
        else:
            print(f"Dec: {half_float_to_float(int(args.value, 16), little_endian)}")
    elif args.float:
        format_str = 'f'
    elif args.doublefloat:
        format_str = 'd'
    elif args.ubyte:
        format_str = 'B'
    elif args.ushort:
        format_str = 'H'
    elif args.uint:
        format_str = 'I'
    elif args.uint64:
        format_str = 'Q'
    else:
        print("Please provide a valid conversion type.")
        sys.exit(1)

    if not args.halffloat:
        print(generic_conversion(args.value, format_str, little_endian, to_hex))

if __name__ == "__main__":
    main()
