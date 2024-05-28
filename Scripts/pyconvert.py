#!/usr/bin/env python3

import sys
import struct
import argparse
import logging

# Setup debug logging
logging.basicConfig(level=logging.DEBUG, format='%(message)s')
logger = logging.getLogger()

format_byte_size = {
    'ubyte': 2,  # 2 hex characters (1 byte)
    'ushort': 4,  # 4 hex characters (2 bytes)
    'uint32': 8,  # 8 hex characters (4 bytes)
    'uint64': 16,  # 16 hex characters (8 bytes)
    'float': 8,  # 8 hex characters (4 bytes)
    'doublefloat': 16  # 16 hex characters (8 bytes)
}

format_bounds = {
    'ubyte': (0, 255),
    'ushort': (0, 65535),
    'uint32': (0, 4294967295),
    'uint64': (0, 18446744073709551615),
    'float': (-3.4028235e+38, 3.4028235e+38),
    'doublefloat': (-1.7976931348623157e+308, 1.7976931348623157e+308)
}

format_map = {
    'ubyte': 'B',
    'ushort': 'H',
    'uint32': 'I',
    'uint64': 'Q',
    'float': 'f',
    'doublefloat': 'd'
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
        return sign << 15  # zero
    elif exponent == 255:
        return (sign << 15) | 0x7C00  # inf/nan
    
    new_exp = exponent - 127 + 15
    if new_exp >= 31:  # overflow
        return (sign << 15) | 0x7C00  # inf
    elif new_exp <= 0:  # underflow to subnormal or zero
        if new_exp < -10:
            return sign << 15  # too small becomes zero
        fraction = (fraction | 0x800000) >> (1 - new_exp)
        return (sign << 15) | (fraction >> 13)
    else:
        hex_value = (sign << 15) | (new_exp << 10) | (fraction >> 13)
        if little_endian:
            hex_value = ((hex_value & 0xFF) << 8) | ((hex_value & 0xFF00) >> 8)
        return hex_value

def generic_conversion(value, format_str, little_endian, to_hex=True):
    byte_order = '<' if little_endian else '>'
    struct_format = format_map[format_str]
    
    # Check if the value is hexadecimal
    is_hex = value.startswith('0x')
    value_cleaned = value.replace('0x', '')

    try:
        if struct_format in ['f', 'd']:  # Handling floats and doubles
            float_value = float(value) if not is_hex else None
            if to_hex:
                if is_hex:
                    int_value = int(value, 16)
                    packed_value = struct.pack(byte_order + struct_format.replace("f", "I").replace("d", "Q"), int_value)
                else:
                    packed_value = struct.pack(byte_order + struct_format, float_value)
                hex_value = hex(struct.unpack(byte_order + struct_format.replace("f", "I").replace("d", "Q"), packed_value)[0])[2:].upper()
            else:
                if is_hex:
                    if len(value_cleaned) > format_byte_size[format_str]:
                        raise ValueError(f"Hex value exceeds the allowed byte size for format {format_str}[{format_byte_size[format_str]}].")
                    if little_endian:
                        value_cleaned = ''.join(reversed([value_cleaned[i:i + 2] for i in range(0, len(value_cleaned), 2)]))
                    int_val = int(value_cleaned, 16)
                    unpacked_value = struct.unpack(byte_order + struct_format, struct.pack(byte_order + struct_format.replace("f", "I").replace("d", "Q"), int_val))
                    return f"Dec: {unpacked_value[0]}"
                else:
                    packed_value = struct.pack(byte_order + struct_format, float_value)
                    hex_value = hex(struct.unpack(byte_order + struct_format.replace("f", "I").replace("d", "Q"), packed_value)[0])[2:].upper()
        else:  # Handling other integer types
            if is_hex:
                int_value = int(value_cleaned, 16)
                if int_value < format_bounds[format_str][0] or int_value > format_bounds[format_str][1]:
                    raise ValueError(f"Hex value {value} out of bounds for format {format_str}. Allowed range: {format_bounds[format_str][0]} to {format_bounds[format_str][1]}.")
            else:
                int_value = int(value)
            if to_hex:
                packed_value = struct.pack(byte_order + struct_format, int_value)
                hex_value = hex(struct.unpack(byte_order + struct_format.upper(), packed_value)[0])[2:].upper()
            else:
                if is_hex:
                    if len(value_cleaned) > format_byte_size[format_str]:
                        raise ValueError(f"Hex value exceeds the allowed byte size for format {format_str}[{format_byte_size[format_str]}].")
                    if little_endian:
                        value_cleaned = ''.join(reversed([value_cleaned[i:i + 2] for i in range(0, len(value_cleaned), 2)]))
                    int_value = int(value_cleaned, 16)
                packed_value = struct.pack(byte_order + struct_format, int_value)
                return f"Dec: {struct.unpack(byte_order + struct_format, packed_value)[0]}"
        
        # Correctly reverse the hexadecimal string for little-endian
        if little_endian:
            hex_value = hex_value.zfill(format_byte_size[format_str])
            hex_value = ''.join(reversed([hex_value[i:i + 2] for i in range(0, len(hex_value), 2)]))
    except Exception as e:
        raise ValueError(f"Error when processing value {value} with format string {format_str}. Error: {e}")
    
    # Adjust hex representation for byte size
    hex_value = hex_value.zfill(format_byte_size[format_str])

    # Return formatted string
    return f"Hex: {hex_value}"

def check_bounds(value, format_str):
    lower, upper = format_bounds[format_str]
    logger.debug(f"Checking bounds for value {value} in range {lower} to {upper}")
    if not lower <= value <= upper:
        raise ValueError(f"Value out of bounds for format {format_str}. Allowed range: {lower} to {upper}.")

def alias_parser(args):
    alias_map = {
        "-hf": "--halffloat",
        "-fl": "--float",
        "-df": "--doublefloat",
        "-ui8": "--ubyte",
        "-ui16": "--ushort",
        "-ui32": "--uint32",
        "-ui64": "--uint64",
        "-ltl": "--little"
    }
    new_args = []
    for arg in args:
        if arg in alias_map:
            new_args.append(alias_map[arg])
        else:
            new_args.append(arg)
    return new_args

def main():
    parser = argparse.ArgumentParser(description="Convert decimal and hex values.", allow_abbrev=False)
    parser.add_argument("value", help="Value to be converted")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--halffloat", action="store_true", help="Convert to/from half float")
    group.add_argument("--float", action="store_true", help="Convert to/from float")
    group.add_argument("--doublefloat", action="store_true", help="Convert to/from double float")
    group.add_argument("--ubyte", action="store_true", help="Convert to/from unsigned byte")
    group.add_argument("--ushort", action="store_true", help="Convert to/from unsigned short")
    group.add_argument("--uint32", action="store_true", help="Convert to/from unsigned int (32-bit)")
    group.add_argument("--uint64", action="store_true", help="Convert to/from unsigned int (64-bit)")
    parser.add_argument("--little", action="store_true", help="Use little endian byte order")
    parser.add_argument("--debug", action="store_true", help="Enable debug output")
    
    args = parser.parse_args(alias_parser(sys.argv[1:]))

    value = args.value
    little_endian = args.little
    debug = args.debug

    if debug:
        logger.setLevel(logging.DEBUG)
    else:
        logger.setLevel(logging.ERROR)

    # Validate value based on the selected type
    if '.' in value:
        if not (args.halffloat or args.float or args.doublefloat):
            print("Error: Decimal points are only allowed for float, double float, and half float types.")
            sys.exit(1)

    # Validate value against format bounds if it's not in hexadecimal
    if not value.startswith('0x'):
        try:
            if args.ubyte:
                check_bounds(int(value), 'ubyte')
            elif args.ushort:
                check_bounds(int(value), 'ushort')
            elif args.uint32:
                check_bounds(int(value), 'uint32')
            elif args.uint64:
                check_bounds(int(value), 'uint64')
            elif args.float:
                check_bounds(float(value), 'float')
            elif args.doublefloat:
                check_bounds(float(value), 'doublefloat')
        except ValueError as e:
            print(e)
            sys.exit(1)
    else:
        # Validate hexadecimal value against format byte size
        value_cleaned = value.replace('0x', '')
        if args.ubyte and len(value_cleaned) > format_byte_size['ubyte']:
            print(f"Hex value {value} exceeds the allowed byte size for format ubyte[{format_byte_size['ubyte']}].")
            sys.exit(1)
        elif args.ushort and len(value_cleaned) > format_byte_size['ushort']:
            print(f"Hex value {value} exceeds the allowed byte size for format ushort[{format_byte_size['ushort']}].")
            sys.exit(1)
        elif args.uint32 and len(value_cleaned) > format_byte_size['uint32']:
            print(f"Hex value {value} exceeds the allowed byte size for format uint32[{format_byte_size['uint32']}].")
            sys.exit(1)
        elif args.uint64 and len(value_cleaned) > format_byte_size['uint64']:
            print(f"Hex value {value} exceeds the allowed byte size for format uint64[{format_byte_size['uint64']}].")
            sys.exit(1)

    if args.halffloat:
        if '0x' in value:
            int_value = int(value, 16)
            result = f"Dec: {half_float_to_float(int_value, little_endian)}"
        else:
            float_value = float(value)
            check_bounds(float_value, 'float')
            hex_value = hex(float_to_half_float(float_value, little_endian))[2:].upper().zfill(4)
            result = f"Hex: {hex_value}"
    elif args.float:
        result = generic_conversion(value, 'float', little_endian, not value.startswith('0x'))
    elif args.doublefloat:
        result = generic_conversion(value, 'doublefloat', little_endian, not value.startswith('0x'))
    elif args.ubyte:
        result = generic_conversion(value, 'ubyte', little_endian, not value.startswith('0x'))
    elif args.ushort:
        result = generic_conversion(value, 'ushort', little_endian, not value.startswith('0x'))
    elif args.uint32:
        result = generic_conversion(value, 'uint32', little_endian, not value.startswith('0x'))
    elif args.uint64:
        result = generic_conversion(value, 'uint64', little_endian, not value.startswith('0x'))

    print(result)

if __name__ == "__main__":
    main()
