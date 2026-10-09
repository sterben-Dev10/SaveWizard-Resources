<a id="death-stranding-scripts"></a>

# 🎮 Death Stranding Scripts

**Scope: PS4 saves only.** These scripts edit save files; keep an untouched backup of the original save.

[Setup](#python-setup) · [Structure editor](#ds_structurespy) · [Safehouse resources](#ds_sh-resourcespy)

## Python setup

From the repository root, create and activate a virtual environment, then install the shared dependencies before running either script.

macOS/Linux:

```sh
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
```

Windows PowerShell:

```powershell
py -m venv .venv
.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
```

Change into the script directory:

```sh
cd "Scripts/Death Stranding"
```

Reactivate `.venv` in each new shell. The examples below assume the virtual environment is active and the working directory is `Scripts/Death Stranding`.

## `DS_Structures.py`

Repairs and upgrades structures to the configured values. Safehouses are excluded.

```sh
python DS_Structures.py checkpoint.dat
```

### Options

| Option | Behavior | Example |
| --- | --- | --- |
| `--help` | Show the help menu. | `python DS_Structures.py --help` |
| `--bak` | Create a backup of the file (`checkpoint.dat.bak`). | `python DS_Structures.py checkpoint.dat --bak` |
| `--times` | Set how many edits to make. For example, `30` makes the first 30 edits, then stops. | `python DS_Structures.py checkpoint.dat --times 30` |
| `--debug` | Show debug information and skipped edits. | `python DS_Structures.py checkpoint.dat --debug` |
| `--skipchecks` | Skip selected validation checks. Accepts `1`, `2`, `3`, `4`, `all`, or a range such as `1-2`. | `python DS_Structures.py checkpoint.dat --skipchecks all` |
| `--debug2` | Make the edits, then restore the file from the backup created for this run. | `python DS_Structures.py checkpoint.dat --debug2` |
| `--logs` | Write logs to the specified file. | `python DS_Structures.py checkpoint.dat --logs log1.txt` |
| `--roads` | Attempt to include roads and miscellaneous structures missed by the main pass. | `python DS_Structures.py checkpoint.dat --roads` |

`--skipchecks` is intended for debugging. Skipping checks can corrupt the save; use it only if you understand the risk.

`--debug2` is not a no-write dry run. It creates a backup, writes the edited file, and then restores the file from that backup. The script needs to complete the restore for the original contents to be back in place.

> **Warning — experimental roads mode:** `--roads` runs separately and does not include the same changes as the main script. It can cause game crashes, save corruption, or softlocks, including missing interaction buttons at delivery terminals. It may delete safehouses. Keep a separate save backup before trying it.

### Order No. 10 recovery values

If the game softlocks and you cannot contribute to bridge construction in Order No. 10, the original guidance was to use these values to set structure level 1, health 10, and upgrades 10. Set them near the top of the script:

```python
struct_lvl = int(os.environ.get('struct_lvl', 1))
float_health = float(os.environ.get('float_health', 10.0))
struct_upgrade = int(os.environ.get('struct_upgrade', 10))
```

### Custom values

Edit the variables near the top of the script or set them in the shell. `struct_lvl` must be between `0` and `5` inclusive.

macOS/Linux:

```sh
export struct_upgrade=3
export float_health=9999999.0
export struct_lvl=5
```

Windows PowerShell:

```powershell
$env:struct_upgrade = "3"
$env:float_health = "9999999.0"
$env:struct_lvl = "5"
```

## `DS_SH-Resources.py`

Maxes out resources in **your owned safehouses**. This script requires [Apollo CLI Tools](https://github.com/bucanero/apollo-lib/releases). Place the executable `patcher` (or `patcher.exe` on Windows) in the same folder as this script, or set `APOLLO_PATCHER` to its executable path.

```sh
python DS_SH-Resources.py checkpoint.dat
```

### Options

| Option | Behavior | Example |
| --- | --- | --- |
| `--help` | Show the help menu. | `python DS_SH-Resources.py --help` |
| `--bak` | Create a backup of the file. | `python DS_SH-Resources.py checkpoint.dat --bak` |
| `--debug` | Show debug information. | `python DS_SH-Resources.py checkpoint.dat --debug` |
| `--logs` | Write logs to the specified file. | `python DS_SH-Resources.py checkpoint.dat --logs log1.txt` |

### Custom values and Apollo path

The script reads these environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `APOLLO_PATCHER` | Empty | Optional path to the Apollo `patcher` executable. When unset, the script looks beside itself for `patcher` or `patcher.exe`. |
| `safehouse_resources` | `999999999` | Resource value to write; values are clamped to the unsigned 32-bit range. |

macOS/Linux example using the macOS wrapper's default CLI destination. Replace `/path/to/Scripts` with the wrapper's directory, or use your configured `STORE_PATH`:

```sh
export APOLLO_PATCHER="/path/to/Scripts/apollo/Apollo CLI Tools/patcher"
export safehouse_resources=1000
```

Windows PowerShell example:

```powershell
$env:APOLLO_PATCHER = "$env:USERPROFILE\Downloads\tools\patcher.exe"
$env:safehouse_resources = "1000"
```

The configured path must point to an executable file. Environment variables in the path are expanded; a literal `~` is not expanded by the script.
