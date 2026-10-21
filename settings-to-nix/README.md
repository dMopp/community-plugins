# Settings to Nix

Configure Noctalia entirely in its settings window and still keep every setting in your
NixOS / Home Manager configuration. The plugin mirrors Noctalia's GUI settings into a
Nix file. You commit that file with your configuration, and on a new install (or after
the state is lost) your configuration writes it back, so nothing gets lost.

> [!IMPORTANT]
> **This plugin only writes a `.nix` file. It never builds, switches or changes your
> system configuration.** The file is not used by anything until your configuration
> uses it (see [Setup](#setup)).
>
> With flakes, the file has to be inside your config repository and tracked by git
> (`git add`), or Nix cannot see it.

## Plugin

| Field | Value |
| --- | --- |
| ID | `dmopp/settings-to-nix` |
| Entries | Shortcut: `export`; panel: `panel`; service: `service` |

## Requirements

- `nix`: the generated file is meant for a NixOS or Home Manager configuration.
  `nix-instantiate` on `PATH` is used to check the file before it replaces the old
  one; without it the check is skipped.

## How it works

Noctalia reads its configuration in two layers:

1. `~/.config/noctalia/*.toml`: the config files. Noctalia never writes to them.
2. `~/.local/state/noctalia/settings.toml` (`$XDG_STATE_HOME`/`$NOCTALIA_STATE_HOME`
   are honored): everything you change in the settings window. This layer wins.

The settings window can only override layer 1, not remove anything from it. A calendar
account, bar or widget defined in a config file cannot be deleted in the GUI. That is
why this plugin does **not** turn your settings into a config file. Instead:

```text
GUI ──▶ settings.toml ──export──▶ gui-settings.nix   (in your config repo, committed)
              ▲                                                     │
              └──── written by your configuration, only when settings.toml is missing
```

- **Export** writes `settings.toml` to the Nix file as an exact mirror. A setting you
  delete in the GUI also disappears from the file on the next export.
- **Your configuration** turns the file back into `settings.toml`, but only when that
  file does not exist yet (new machine, new user, lost state). On a running system
  Noctalia keeps using its own `settings.toml`, so nothing needs a rebuild to take
  effect and everything stays editable and deletable in the GUI.

The wallpaper paths Noctalia rewrites on every wallpaper change (`wallpaper.last.path`,
`wallpaper.default.path`, `wallpaper.monitors.*.path`) are left out by default.

## Usage

### Setup

1. **Install and enable** the plugin, and add its control-center tile
   (see [Where the buttons are](#where-the-buttons-are)).
2. **Set the target file inside your config repository.** Open **Settings → Plugins**,
   click the gear on the **Settings to Nix** row and set **Target Nix file**, for
   example `/etc/nixos/noctalia/gui-settings.nix` or
   `~/nixos-config/noctalia/gui-settings.nix`. The directory must be writable by your
   user. Turning on **Export automatically** is recommended.
3. **Export once** (right-click the tile, or **Export to Nix** in the panel) and track
   the file in git (flakes only):

   ```sh
   git -C /etc/nixos add noctalia/gui-settings.nix
   ```

4. **Let your configuration seed `settings.toml` from the file.** Pick the variant
   that matches your setup and replace `alice` with your user name.

   **NixOS** (also with hjem):

   ```nix
   { pkgs, ... }:
   let
     noctaliaSeed = (pkgs.formats.toml { }).generate "noctalia-settings.toml"
       (import ./noctalia/gui-settings.nix);
   in
   {
     # Writes settings.toml only when it does not exist yet (new install, lost state).
     system.userActivationScripts.noctalia-settings-seed = ''
       if [ "$USER" = alice ]; then
         f="''${XDG_STATE_HOME:-$HOME/.local/state}/noctalia/settings.toml"
         if [ ! -e "$f" ]; then
           mkdir -p "$(dirname "$f")"
           install -m 644 ${noctaliaSeed} "$f"
         fi
       fi
     '';
   }
   ```

   **Home Manager:**

   ```nix
   { lib, pkgs, ... }:
   let
     noctaliaSeed = (pkgs.formats.toml { }).generate "noctalia-settings.toml"
       (import ./noctalia/gui-settings.nix);
   in
   {
     # Writes settings.toml only when it does not exist yet (new install, lost state).
     home.activation.noctaliaSettingsSeed = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
       f="''${XDG_STATE_HOME:-$HOME/.local/state}/noctalia/settings.toml"
       if [ ! -e "$f" ]; then
         run mkdir -p "$(dirname "$f")"
         run install -m 644 ${noctaliaSeed} "$f"
       fi
     '';
   }
   ```

5. **Remove what generated Noctalia's config before**, such as
   `programs.noctalia.settings`, an `environment.etc` entry or a symlinked
   `~/.config/noctalia/config.toml`. Keep only what you deliberately want to be
   read-only. Everything left in a config file can no longer be removed in the GUI
   (see [How it works](#how-it-works)).

> [!WARNING]
> **Coming from a config file?** If your settings currently live in a config file,
> moving only `settings.toml` into the Nix file loses them once the config file is
> gone. Save the merged state into `settings.toml` first, then export:
>
> ```sh
> cp ~/.local/state/noctalia/settings.toml ~/noctalia-settings.backup.toml
> noctalia config export merged > /tmp/noctalia-merged.toml
> { echo 'config_version = 15'; cat /tmp/noctalia-merged.toml; } > ~/.local/state/noctalia/settings.toml
> ```
>
> Use the `config_version` from your backup. Noctalia reloads the file on its own.

### Restoring after a reinstall

1. Install the system, clone your configuration repository and build it as usual
   (`sudo nixos-rebuild switch --flake .` or `home-manager switch`).
2. **Log in.** The activation snippet from step 4 of the setup writes
   `settings.toml` from the Nix file because it does not exist yet. On NixOS this
   runs in the user service `nixos-activation.service` at login and on every switch.
   If Noctalia starts first, it picks the file up on its own as soon as it appears.
3. Noctalia now runs with your old settings.

Things to know:

- **Do not change anything in the settings window before that first login.** Any
  change creates `settings.toml`, and the seed never overwrites an existing file. If
  it happened anyway, move the file away and run the activation again:

  ```sh
  mv ~/.local/state/noctalia/settings.toml ~/.local/state/noctalia/settings.toml.old
  systemctl --user restart nixos-activation.service   # Home Manager: home-manager switch
  ```

  The same commands roll an existing machine back to the last state you committed.
- **What comes back is the state of your last commit/push**, so commit the Nix file
  regularly (for example as part of your rebuild alias).
- **Secrets are not part of the settings.** Calendar passwords and other credentials
  live in your keyring; enter them again after the restore.
- **Plugins from local `path` sources** are only found if those directories exist
  again. Plugins from the `official` and `community` sources are installed again
  automatically.
- **Excluded paths** (by default the current wallpaper paths) are not restored. If a
  wallpaper rotation script or Noctalia's wallpaper settings set them, nothing is
  needed; otherwise pick the wallpaper once.

### Where the buttons are

After enabling the plugin you will not see a button anywhere yet. Noctalia does not
add plugin shortcuts to the control center on its own. There are three ways to use
it; pick one.

> [!NOTE]
> The control center's Home tab holds **at most six shortcuts**, and the default set
> already uses all six (`wifi`, `bluetooth`, `caffeine`, `nightlight`,
> `notification`, `power_profile`). To add the tile you have to **remove another
> shortcut first**; until then the **+** button stays disabled and nothing tells you
> why. If you do not want to give one up, use the panel (B) or automatic export (C).

**A. Control-center tile (recommended)**

1. Open **Settings → Control Center** and expand **Home**. The **Home shortcuts** list
   holds at most **six** shortcuts. When it shows `6/6`, the **+** button is disabled:
   remove one shortcut with its **✕** first.
2. In the dropdown, choose **Settings to Nix**. The dropdown shows the plugin's name;
   the tile itself is labeled **Export to Nix**. Then click **+**.
3. The tile (a snowflake) now appears at the bottom of the control center's Home tab:
   - **Click** opens the panel.
   - **Right-click** exports directly, without opening the panel.
   - The tile is highlighted while the GUI has changes that are not in the Nix file
     yet, and reads **Export to Nix (changed)**.

The same in TOML:

```toml
[[control_center.shortcuts]]
type = "dmopp/settings-to-nix:export"
```

**B. Panel only, e.g. on a compositor key binding**

```sh
noctalia msg panel-toggle dmopp/settings-to-nix:panel
```

The panel shows how many settings the file holds, whether the GUI changed since the
last export, the target path and an **Export to Nix** button.

**C. No button at all.** Turn on **Export automatically** in the plugin settings.
Every GUI change is then written to the Nix file within a few seconds.

### Everyday use

1. Change settings in the GUI as usual. They take effect immediately, as always.
2. Export: right-click the tile, use the panel, or let **Export automatically** do it.
3. Commit the Nix file with your configuration whenever you commit anyway. A rebuild
   is not needed for Noctalia.

An optional reminder (off by default) notifies you once when GUI changes have not been
exported for some hours.

The generated file looks like this:

```nix
{
  bar.Top.capsule_opacity = 0.35;
  config_version = 15;
  shell.greeter_sync.auto_sync = true;
  theme = {
    mode = "dark";
    source = "wallpaper";
  };
}
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `target_path` | `file` | `~/.config/noctalia/gui-settings.nix` | File the settings are mirrored to. It is overwritten on every export. With flakes, point it inside your config repository. |
| `auto_export` | `bool` | `false` | Export whenever `settings.toml` changes (checked every 2 seconds) instead of only on demand. |
| `notify` | `bool` | `true` | Notification after a manual export. Errors are always shown. |
| `remind_export_hours` | `int` | `0` | Notify once when GUI changes have not been exported for this many hours (0–168, 0 = off). Not used with `auto_export`. |
| `exclude` | `string_list` | wallpaper paths | Dotted paths left out of the export; `*` matches one level (advanced). |
| `validate` | `bool` | `true` | Check the generated file with `nix-instantiate --parse` before replacing the target (advanced). |

## IPC

```sh
# Export now (same as right-clicking the tile)
noctalia msg plugin dmopp/settings-to-nix:service all export
```

`export` fits well in a rebuild or commit alias.

## Notes

- **Nothing of yours is overwritten.** The plugin only replaces a target file that it
  wrote itself (recognized by its first line). Point it at any other existing file and
  the export stops with an error.
- **Files written:** the target file (via `<target>.tmp` and a rename) and
  `reminders.json` in the plugin data dir
  (`~/.local/state/noctalia/plugins/data/dmopp/settings-to-nix/`). The plugin never
  writes `settings.toml`.
- **Processes:** only `nix-instantiate --parse <target>.tmp` (when `validate` is on).
  There is no network access.
- TOML values Nix cannot express (`inf`, `nan`) are left out; dates are exported as
  strings.
- The plugin reads `settings.toml` itself (with its own TOML reader), so it does not
  need `remarshal`, `yj` or similar.
