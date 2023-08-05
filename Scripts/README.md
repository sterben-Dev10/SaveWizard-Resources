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

`--skipchecks` skips certain checks within the script that validate if it should write where it needs to.

> `python3 DS_Structures.py --skipchecks all checkpoint.dat`  
> **WARNING:** only use this if you edited like the level of the building higher then 3
> this is only ment for debug cases.

**Note:** if the game softlocks on you & unable to contribute to the bridge construction In order No. 10

Edit the following varribles to following in the script:
```
struct_lvl = 1 
float_val = 10.0 
struct_val = 10
```

which should erase any upgrades, set health to 10 & set the bridge back to Lvl 1