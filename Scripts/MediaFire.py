#!/usr/bin/env python3

import signal
import sys

# Global variable for Link 1 - Set This To a DL Link You own in your mediafire folder
# Example:
# Link1 = "https://www.mediafire.com/view/i0w4rh8twcwfirv/Test.png/file"
Link1 = "https://www.mediafire.com/file/b1wt1l2hrb0ey3e/Test.zip/file"

# Immediately check if Link1 is set
if not Link1:
    print("Please set the 'Link1' variable in the script first.")
    sys.exit(1)

# Function to handle SIGINT (CTRL+C)
def signal_handler(sig, frame):
    print('\nYou pressed CTRL+C! Exiting gracefully.')
    sys.exit(0)

# Register the signal handler for SIGINT
signal.signal(signal.SIGINT, signal_handler)

# Function to extract the unique ID from a Mediafire link
def extract_id(link):
    # Attempt to extract the ID from the URL path
    parts = link.split('/')
    mediafire_index = next((i for i, part in enumerate(parts) if "mediafire.com" in part), None)
    if mediafire_index is not None and len(parts) > mediafire_index + 2:
        return parts[mediafire_index + 2]

    # If the path method fails, attempt to extract the ID using the 'quickkey' parameter
    if 'quickkey=' in link:
        start = link.find('quickkey=') + len('quickkey=')
        end = link.find('&', start)
        return link[start:end if end != -1 else None]

    return None

# Function to build the final link with the two IDs
def build_link(id1, id2):
    return f"mediafire.com/?{id1},{id2}"

# Extract the ID from the preconfigured Link1
id1 = extract_id(Link1)

try:
    # Prompt the user to enter Link 2 during runtime
    Link2 = input("Enter Your Blocked Mediafire Link: ").strip()
    # Check if Link2 contains "mediafire.com/"
    if not Link2 or "mediafire.com/" not in Link2:
        raise ValueError("Invalid or no link provided.")
except (EOFError, ValueError) as e:
    # Handle case where user inputs an EOF character or an invalid link
    print(f'\nError: {str(e)} Exiting.')
    sys.exit(1)

# Extract the ID from Link 2
id2 = extract_id(Link2)
if not id2:
    print('\nError: Could not extract ID from Link 2. Exiting.')
    sys.exit(1)
    
# Adding line break before constructing the final link
print("\n")
print("Your Link:")

# Build the final link using the IDs from Link 1 and Link 2
final_link = build_link(id1, id2)

# Print the final link
print(final_link)
