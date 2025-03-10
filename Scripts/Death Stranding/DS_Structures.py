#!/usr/bin/env python3

# Death Stranding All Structures Repair - PS4 Saves Only
# OpenAI Generated Script, Research Done By XxUnkn0wnxX
# Script Ver 4.1.1

import os
import struct
import sys
import signal
import argparse
from colorama import init, Fore, Style

init(autoreset=True)

# Variables
struct_lvl = int(os.environ.get('struct_lvl', 5))  # Structure Level
float_health = float(os.environ.get('float_health', 2147483000.0))  # Structure Health
struct_upgrade = int(os.environ.get('struct_upgrade', 999999))  # Upgrades & Controls Level

# Defaults (for reference)
# struct_lvl = int(os.environ.get('struct_lvl', 3))
# float_health = float(os.environ.get('float_health', 9999999.0))
# struct_upgrade = int(os.environ.get('struct_upgrade', 999999))

# struct_lvl Controls wether Structure Health is applied depended on what this is set to
# if set to level 2, the struct_upgrade needs to match the min amount of materials for level 2
# if struct_lvl is set to 0,1,2,4,5 while the struct_upgrade is super maxed, I.E 9999999.0 
# the float_health value will be ignored on load time & just max out to the in-game max
# Example: 
# struct_lvl = int(os.environ.get('struct_lvl', 1))
# float_health = float(os.environ.get('float_health', 10.0))
# struct_upgrade = int(os.environ.get('struct_upgrade', 10)) 
# everything will be set to level 1 due to struct_upgrade being so low
# & the struct_lvl matching the level 1 requirement, due to struct_lvl set to 1, float_health takes into effect
# all buildings & road pavers will be rusted away.

# Initialize counters
edit_count = 0
skipped_edit_count = 0
count = 0

# Initialize global variable for successful edit status
global is_successful_edit
is_successful_edit = False

# Default skip_checks value
skip_checks = []

# Check if struct_lvl exceeds 1 byte
if not (0 <= struct_lvl <= 5):
    raise ValueError("The value of struct_lvl must be between 0 and 5.")

# Check if float_health or struct_upgrade exceed 4 bytes
if not (-2147483648 <= float_health <= 2147483647):
    raise ValueError("The value of float_health must be between -2147483648 and 2147483647.")

if not (0 <= struct_upgrade <= 4294967295):
    raise ValueError("The value of struct_upgrade must be between 0 and 4294967295.")

# Convert hex string to bytes
first_hex = bytes.fromhex('BFABAAAABFABAAAA3F')
second_hex = bytes.fromhex('FFFFFFFF')

# Signal handler function
def signal_handler(signal, frame):
    write_log('SIGINT received. Exiting.', args.logs)
    sys.exit(0)

# Set the signal handler
signal.signal(signal.SIGINT, signal_handler)

# Function to find pointers
def find_pointers(start_index, content):
    # Find first pointer
    first_pointer = content.find(first_hex, start_index)
    if first_pointer == -1:
        write_log('End of File Reached.', args.logs)
        write_log('', args.logs)
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

# Checks Functions
def check_1(value1, value2):
    # Ensures both values are within 1-254.
    return value1 in range(1, 255) and value2 in range(1, 255)

def check_2(value):
    # Ensures the value is less than or equal to 5.
    return value <= 5

def check_3(float_health_check):
    # Ensures the float health value is greater than 0.0.
    return float_health_check > 0.0

def check_4(region, allow_all_zero=True):
    """
    Revised check_4: Validate a 24-byte (0x18) region.
    The region is divided into 6 segments (each 4 bytes).
    For each segment, interpret it as an unsigned 32-bit integer (little-endian)
    and ensure the value is less than or equal to 2147483647 (0x7FFFFFFF).
    If allow_all_zero is False, the region must not consist solely of zeros.
    Returns True if all segments are valid.
    """
    if len(region) != 0x18:
        return False
    values = []
    for i in range(6):
        segment = region[i*4:(i+1)*4]
        unsigned_val = struct.unpack('<I', segment)[0]
        if unsigned_val > 0x7FFFFFFF:
            return False
        values.append(unsigned_val)
    if not allow_all_zero and all(v == 0 for v in values):
        return False
    return True

# Roads Check Functions Logic
def should_write_data_for_roads(skip_checks, value, float_health_check, region):
    """
    For roads/misc structures, evaluate whether to write data.
    Expects the 24-byte region (starting at third pointer + 0x38).
    In roads mode, the region must not be all zeros.
    """
    check_3_fail = (3 not in skip_checks) and not check_3(float_health_check)
    check_4_fail = (4 not in skip_checks) and not check_4(region, allow_all_zero=False)
    check_2_fail = (2 not in skip_checks) and not check_2(value)

    # If checks 2 & 4 are skipped but check 3 fails:
    if (2 in skip_checks) and (4 in skip_checks) and check_3_fail:
        return False
    # If checks 2 & 3 are skipped but check 4 fails:
    elif (2 in skip_checks) and (3 in skip_checks) and check_4_fail:
        return False
    # Otherwise, if check 2 passes and not both check 3 and check 4 fail:
    elif not check_2_fail and not (check_3_fail and check_4_fail):
        return True
    return False

def write_log(message, log_filename=None):
    # Strips ANSI color codes for file logging.
    clean_message = message.replace(Fore.YELLOW, '').replace(Fore.RED, '').replace(Fore.BLUE, '').replace(Fore.RESET, '')
    print(message)
    if log_filename:
        with open(log_filename, 'a') as log_file:
            log_file.write(clean_message + '\n')

# Create argument parser
parser = argparse.ArgumentParser(description='Process a binary file.')
parser.add_argument('file', type=str, help='Path to the file to process.')
parser.add_argument('--times', type=int, help='Number of times to modify the file.')
parser.add_argument('--bak', action='store_true', help='Create a backup of the original file.')
parser.add_argument('--debug', action='store_true', help='Print debug information')
parser.add_argument('--debug2', action='store_true', help='Debug mode without saving changes')
parser.add_argument('--logs', '-log', type=str, help='Specify a file to write logs to.')
parser.add_argument('--skipchecks', '-sc', type=str, help='Specify checks to skip. Options: 1, 2, 3, 4 all, or a range like 1-2')
parser.add_argument('--roads', action='store_true', help='Will Attempt to also include roads or misc structures')
args = parser.parse_args()

# If --debug2 is passed, always set --bak to True
if args.debug2:
    args.bak = True

# If logs argument is passed, open the log file in write mode
log_file = None
if args.logs:
    log_file = open(args.logs, 'w')

# Determine if writing should be forcefully prevented
force_no_write = (args.times == 0)

# Get file path from command line arguments and open file in binary mode
file_path = args.file
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

# If --roads is passed, always skip the first check
if args.roads:
    skip_checks.append(1)

# Process the --skipchecks argument to add additional checks to be skipped
if args.skipchecks:
    if args.skipchecks.lower() == 'all':
        skip_checks.extend([1, 2, 3, 4])  # Now includes checks 1 to 4
    elif ',' in args.skipchecks:
        values = args.skipchecks.split(',')
        if len(values) < 2 or not all(i.isdigit() for i in values):
            raise ValueError("Invalid value for --skipchecks. Expecting comma-separated numbers.")
        skip_checks.extend([int(i) for i in values])
    elif '-' in args.skipchecks:
        values = args.skipchecks.split('-')
        if len(values) < 2 or not all(i.isdigit() for i in values):
            raise ValueError("Invalid value for --skipchecks. Expecting dash-separated numbers.")
        start_val, end_val = [int(i) for i in values]
        if end_val > 4:
            raise ValueError("Invalid range for --skipchecks. Can't exceed 4.")
        skip_checks.extend(list(range(start_val, end_val + 1)))
    elif args.skipchecks.isdigit():
        check_value = int(args.skipchecks)
        if check_value > 4:
            raise ValueError("Invalid value for --skipchecks. Can't exceed 4.")
        skip_checks.append(check_value)
    else:
        raise ValueError("Invalid value for --skipchecks.")

# Remove duplicates from skip_checks
skip_checks = list(set(skip_checks))

while True:
    # Reset flags at the start of each loop iteration
    write_data = False

    first_pointer, second_pointer, third_pointer = find_pointers(start_index, content)

    # Break if no more pointers can be found
    if third_pointer == -1:
        break

    # Update start index for the next iteration
    start_index = first_pointer + 1

    # Check first two bytes at third pointer
    value1, value2 = struct.unpack('<BB', content[third_pointer:third_pointer+2])

    # Always unpack the value for Check 2 from third pointer + 0x4
    value = struct.unpack('<B', content[third_pointer+0x4:third_pointer+0x4+1])[0]

    # Logic for checks when --roads is NOT provided
    if not args.roads:
        # Define checks as lambdas with an associated check number.
        checks = [
            (lambda: check_1(value1, value2), 1),
            (lambda: check_2(value,), 2),
            (lambda: check_4(content[third_pointer+0x38:third_pointer+0x38+0x18]), 4)
        ]
        all_checks_passed = True
        for func, check_num in checks:
            if check_num not in skip_checks and not func():
                all_checks_passed = False
                break
        if all_checks_passed:
            write_data = not force_no_write

    # Logic for checks when --roads is provided
    else:
        float_health_check = struct.unpack('<f', content[third_pointer+0x2C:third_pointer+0x2C+4])[0]
        # Extract the 24-byte region (6 segments of 4 bytes) starting at third pointer + 0x38.
        region_roads = content[third_pointer+0x38:third_pointer+0x38+0x18]
        write_data = should_write_data_for_roads(skip_checks, value, float_health_check, region_roads)
        write_data = write_data and (not force_no_write)
    
    # After determining write_data and before acting on it:
    if not write_data and args.debug:
        skipped_edit_count += 1

    if write_data or args.debug:
        # Print pointer information when writes are done or when debug flag is enabled.
        write_log(f'First pointer found at address: 0x{first_pointer:X}', args.logs)
        write_log(f'Second pointer found at address: 0x{second_pointer:X}', args.logs)
        write_log(f'Third pointer is at address: 0x{third_pointer:X}', args.logs)

    if write_data:
        # Increment edit count
        edit_count += 1
        count += 1

        # Write value at third pointer + 0x4
        content[third_pointer+0x4:third_pointer+0x4+1] = struct.pack('<B', struct_lvl)
        # Write float value at third pointer + 0x2C
        content[third_pointer+0x2C:third_pointer+0x2C+4] = struct.pack('<f', float_health)
        # Write struct_upgrade six times at third pointer + 0x38, each 4 bytes apart
        for i in range(6):
            content[third_pointer+0x38+i*4:third_pointer+0x38+i*4+4] = struct.pack('<I', struct_upgrade)

        # Print information about the successful edit.
        write_log(f'Value {struct_lvl} written at third pointer + 0x4', args.logs)
        write_log(f'Float value {float_health} written at third pointer + 0x2C', args.logs)
        write_log(f'Value {struct_upgrade} written six times at third pointer + 0x38, each 4 bytes apart', args.logs)
    
    if args.debug:
        if not args.roads:
            write_log(f'- Debug Check 1: 1st Two Values at third pointer are: {value1}, {value2}', args.logs)
        # Debug Check 2 always prints regardless of mode.
        write_log(f'- Debug Check 2: 3rd Value at third pointer + 0x04 is {value}.', args.logs)
        if not args.roads:
            # Evaluate the 24-byte region using revised check_4 with allow_all_zero True.
            region = content[third_pointer+0x38:third_pointer+0x38+0x18]
            if check_4(region):
                values_4 = [struct.unpack('<I', region[i*4:(i+1)*4])[0] for i in range(6)]
                write_log(f'- Debug Check 4: Values at third pointer + 0x38 are: {", ".join(map(str, values_4))}', args.logs)
            else:
                hex_str = " ".join(f"{b:02X}" for b in region)
                write_log(f'- Debug Check 4: Values at third pointer + 0x38 failed: [{hex_str}]', args.logs)
        if args.roads:
            write_log(f'- Debug Check 3: float value at third pointer + 0x2C is: {float_health_check}', args.logs)
            region_roads = content[third_pointer+0x38:third_pointer+0x38+0x18]
            if check_4(region_roads, allow_all_zero=False):
                values_roads = [struct.unpack('<I', region_roads[i*4:(i+1)*4])[0] for i in range(6)]
                write_log(f'- Debug Check 4: Values at third pointer + 0x38 are: {", ".join(map(str, values_roads))}', args.logs)
            else:
                hex_str = " ".join(f"{b:02X}" for b in region_roads)
                write_log(f'- Debug Check 4: Values at third pointer + 0x38 failed: [{hex_str}]', args.logs)
            
    if write_data or args.debug:
        # Print a separator based on whether an edit was made.
        if write_data:
            write_log(Fore.YELLOW + '-------------------- SUCCESS -------------------', args.logs)
        else:
            write_log(Fore.RED + '-------------------- SKIPPED -------------------', args.logs)

    # Stop if the count reached the limit specified by --times.
    if args.times is not None and count >= args.times:
        break

write_log(f'Total edits made: {Fore.YELLOW}{edit_count}{Fore.RESET}', args.logs)

# Print skipped edits if --debug was provided.
if args.debug:
    write_log(f'Total skipped edits: {Fore.RED}{skipped_edit_count}{Fore.RESET}', args.logs)

# Print skipped checks if --skipchecks was provided.
if args.skipchecks:
    write_log(f'Checks skipped: {Fore.BLUE}{args.skipchecks}{Fore.RESET}', args.logs)

write_log('---------------------------------------', args.logs)

if edit_count > 0:
    # Save the modified content to the file.
    with open(args.file, 'wb') as f:
        f.write(content)
    write_log('File saved successfully', args.logs)

    # If --debug2 is passed, restore the backup file.
    if args.debug2 and args.bak:
        backup_file_path = args.file + '.bak'
        with open(backup_file_path, 'rb') as f_bak:
            backup_content = f_bak.read()
        with open(args.file, 'wb') as f:
            f.write(backup_content)
        write_log('File restored successfully due to debug2 mode', args.logs)
else:
    write_log('No edits made. File not saved.', args.logs)

# Close the log file if it was opened.
if log_file:
    log_file.close()
