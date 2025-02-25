#!/usr/bin/env python3

# Death Stranding Max Player Owned Safehouse Resources - PS4 Saves Only
# OpenAI Generated Script, Research Done By XxUnkn0wnxX
# Script Ver 1.01

"""
DS Safe House Max Resources
-------------------------------------------------------------------

This script uses a pointer chain to locate the first writable block:
  • PATTERN1: D598821705F1C4895529   (10 bytes)
  • PATTERN2: 1401000000000000         (8 bytes)
  • PATTERN3: 2003000028               (5 bytes)

It then performs tests:
  - Offset +0xC: the 2 bytes must not be 00 00.
  - Offset +0x10: the 1 byte must equal 04.
  - Offset +0x14: the 1 byte must equal 04.
  - Offset +0xA8: the 2 bytes must not be 00 00.
If these pass, the writable block is assumed to begin at (p3 + 0x48).

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

The patch file is then written as “DS_SHResources.savepatch” and the patcher tool is executed with:
    {APOLLO_PATCHER} DS_SHResources.savepatch 1 <savefile>
APOLLO_PATCHER must be set to a full path if desired; if left empty the script will look in the
current folder for the "patcher" binary. If --debug is not passed the temporary patch file is deleted.

Additionally, when --debug is passed the script outputs each candidate region’s hex data (the 44‑byte region)
and whether it is valid or not.

Additionally, if the --logs option is used, the log file is written in plain text (ANSI color codes stripped).
If the --bak flag is passed, a backup of the save file (filename + ".bak") is created before any edits.
  
Note: This script does not source your shell rc file.
"""

import os, sys, struct, argparse, signal, subprocess, re
from colorama import init, Fore, Style
init(autoreset=True)

# User-set variable for the patcher tool. By default, leave empty to force local search.
APOLLO_PATCHER = os.environ.get('APOLLO_PATCHER', '')

# Get safehouse_resources (default 999999999) and convert to a 4-byte Big Endian HEX string.
safehouse_resources = int(os.environ.get('safehouse_resources', 999999999))
safe_hex = safehouse_resources.to_bytes(4, byteorder='big').hex().upper()

# Constants:
DATA_REGION_SIZE = 0x2C     # 44 bytes: data region per segment.
SEGMENT_SPACING = 0x6C      # 108 bytes gap.
NEXT_SEGMENT_DELTA = DATA_REGION_SIZE + SEGMENT_SPACING  # 44 + 108 = 152 bytes (0x98)

# Define HEX patterns (all little-endian)
PATTERN1 = bytes.fromhex("D598821705F1C4895529")   # 10 bytes
PATTERN2 = bytes.fromhex("1401000000000000")         # 8 bytes
PATTERN3 = bytes.fromhex("2003000028")               # 5 bytes

def signal_handler(sig, frame):
    write_log(Fore.RED + "SIGINT received. Exiting.")
    sys.exit(0)
signal.signal(signal.SIGINT, signal_handler)

def strip_ansi(text):
    return re.sub(r'\x1b\[[0-9;]*m', '', text)

def write_log(message, log_file=None):
    # Print the colored message to the terminal
    print(message)
    # If logging to a file, strip the ANSI escape sequences so the file is plain text.
    if log_file:
        with open(log_file, "a") as f:
            f.write(strip_ansi(message) + "\n")

def valid_data_region(region):
    """
    Return True if the 44-byte region is valid for overwriting.
    It is valid if it is completely blank OR if for groups 0–4, each 4-byte value (at offset i*8)
    is followed by exactly 4 bytes of 0's.
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
    The header line is:
         95000000 <block_ptr in 8-digit Big Endian>
    Then for i = 0 .. 5, output two lines:
         Write line: address = 4A000000 + (i*8), value = safe_hex.
         Repeater line: "4{repeat_count:03X}0098 00000000" where repeat_count is the total number of valid segments.
    """
    lines = []
    header = f"95000000 {format(block_ptr, '08X')}"
    lines.append(header)
    rep_str = f"4{repeat_count:03X}0098"
    for i in range(6):
        addr = 0x4A000000 + (i * 8)
        lines.append(f"{format(addr, '08X')} {safe_hex}")
        lines.append(f"{rep_str} 00000000")
    return lines

def main():
    parser = argparse.ArgumentParser(description="DS Safe House Max Resources")
    parser.add_argument("file", help="Path to the save file")
    parser.add_argument("--debug", action="store_true", help="Keep temporary patch file and output candidate regions")
    parser.add_argument("--logs", help="Log file path")
    parser.add_argument("--bak", action="store_true", help="Create a backup of the save file before editing")
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
    if os.path.exists(patch_filename) and not args.debug:
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
    p1 = content.find(PATTERN1, start_index)
    if p1 == -1:
        write_log(Fore.YELLOW + "PATTERN1 not found. Exiting.", args.logs)
        sys.exit(0)
    p2 = content.find(PATTERN2, p1)
    if p2 == -1:
        write_log(Fore.YELLOW + "PATTERN2 not found after PATTERN1. Exiting.", args.logs)
        sys.exit(0)
    p3 = content.find(PATTERN3, p2)
    if p3 == -1:
        write_log(Fore.YELLOW + "PATTERN3 not found after PATTERN2. Exiting.", args.logs)
        sys.exit(0)
    if args.debug:
        write_log(Fore.CYAN + f"PATTERN1 found at: 0x{p1:X}", args.logs)
        write_log(Fore.CYAN + f"PATTERN2 found at: 0x{p2:X}", args.logs)
        write_log(Fore.CYAN + f"PATTERN3 found at: 0x{p3:X}", args.logs)

    # --- Run tests at p3 ---
    if content[p3+0xC : p3+0xC+2] == b'\x00\x00':
        write_log(Fore.RED + f"Test1 failed at 0x{p3+0xC:X}. Exiting.", args.logs)
        sys.exit(0)
    if content[p3+0x10] != 0x04:
        write_log(Fore.RED + f"Test2 failed at 0x{p3+0x10:X}. Exiting.", args.logs)
        sys.exit(0)
    if content[p3+0x14] != 0x04:
        write_log(Fore.RED + f"Test3 failed at 0x{p3+0x14:X}. Exiting.", args.logs)
        sys.exit(0)
    if content[p3+0xA8 : p3+0xA8+2] == b'\x00\x00':
        write_log(Fore.RED + f"Test4 failed at 0x{p3+0xA8:X}. Exiting.", args.logs)
        sys.exit(0)
    if args.debug:
        write_log(Fore.GREEN + "All tests passed.", args.logs)

    # The first writable block is assumed to begin at (p3 + 0x48)
    first_block_ptr = p3 + 0x48
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

    # --- Generate consolidated patch group ---
    patch_lines = generate_patch_group(first_block_ptr, count)
    write_log(Fore.YELLOW + f"Total patch groups (repeat count) generated: {count}", args.logs)

    # Write patch file.
    with open(patch_filename, "w") as f:
        f.write(":*\n\n[DS_SHR]\n")
        for line in patch_lines:
            f.write(line + "\n")
    write_log(Fore.WHITE + f"Patch file '{patch_filename}' created.", args.logs)

    # Build and run the patcher command.
    cmd = f'"{patcher_path}" {patch_filename} 1 "{args.file}"'
    if args.debug:
        write_log(Fore.WHITE + f"Executing command: {cmd}", args.logs)
    result = subprocess.run(cmd, shell=True)
    if result.returncode != 0:
        write_log(Fore.RED + f"Patcher tool returned error code {result.returncode}.", args.logs)
    else:
        write_log(Fore.GREEN + "Patcher tool executed successfully.", args.logs)

    if not args.debug:
        try:
            os.remove(patch_filename)
            write_log(Fore.WHITE + f"Temporary patch file '{patch_filename}' deleted.", args.logs)
        except Exception as e:
            write_log(Fore.YELLOW + f"Could not delete temporary patch file: {e}", args.logs)

if __name__ == "__main__":
    main()
