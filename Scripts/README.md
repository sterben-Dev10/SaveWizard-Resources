## Scripts

A collection of scripts that edit save files rather then using quickcode.

[Death Stranding](Death%20Stranding)  

`DS_Structures.py`  - PS4 Saves Only

> Upgrades & Repairs all strctures to max level.
> Usage: `python3 DS_Structures.py checkpoint.dat`

##### Additinal Options

`--help` brings up the help menu

`--bak` creates a backup of the file

> `python3 DS_Structures.py --bak checkpoint.dat`

`--times` the ammount of times you want the to run through each sequence

> `python3 DS_Structures.py --times 30 checkpoint.dat`
>
> will make the 1st 30 edits then stop.

`--debug` shows debug info as well as skipped edits

> `python3 DS_Structures.py --debug checkpoint.dat`