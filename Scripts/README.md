## Scripts

A collection of scripts that edit save files rather than using quickcode.

[Death Stranding](Death%20Stranding)  

> Repairs & Upgrades all Structures on the map, excluding safehouses  
> Maxes out your owned safehouses resources

[pyconvert](pyconvert.py)  

> A simple script to convert Dec to Hex & vice versa.  
> Supports Floats as well, bring up the help menu to view all options `--help`

**Usage:**  
`python3 pyconvert.py 999 -ui32` will output the hexadecimal value of 999 in 32bit integer (4 bytes) Big Endian by default,  
Apply `--little` if you want it in Little Endian.  
`python3 pyconvert.py 0x000003E7 -ui32` will output the decimal value. All hexadecimal values must start with `0x` when converting back to decimal.  
`python3 pyconvet.py C39E943977124BE8 -swp` will swap endianness of the inputed hexadecimal input.

[Apollo-lib Compiler macOS](apollo-lib-macos.sh)

> A script for macOS to build and compile Apollo CLI tools
> will handle the Installation of Xcode dev tools & hombrew.
> as well as any other necessary dependcies.

**Usage**  
open a temrinal window type in `chmod 755` then a space, then drag the script on the window & hit enter.  
now right click on the `apollo-lib-macos.sh` script & open with Terminal.

[MediaFire](MediaFire.py)  

> A Script that bypasse's the blocked/dangerous links that you cannot download on mediafire.  
> you must be logged in with mediafire 1st & have a dummy file uploaded to your own mediafire drive,  
> use that dummy file to set the varrible for `Link1`.

**Usage:**  
`python3 MediaFire.py` it will then ask you to enter the link you are trying to access,  
enter the link & hit enter, it should give you an example link like this `mediafire.com/?i0w4rh8twcwfirv,znig9z0dsbg6x7k`  
as the output.

<a href=".images/Step1.png" target="_blank">
    <img src=".images/Step1.png"" alt="Alt Text" width="300" style="display: inline-block; margin-right: 10px;"/>
</a> <br><a href=".images/Step2.png" target="_blank">
    <img src=".images/Step2.png"" alt="Alt Text" width="300" style="display: inline-block; margin-right: 10px;"/>
</a>

you should be able to see one of your files & the block file, then you just right click on the file that is blocked (red tint), click on "Copy File To" & place it in your own drive, from there you can download the blocked file as you own it now.
