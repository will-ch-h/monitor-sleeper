# monitor-sleeper

This program puts a second monitor into the standby state when you do not use it. The program
starts the monitor again when you use it.

The program has support for GlazeWM. If a workspace on the second monitor contains a window,
the monitor stays on. Thus you can keep a monitor on for your chat window or your log window,
and the monitor goes to standby when that workspace is empty.

The program is one PowerShell script. It has no dependencies. It sends the standby command
directly to the monitor with the Windows DDC/CI interface.

GlazeWM is not necessary. If you do not use GlazeWM, refer to
["Use without GlazeWM"](#use-without-glazewm).

## Terms

| Term | Explanation |
|---|---|
| DDC/CI | A control channel between the computer and the monitor. It uses the video cable. |
| Standby | The monitor power state with the backlight off. The monitor stays connected. |
| Display index | The number of a monitor in this program. The `-List` command shows it. |
| Workspace | A GlazeWM window group. GlazeWM shows one workspace on each monitor. |

## Before you start

You must have these items:

- Windows 10 or Windows 11
- Windows PowerShell 5.1 (Windows supplies it)
- A monitor with DDC/CI support
- GlazeWM (optional)

Many monitors have DDC/CI in the off state when they are new. If your monitor does not obey
this program, open the monitor menu. Then set DDC/CI to on.

## Installation

1. Download the four files into one folder.
2. Open PowerShell in that folder.
3. Run this command to find the display index:

   ```powershell
   .\monitor-sleeper.ps1 -List
   ```

   The command shows each monitor with its display index, its name, and its size. Example:

   ```
   [0] Primary Display  1920x1080 at (0,0)
   [1] Secondary Display  1920x1080 at (1920,0)
   ```

4. Run this command to find the GlazeWM index of the same monitor:

   ```powershell
   $i=0; (glazewm query monitors|ConvertFrom-Json).data.monitors|%{ "[$i] $($_.hardwareId)"; $i++ }
   ```

   The two lists can have a different sequence. Thus you must do this step.

5. Open `settings.json` in a text editor.
6. Set `displayIndex` to the index from step 3.
7. Set `glazeMonitorIndex` to the index from step 4.
8. Set `idleSeconds` to the time in seconds before the monitor goes into standby.
9. Set `keepAwakeWorkspaces` to the workspaces that must keep the monitor on (when an app is present within the focused workspace).
     **To make this easier, each workspace should be assigned a monitor in the GlazeWM Config file (Ex: I have my even workspaces set to my secondary monitor)**:

   ```json
   "keepAwakeWorkspaces": [2, 4, 6, 8, 10]
   ```

   names are also permitted:

   ```json
   "keepAwakeWorkspaces": ["chat", "mail"]
   ```

11. Save the file.
12. Run this command to examine the settings:

    ```powershell
    .\monitor-sleeper.ps1 -Test
    ```

    The program prints its decisions. It does not change the monitor in this mode. Push
    `Ctrl+C` to stop the program.

13. Run this command to start the program:

    ```powershell
    .\monitor-sleeper.ps1
    ```

## Automatic start

Do these steps to start the program when you log on:

1. Push `Win+R`.
2. Type `shell:startup`. Then push `Enter`.
3. Make a shortcut to `start-hidden.vbs` in the folder that opens.

The `start-hidden.vbs` file starts the program without a console window.

## Use without GlazeWM

The program operates without GlazeWM. The mouse rule and the focus rule do not need GlazeWM.

**Warning:** you must make the workspace list empty. If the list is not empty and GlazeWM is
absent, the program cannot get the workspace data. In that condition the program keeps the
monitor on for safety, and the monitor never goes into standby.

Do these steps:

1. Do the installation steps, but do step 4 and step 7 no more. These two steps are for
   GlazeWM only. Keep the default value of `glazeMonitorIndex`.
2. Set the workspace list to an empty list:

   ```json
   "keepAwakeWorkspaces": []
   ```

3. Save the file.

The program then ignores GlazeWM fully. It does not start the `glazewm` command.

## More than one monitor

The program can control two monitors or more. Each monitor has its own idle time and its own
workspace list. One monitor can go into standby while the other monitor stays on.

To control more than one monitor, use a `displays` list. Each item in the list has the three
monitor settings. Remove `displayIndex`, `glazeMonitorIndex`, and `keepAwakeWorkspaces` from
the top level of the file.

```json
{
  "idleSeconds": 180,
  "pollSeconds": 0.5,
  "glazePollSeconds": 3,
  "offValue": 4,
  "wakeOnFocus": true,
  "wakeOnMouseEnter": true,
  "displays": [
    { "displayIndex": 1, "glazeMonitorIndex": 1, "keepAwakeWorkspaces": [2, 4] },
    { "displayIndex": 2, "glazeMonitorIndex": 2, "keepAwakeWorkspaces": ["chat"] }
  ]
}
```

Do step 3 and step 4 of the installation again for each monitor. Then put the two indexes in
the item for that monitor.

The other settings stay at the top level. They apply to all the monitors.

You can give one monitor a different time. Put `idleSeconds` in the item for that monitor.
This value replaces the value at the top level for that monitor only.

```json
"displays": [
  { "displayIndex": 1, "glazeMonitorIndex": 1, "keepAwakeWorkspaces": [2, 4] },
  { "displayIndex": 2, "glazeMonitorIndex": 2, "keepAwakeWorkspaces": [], "idleSeconds": 30 }
]
```

The program sends one `glazewm` command for all the monitors. This makes sure that more monitors do not make
the program slower.

## Settings

All settings are in `settings.json`.

| Setting | Function |
|---|---|
| `displays` | A list of monitors. Refer to ["More than one monitor"](#more-than-one-monitor). |
| `displayIndex` | The monitor that goes into standby. Use the index from `-List`. |
| `glazeMonitorIndex` | The position of the same monitor in `glazewm query monitors`. |
| `idleSeconds` | The time in seconds that a monitor stays unused before standby. You can also put this setting in one item of the `displays` list. |
| `pollSeconds` | The interval between the checks. Decimal values are permitted. The minimum is 0.05. |
| `glazePollSeconds` | The minimum interval between two `glazewm` commands. |
| `offValue` | The standby command value. Use `4` first. If the monitor does not obey, use `5`. |
| `keepAwakeWorkspaces` | The workspaces that keep the monitor on. An empty list stops the GlazeWM rule. |
| `wakeOnFocus` | If `true`, a window in focus on that monitor keeps the monitor on. |
| `wakeOnMouseEnter` | If `true`, mouse movement on that monitor keeps the monitor on. |

The program reads `settings.json` again after you save it. You do not have to start the
program again. If the file has an error, the program keeps the last correct settings. It also
writes a warning.

## Operation

The program measures the idle time of each monitor. It does not measure the idle time of the
computer. Thus work on one monitor does not start a different monitor again.

Three conditions show that you use a monitor. Each condition sets the idle time of that
monitor to zero:

- The mouse pointer is on the monitor, and the pointer moves.
- The window in focus is on the monitor. Your keys go to that window.
- GlazeWM shows a workspace from `keepAwakeWorkspaces` on the monitor, and that workspace
  contains one window or more.

A monitor goes into standby when no condition is true for `idleSeconds` seconds.

A pointer that stays at one position does not keep a monitor on. The pointer must move.

## The notification area icon

Click the icon with the right mouse button. The menu has three items:

| Item | Function |
|---|---|
| Enabled | Stops or starts the automatic control. |
| Sleep now | Puts all the controlled monitors into standby immediately. |
| Exit | Starts the monitors again, then stops the program. |

Put the mouse pointer on the icon to see how many monitors are in standby.

## Effect on the monitor

The program writes only one DDC/CI value: `0xD6`, the power state. The monitor does not keep
this value in its memory. Windows uses the same mechanism for its display timeout. Thus you
can use this program continuously.

## Known Issues

- Some monitors do not obey a DDC/CI standby command that comes from software. If your
  monitor stays on, set `offValue` to `5`.
- Some monitors do not accept DDC/CI commands while they are in standby. If your monitor does
  not come on again, move the mouse pointer, or use the monitor power button.
- If windows screen saver is configured. When entering screen saver, the secondary monitor will turn back on (and display the screensaver). - I honestly don't hate this.

----------------
Engineered with Anthropic's Opus 5 Model
