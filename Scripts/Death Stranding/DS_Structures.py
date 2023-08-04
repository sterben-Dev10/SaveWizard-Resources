
#!/usr/bin/env python

# Death Stranding All Structures Repair - PS4 Saves Only
# ChatGPT Generated Script, Research Done By XxUnkn0wnxX

import struct
import sys
import signal
import argparse

# Variables
struct_lvl = 4 # Structure level, 4 = lvl 3
float_val = 2147483000.0 # Structure Health
struct_val = 99999 # Upgrades

# Defaults
# struct_lvl = 4 
# float_val = 9999999.0 
# struct_val = 99999 

# Initialize counter
edit_count = 0

# Count of modifications
count = 0

# Initialize global variable for successful edit status
global is_successful_edit
is_successful_edit = False

# Check if struct_lvl exceeds 1 byte
if not (0 <= struct_lvl <= 5):
    raise ValueError("The value of struct_lvl must be between 0 and 5.")

# Comment the above code then uncomment this if you want to mess with higher level above LVL 4
# if not (0 <= struct_lvl <= 255):
#    raise ValueError("The value of struct_lvl must be between 0 and 255.")

# Check if float_val or struct_val exceed 4 bytes
if not (-2147483648 <= float_val <= 2147483647):
    raise ValueError("The value of float_val must be between -2147483648 and 2147483647.")

if not (0 <= struct_val <= 4294967295):
    raise ValueError("The value of struct_val must be between 0 and 4294967295.")

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
        print('End of File Reached,')
        return -1, -1, -1

    # Find second pointer backwards from the first pointer
    second_pointer = content.rfind(second_hex, 0, first_pointer)
    if second_pointer == -1:
        return -1, -1, -1

    # Calculate third pointer
    third_pointer = second_pointer - 0x8C
    if third_pointer < 0:
        return -1, -1, -1

    return first_pointer, second_pointer, third_pointer

# Create argument parser
parser = argparse.ArgumentParser(description='Process a binary file.')
parser.add_argument('file', type=str, help='Path to the file to process.')
parser.add_argument('--times', type=int, help='Number of times to modify the file.')
parser.add_argument('--bak', action='store_true', help='Create a backup of the original file.')
parser.add_argument('--debug', action='store_true', help='Print debug information')
parser.add_argument('--skipchecks', type=str, help='Specify checks to skip. Options: 1, 2, all, or a range like 1-2')
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

# Process the --skipchecks argument
skip_checks = []
if args.skipchecks:
    if args.skipchecks.lower() == 'all':
        skip_checks = [1, 2]  # Add the numbers of all checks here
    elif ',' in args.skipchecks:
        values = args.skipchecks.split(',')
        if len(values) < 2 or not all(i.isdigit() for i in values):
            raise ValueError("Invalid value for --skipchecks. Expecting two comma-separated numbers.")
        skip_checks = [int(i) for i in values]
    elif '-' in args.skipchecks:
        values = args.skipchecks.split('-')
        if len(values) < 2 or not all(i.isdigit() for i in values):
            raise ValueError("Invalid value for --skipchecks. Expecting two dash-separated numbers.")
        start, end = [int(i) for i in values]
        skip_checks = list(range(start, end + 1))
    elif args.skipchecks.isdigit():
        skip_checks = [int(args.skipchecks)]
    else:
        raise ValueError("Invalid value for --skipchecks.")

while True:
    # Find third pointer
    is_successful_edit = False
    first_pointer, second_pointer, third_pointer = find_pointers(start_index, content)

    # Break if no more pointers can be found
    if third_pointer == -1:
        break

    # Check first two bytes at third pointer, Inside the loop, increment the counter every time an edit is made
    value1, value2 = struct.unpack('<BB', content[third_pointer:third_pointer+2])
    if 1 in skip_checks or (value1 in range(1, 255) and value2 in range(1, 255)):

        # Check value at third pointer + 0x4
        value = struct.unpack('<B', content[third_pointer+0x4:third_pointer+0x5])[0]
        if 2 in skip_checks or value <= 5:
            # Perform actions if check 2 is not skipped
            # Increment edit count
            edit_count += 1
            count += 1 # Count the successful modification
            is_successful_edit = True

            # Print pointer information for successful edit
            print(f'First pointer found at address: 0x{first_pointer:x}')
            print(f'Second pointer found at address: 0x{second_pointer:x}')
            print(f'Third pointer is at address: 0x{third_pointer:x}')

            # Write value at third pointer + 0x4
            content[third_pointer+0x4:third_pointer+0x5] = struct.pack('<B', struct_lvl)

            # Write float value at third pointer + 0x2C
            content[third_pointer+0x2C:third_pointer+0x2C+4] = struct.pack('<f', float_val)

            # Write struct_val six times at third pointer + 0x38, each 4 bytes apart
            for i in range(6):
                content[third_pointer+0x38+i*4:third_pointer+0x38+i*4+4] = struct.pack('<I', struct_val)

            # Print information about what was written for successful edit
            print(f'Value {struct_lvl} written at third pointer + 0x4')
            print(f'Float value {float_val} written at third pointer + 0x2C')
            print(f'Value {struct_val} written six times at third pointer + 0x38, each 4 bytes apart')

            if args.debug:
                print(f'- Debug Check 1: 1st Two Values at third pointer are: {value1}, {value2}')
                print(f'- Debug Check 2: 3rd Value at third pointer + 0x4 is: {value}')
        else:
            if args.debug:
                print(f'First pointer found at address: 0x{first_pointer:x}')
                print(f'Second pointer found at address: 0x{second_pointer:x}')
                print(f'Third pointer is at address: 0x{third_pointer:x}')
                print(f'- Debug Check 1: Success, values at third pointer are: {value1}, {value2}')
                print('- Debug Check 2: 3rd Value at third pointer is not less than or equal 5. Continuing to next pointer.')
    else:
        if args.debug:
            print(f'First pointer found at address: 0x{first_pointer:x}')
            print(f'Second pointer found at address: 0x{second_pointer:x}')
            print(f'Third pointer is at address: 0x{third_pointer:x}')
            print('- Debug Check 1: 1st Two Values at third pointer are not in range 1-254. Continuing to next pointer.')


    if is_successful_edit or args.debug:
        print('---------------------------------------')

    # Update start index for next loop
    start_index = first_pointer + 1

    # Stop if count reached the limit specified by --times
    if args.times is not None and count >= args.times:
        break

# Print the count of edits before saving the file
print(f'Total edits made: {edit_count}')

# Save the modified content to the file
with open(args.file, 'wb') as f:
    f.write(content)
    
print('---------------------------------------')
print('File saved successfully')
