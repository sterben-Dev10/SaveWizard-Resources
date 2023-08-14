## Death Stranding

`DS_Structures.py`  - PS4 Saves Only

> Following Dependencies Required:  
> `pip3 install colorama`

> Upgrades & Repairs all structures to max level.  
> Usage: `python3 DS_Structures.py checkpoint.dat`

##### Additional Options

`--help` brings up the help menu

`--bak` creates a backup of the file

> `python3 DS_Structures.py checkpoint.dat --bak`

`--times` the amount of times you want to run through each sequence

> `python3 DS_Structures.py checkpoint.dat --times 30`
>
> will make the 1st 30 edits then stop.

`--debug` shows debug info as well as skipped edits

> `python3 DS_Structures.py checkpoint.dat --debug`

`--skipchecks` skips certain checks within the script that validate if it should write where it needs to.

> `python3 DS_Structures.py checkpoint.dat --skipchecks all`  
> **WARNING:** only use this if you know what you are doing & are not afraid of possible save corruption.
> this is only meant for debug cases.

`--debug2` restores the file from backup after writes.

> `python3 DS_Structures.py checkpoint.dat --debug2`  
> this is intended to see what edits would have been made without making them.

`--logs` Specify a file to write logs to.

> `python3 DS_Structures.py checkpoint.dat --logs log1.txt`

`--roads` Attempt to include roads & misc structures missed by the main script.

> `python3 DS_Structures.py checkpoint.dat --roads`  
> this is extremely experimental, expect game crashes or save corruption, softlocks. (missing interaction buttons from delivery terminals)
> this runs separately from the main script & does not include the same changes from the main script.

**Note:** if the game softlocks on you & unable to contribute to the bridge construction In order No. 10

Edit the following variables to following in the script:
```
struct_lvl = 1 
float_val = 10.0 
struct_val = 10
```

which should erase any upgrades, set health to 10 & set the bridge back to Lvl 1
