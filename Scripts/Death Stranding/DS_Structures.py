#!/usr/bin/env python

# Death Stranding All Structures Repair - PS4 Saves Only
# ChatGPT Generated Script, Research Done By XxUnkn0wnxX

import struct
import sys
import signal
import argparse

# Define values
struct_lvl = 4 # Structure Level
float_val = 9999999 # Structure Health
struct_val = 99999 # Some other value regarding the structure

# struct_lvl = 4
# float_val = 9999999
# struct_val = 99999

# Convert hex string to bytes
first_hex = bytes.fromhex('BFABAAAABFABAAAA3F')
second_hex = bytes.fromhex('FFFFFFFF')

# Signal handler function
def signal_handler(signal, frame):
    print('SIGINT received. Exiting.')
    sys.exit(0)

# Set the signal handler
signal.signal(signal.SIGINT, signal_handler)

# Function to find pointers
def find_pointers(start_index, content):
    # Find first pointer
    first_pointer = content.find(first_hex, start_index)
    if first_pointer == -1:
        print('End of File Reached')
        return -1, -1
    print(f'First pointer found at address: 0x{first_pointer:x}')

    # Find second pointer backwards from the first pointer
    second_pointer = content.rfind(second_hex, 0, first_pointer)
    if second_pointer == -1:
        print('Second hex not found')
        return -1, -1
    print(f'Second pointer found at address: 0x{second_pointer:x}')

    # Calculate third pointer
    third_pointer = second_pointer - 0x8C
    if third_pointer < 0:
        print('Third pointer address is negative')
        return -1, -1
    print(f'Third pointer is at address: 0x{third_pointer:x}')

    return first_pointer, third_pointer

# Create argument parser
parser = argparse.ArgumentParser(description='Process a binary file.')
parser.add_argument('file', type=str, help='Path to the file to process.')
parser.add_argument('--times', type=int, help='Number of times to modify the file.')
parser.add_argument('--bak', action='store_true', help='Create a backup of the original file.')
args = parser.parse_args()

# Get file path from command line arguments
file_path = args.file

# Open file in binary mode
with open(file_path, 'rb') as f:
    content = f.read()

# If --bak is provided, create a backup of the original file
if args.bak:
    with open(file_path + '.bak', 'wb') as f:
        f.write(content)

# Copy content to a bytearray for manipulation
content = bytearray(content)

# Initial start index
start_index = 0

# Count of modifications
count = 0

while True:
    print('---------------------------------------')
    # Find third pointer
    first_pointer, third_pointer = find_pointers(start_index, content)

    # Break if no more pointers can be found
    if third_pointer == -1:
        break

    # Check first two bytes at third pointer
    value1, value2 = struct.unpack('<BB', content[third_pointer:third_pointer+2])
    if value1 in range(1, 255) and value2 in range(1, 255):
        print(f'Values at third pointer are: {value1}, {value2}')

        # Check value at third pointer + 0x4
        value = struct.unpack('<B', content[third_pointer+0x4:third_pointer+0x5])[0]
        if value < 5:
            print(f'Value at third pointer + 0x4 is: {value}')

            # Write value at third pointer + 0x4
            content[third_pointer+0x4:third_pointer+0x5] = struct.pack('<B', struct_lvl)
            print(f'Value {struct_lvl} written at third pointer + 0x4')

            # Write float value at third pointer + 0x2C
            content[third_pointer+0x2C:third_pointer+0x2C+4] = struct.pack('<f', float_val)
            print(f'Float value {float_val} written at third pointer + 0x2C')

            # Write struct_val six times at third pointer + 0x38, each 4 bytes apart
            for i in range(6):
                content[third_pointer+0x38+i*4:third_pointer+0x38+i*4+4] = struct.pack('<I', struct_val)
            print(f'Value {struct_val} written six times at third pointer + 0x38, each 4 bytes apart')
    else:
        print('Values at third pointer are not in range 1-254. Continuing to next pointer.')

    # Update start index for next loop
    start_index = first_pointer + 1

    # Increase count of modifications
    count += 1

    # Stop if count reached the limit specified by --times
    if args.times is not None and count >= args.times:
        break

# Overwrite the original file
with open(file_path, 'wb') as f:
    f.write(content)

print()
print()
print('File saved successfully')