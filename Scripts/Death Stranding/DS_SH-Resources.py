#!/usr/bin/env python3

# Death Stranding Max Player Owned Safehouse Resources - PS4 Saves Only
# OpenAI Generated Script, Research Done By XxUnkn0wnxX
# Script Ver 1.04

"""
DS Safe House Max Resources
-------------------------------------------------------------------

This script uses a pointer chain to locate the first writable block:
  • 1st Pointer (expected pattern): D598821705F1C4895529   (10 bytes)
  • 2nd Pointer (expected pattern): 1401000000000000         (8 bytes)
  • 3rd Pointer (expected pattern): 2003000028               (5 bytes)

It then performs tests:
  - 3rd Pointer + 0xC: the 2 bytes must not be 00 00.
  - 3rd Pointer + 0x10: the 1 byte must equal 04.
  - 3rd Pointer + 0x14: the 1 byte must equal 04.
  - 3rd Pointer + 0xA8: the 2 bytes must not be 00 00.
If these pass, the writable block is assumed to begin at (3rd Pointer + 0x48).

The writable area is divided into segments spaced exactly 0x6C (108) bytes apart.
Within each segment the first 44 bytes (the “data region”) hold 6 write‐slots:
  • For groups 0–4: each group is a 4‐byte value followed by 4 bytes (separator) that must be 00 00 00 00.
  • For group 5 (offset 40–44): a 4‐byte value (with no following separator).
A candidate segment is valid if its 44‐byte region is either completely blank or matches the expected layout.

The script counts how many valid segments (N) are available and then generates one consolidated
patch group. The header line is:

    95000000 <FIRST_PTR>

where <FIRST_PTR> is the pointer (in 8‑digit Big Endian) of the first write in the first segment.
Then for each of the 6 write–slots (at offsets 0, 8, 16, 24, 32, and 40) two lines are output:
  • Write line: address = 4A000000 + (i * 8) and value = safehouse_resources (converted to 4‐byte Big Endian).
  • Repeater line: "4{repeat_count:03X}0098 00000000" where repeat_count = N.
The next segment’s pointer is calculated as:
    next_segment_ptr = (current_segment_ptr + DATA_REGION_SIZE) + 0x6C
which is DATA_REGION_SIZE (0x2C, 44 bytes) plus 0x6C (108 bytes) = 152 bytes (0x98) from the current segment’s start.

The patch file is then written as “DS_SHResources.savepatch” when --debug is passed, for manual inspection and the patcher tool is executed with:
    {APOLLO_PATCHER} {patch_lines} 1 <savefile>
APOLLO_PATCHER must be set to a full path if desired; if left empty the script will look in the
current folder for the "patcher" binary. If --debug is not passed the temporary patch file is deleted.

Additionally, when --debug is passed the script outputs each candidate region’s hex data (the 44‐byte region)
and whether it is valid or not, as well as detailed test output for the 3rd Pointer offsets.
Additionally, if the --logs option is used, the log file is written in plain text (ANSI color codes stripped).
If the --bak flag is passed, a backup of the save file (filename + ".bak") is created before any edits.
  
Note: This script does not source your shell rc file.
"""

import os, sys, struct, argparse, signal, subprocess, re, shlex
from colorama import init, Fore, Style
init(autoreset=True)

def strip_ansi(text):
    return re.sub(r'\x1b\[[0-9;]*m', '', text)

def write_log(message, log_file=None):
    # Print colored message to terminal and plain text to file.
    print(message)
    if log_file:
        with open(log_file, "a") as f:
            f.write(strip_ansi(message) + "\n")

# User-set variable for the patcher tool. By default, leave empty to force local search.
APOLLO_PATCHER = os.environ.get('APOLLO_PATCHER', '')

# Get safehouse_resources (default 999999999)
safehouse_resources = int(os.environ.get('safehouse_resources', 999999999))

# Clamp to valid 32-bit unsigned max (0xFFFFFFFF = 4294967295)
if safehouse_resources < 0:
    write_log(Fore.YELLOW + f"safehouse_resources value {safehouse_resources} is negative. Clamped to 0.", None)
    safehouse_resources = 0
elif safehouse_resources > 0xFFFFFFFF:
    write_log(Fore.YELLOW + f"safehouse_resources value {safehouse_resources} exceeds 32-bit max. Clamped to 4294967295.", None)
    safehouse_resources = 0xFFFFFFFF

# Constants:
DATA_REGION_SIZE = 0x2C      # 44 bytes: data region per segment.
SEGMENT_SPACING = 0x6C       # 108 bytes gap.
NEXT_SEGMENT_DELTA = DATA_REGION_SIZE + SEGMENT_SPACING  # 44 + 108 = 152 bytes (0x98)

# Define expected pointer patterns (all little-endian)
# We'll output these as expected in the log.
EXPECTED_PTR1 = "D598821705F1C4895529"
EXPECTED_PTR2 = "1401000000000000"
EXPECTED_PTR3 = "2003000028"

# These are used to find the pointers in the file.
PTR1 = bytes.fromhex(EXPECTED_PTR1)   # 10 bytes
PTR2 = bytes.fromhex(EXPECTED_PTR2)   # 8 bytes
PTR3 = bytes.fromhex(EXPECTED_PTR3)   # 5 bytes

def signal_handler(sig, frame):
    write_log(Fore.RED + "SIGINT received. Exiting.")
    sys.exit(0)
signal.signal(signal.SIGINT, signal_handler)

def valid_data_region(region):
    """
    Return True if the 44-byte region is valid for overwriting.
    It is valid if it is completely blank OR if for groups 0–4, each 4-byte value
    (at offset i*8) is followed by exactly 4 bytes of 0's.
    Group 5 (offset 40-44) is not checked.
    """
    if len(region) < DATA_REGION_SIZE:
        return False
    for i in range(5):
        sep = region[i*8+4 : i*8+8]
        if sep != b'\x00'*4:
            return False
    return True

def generate_patch_group(block_ptr, repeat_count):
    """
    Generate a consolidated patch group for a segment starting at block_ptr.
    The first line must be the marker:
         [DS_SHR]
    The second line is the header:
         95000000 <block_ptr in 8-digit Big Endian>
    Then for i = 0 .. 5, output two lines:
         - Write line: address = 4A000000 + (i * 8), value = safehouse_resources converted to a 4-byte Big Endian HEX string.
         - Repeater line: "4{repeat_count:03X}0098 00000000" where repeat_count is the total number of valid segments.
    """
    lines = []
    # First line is the marker
    lines.append("[DS_SHR]")
    # Second line is the header
    header = f"95000000 {format(block_ptr, '08X')}"
    lines.append(header)
    rep_str = f"4{repeat_count:03X}0098"
    for i in range(6):
        addr = 0x4A000000 + (i * 8)
        # Inline conversion of safehouse_resources to 4-byte Big Endian HEX string.
        value_str = safehouse_resources.to_bytes(4, byteorder='big').hex().upper()
        lines.append(f"{format(addr, '08X')} {value_str}")
        lines.append(f"{rep_str} 00000000")
    return lines
    
def run_tests(content, third_pointer, args, log_file=None):
    # Test 1: Check 2 bytes at (3rd Pointer + 0xC) must not be 00 00.
    test1_addr = third_pointer + 0xC
    test1_value = content[test1_addr:test1_addr+2].hex().upper()
    if content[test1_addr:test1_addr+2] == b'\x00\x00':
        write_log(Fore.RED + f"Test1 failed at 3rd Pointer + 0xC (Address: 0x{test1_addr:X}): [{test1_value}]. Exiting.", log_file)
        sys.exit(0)
    else:
        if args.debug:
            write_log(Fore.GREEN + f"Test1 success at 3rd Pointer + 0xC (Address: 0x{test1_addr:X}): [{test1_value}]", log_file)

    # Test 2: Check 1 byte at (3rd Pointer + 0x10) must equal 04.
    test2_addr = third_pointer + 0x10
    test2_value = format(content[test2_addr], '02X')
    if content[test2_addr] != 0x04:
        write_log(Fore.RED + f"Test2 failed at 3rd Pointer + 0x10 (Address: 0x{test2_addr:X}): [{test2_value}]. Exiting.", log_file)
        sys.exit(0)
    else:
        if args.debug:
            write_log(Fore.GREEN + f"Test2 success at 3rd Pointer + 0x10 (Address: 0x{test2_addr:X}): [{test2_value}]", log_file)

    # Test 3: Check 1 byte at (3rd Pointer + 0x14) must equal 04.
    test3_addr = third_pointer + 0x14
    test3_value = format(content[test3_addr], '02X')
    if content[test3_addr] != 0x04:
        write_log(Fore.RED + f"Test3 failed at 3rd Pointer + 0x14 (Address: 0x{test3_addr:X}): [{test3_value}]. Exiting.", log_file)
        sys.exit(0)
    else:
        if args.debug:
            write_log(Fore.GREEN + f"Test3 success at 3rd Pointer + 0x14 (Address: 0x{test3_addr:X}): [{test3_value}]", log_file)

    # Test 4: Check 2 bytes at (3rd Pointer + 0xA8) must not be 00 00.
    test4_addr = third_pointer + 0xA8
    test4_value = content[test4_addr:test4_addr+2].hex().upper()
    if content[test4_addr:test4_addr+2] == b'\x00\x00':
        write_log(Fore.RED + f"Test4 failed at 3rd Pointer + 0xA8 (Address: 0x{test4_addr:X}): [{test4_value}]. Exiting.", log_file)
        sys.exit(0)
    else:
        if args.debug:
            write_log(Fore.GREEN + f"Test4 success at 3rd Pointer + 0xA8 (Address: 0x{test4_addr:X}): [{test4_value}]", log_file)
            
    # Print overall success only when --debug is NOT passed.
    if not args.debug:
        write_log(Fore.GREEN + "All tests passed.", log_file)
        
def main():
    parser = argparse.ArgumentParser(description="DS Safe House Max Resources")
    parser.add_argument("file", help="Path to the file to process.")
    parser.add_argument("--debug", action="store_true", help="Keep temporary patch file and output candidate regions.")
    parser.add_argument("--logs", "-log", type=str, help="Specify a file to write logs to.")
    parser.add_argument("--bak", action="store_true", help="Create a backup of the original file.")
    args = parser.parse_args()

    # Determine patcher binary path.
    if APOLLO_PATCHER:
        patcher_path = os.path.expandvars(APOLLO_PATCHER)
        if not (os.path.isfile(patcher_path) and os.access(patcher_path, os.X_OK)):
            write_log(Fore.YELLOW + f"Patcher binary specified in APOLLO_PATCHER not found or not executable: {patcher_path}", args.logs)
            sys.exit(1)
    else:
        # Look in the script's directory.
        script_dir = os.path.dirname(os.path.abspath(__file__))
        local_patcher = os.path.join(script_dir, "patcher")
        if os.path.isfile(local_patcher) and os.access(local_patcher, os.X_OK):
            patcher_path = local_patcher
            write_log(Fore.CYAN + f"Patcher binary found in script directory: {patcher_path}", args.logs)
        else:
            local_patcher_exe = local_patcher + ".exe"
            if os.path.isfile(local_patcher_exe) and os.access(local_patcher_exe, os.X_OK):
                patcher_path = local_patcher_exe
                write_log(Fore.CYAN + f"Patcher binary found in script directory: {patcher_path}", args.logs)
            else:
                write_log(Fore.YELLOW + "Patcher binary not found in script directory and APOLLO_PATCHER is not set.", args.logs)
                write_log(Fore.YELLOW + "Please place the 'patcher' binary (or 'patcher.exe' on Windows) in the same folder as this script or set APOLLO_PATCHER to its full path.", args.logs)
                sys.exit(1)

    patch_filename = "DS_SHResources.savepatch"
    # Only handle existing patch file when --debug is passed.
    if args.debug and os.path.exists(patch_filename):
        try:
            os.remove(patch_filename)
            write_log(Fore.CYAN + f"Existing patch file '{patch_filename}' deleted.", args.logs)
        except Exception as e:
            write_log(Fore.YELLOW + f"Could not delete existing patch file: {e}", args.logs)

    # Create backup if --bak is specified.
    if args.bak:
        backup_file = args.file + ".bak"
        try:
            with open(args.file, "rb") as src, open(backup_file, "wb") as dst:
                dst.write(src.read())
            write_log(Fore.WHITE + f"Backup created: {backup_file}", args.logs)
        except Exception as e:
            write_log(Fore.YELLOW + f"Could not create backup: {e}", args.logs)
            sys.exit(1)

    with open(args.file, "rb") as f:
        content = bytearray(f.read())
    original_content = content[:]

    # --- Pointer chain to locate first writable block ---
    start_index = 0
    first_pointer = content.find(PTR1, start_index)
    if first_pointer == -1:
        write_log(Fore.YELLOW + "1st Pointer not found. Exiting.", args.logs)
        sys.exit(0)
    second_pointer = content.find(PTR2, first_pointer)
    if second_pointer == -1:
        write_log(Fore.YELLOW + "2nd Pointer not found after 1st Pointer. Exiting.", args.logs)
        sys.exit(0)
    third_pointer = content.find(PTR3, second_pointer)
    if third_pointer == -1:
        write_log(Fore.YELLOW + "3rd Pointer not found after 2nd Pointer. Exiting.", args.logs)
        sys.exit(0)
    if args.debug:
        write_log(Fore.CYAN + f"1st Pointer found at address: 0x{first_pointer:X} [{PTR1.hex().upper()}]", args.logs)
        write_log(Fore.CYAN + f"2nd Pointer found at address: 0x{second_pointer:X} [{PTR2.hex().upper()}]", args.logs)
        write_log(Fore.CYAN + f"3rd Pointer found at address: 0x{third_pointer:X} [{PTR3.hex().upper()}]", args.logs)

    # --- Run tests at 3rd Pointer offsets ---
    run_tests(content, third_pointer, args, args.logs)

    # The first writable block is assumed to begin at (3rd Pointer + 0x48)
    first_block_ptr = third_pointer + 0x48
    if first_block_ptr + DATA_REGION_SIZE > len(content):
        write_log(Fore.YELLOW + "Not enough bytes for first data region. Exiting.", args.logs)
        sys.exit(0)
    candidate = content[first_block_ptr:first_block_ptr+DATA_REGION_SIZE]
    if not (candidate == b'\x00'*DATA_REGION_SIZE or valid_data_region(candidate)):
        write_log(Fore.YELLOW + f"First block at 0x{first_block_ptr:X} is not valid. Exiting.", args.logs)
        sys.exit(0)

    # --- Count valid segments ---
    count = 0
    ptr = first_block_ptr
    while ptr + DATA_REGION_SIZE <= len(content):
        candidate = content[ptr:ptr+DATA_REGION_SIZE]
        status = "VALID" if (candidate == b'\x00'*DATA_REGION_SIZE or valid_data_region(candidate)) else "INVALID"
        if args.debug:
            write_log(Fore.YELLOW + f"Candidate region at 0x{ptr:08X}: {candidate.hex().upper()} - {status}", args.logs)
        if not (candidate == b'\x00'*DATA_REGION_SIZE or valid_data_region(candidate)):
            break
        count += 1
        ptr += NEXT_SEGMENT_DELTA
    if args.debug:
        write_log(Fore.CYAN + f"Total valid segments found: {count}", args.logs)
    if count == 0:
        write_log(Fore.YELLOW + "No valid segments found. Exiting.", args.logs)
        sys.exit(0)
        
    # --- Validate repeat count (must fit in 3 hex digits: 0x000–0xFFF) ---
    if count > 0xFFF:
        write_log(Fore.RED + f"Too many safe houses detected ({count}). Maximum supported is 4095 (0xFFF). Exiting.", args.logs)
        sys.exit(1)

    # --- Generate consolidated patch group ---
    patch_lines = generate_patch_group(first_block_ptr, count)
    write_log(Fore.YELLOW + f"Total patch groups (repeat count) generated: {count}", args.logs)

    # Write patch file only when --debug is passed.
    if args.debug:
        with open(patch_filename, "w") as f:
            f.write(":*\n\n")  # [DS_SHR] removed because it's now added by the patcher function
            for line in patch_lines:
                f.write(line + "\n")
        write_log(Fore.WHITE + f"Patch file '{patch_filename}' created.", args.logs)

    # Build and run the patcher command using in-memory patch content (safe, cross-platform).
    patch_str = "\n".join(patch_lines)
    argv = [patcher_path, patch_str, "1", args.file]

    if args.debug:
        if os.name == "nt":
            from subprocess import list2cmdline
            preview = list2cmdline(argv)  # Windows-style preview
        else:
            preview = " ".join(shlex.quote(a) for a in argv)  # POSIX-style preview
        write_log(Fore.WHITE + f"Executing: {preview}", args.logs)

    # Run and capture output for logging
    result = subprocess.run(
        argv,
        shell=False,
        capture_output=True,
        text=True
    )

    # Append patcher stdout/stderr to logs (no formatting applied)
    if result.stdout:
        out = result.stdout.rstrip("\n")
        if out:
            write_log(out, args.logs)

    if result.stderr:
        err = result.stderr.rstrip("\n")
        if err:
            write_log(err, args.logs)

    if result.returncode != 0:
        write_log(Fore.RED + f"Patcher tool returned error code {result.returncode}.", args.logs)
    else:
        write_log(Fore.GREEN + "Patcher tool executed successfully.", args.logs)

if __name__ == "__main__":
    main()
