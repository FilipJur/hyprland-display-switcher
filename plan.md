# Native HDMI Refactor Implementation Plan

## Handoff Contract

This plan is for the implementation developer. `ARCHITECTURE.md` is authoritative when this plan and existing code disagree. The current source is adapter-era legacy; do not preserve behavior merely because it exists.

Branch from the architecture-documentation commit. Keep the baseline checkpoint `607ccaae0ad4c15ebf5592b72a8530f5ba504bac` reachable for rollback.

The implementation is complete only when both physical transitions pass the live acceptance matrix. Static checks alone are insufficient for a display control path.

## Scope Lock

Implement exactly:

- Monitor mode: PHL 345E2 only.
- TV mode: Philips UHDTV only, native HDMI, 3840×2160@144, 10-bit, HDR, VRR.
- Two-option GTK overlay and Super+O workflow.
- EDID-based discovery, safe staged transition, workspace migration, final-state verification, installation, and documentation.

Do not implement:

- Extend, Mirror, audio switching, adapter compatibility, fallback modes, retry resets, DPM control, DPCD access, daemon restarts, Lua generation, or generalized profile configuration.

## Phase 0 — Operational Preflight

No project code changes in this phase.

1. Set the TV input to **Optimal (Auto Game)**.
2. Run `hyprctl -j monitors all` and capture the monitor identities and TV `availableModes`.
3. Gate implementation validation on a TV mode matching 3840×2160 at 144 Hz. The architecture-time snapshot did not advertise it; do not proceed to TV acceptance until it appears.
4. Confirm the deployed config source order remains:
   - `monitors.conf`
   - `display-switcher-generated.conf`
5. Save copies of `/etc/default/limine` and relevant sudoers entries before the external migration phase.

Gate: exact 4K144 mode is advertised after the TV setting change. There is no 4K120 or 1080p144 acceptance substitute.

## Phase 1 — Replace the Apply Control Plane

Owner: `src/display_apply.sh` only. Do not edit the overlay concurrently with this phase.

### CLI and lock

1. Replace the current default-mode argument handling with the exact `status|monitor|tv` contract.
2. Use one process lock for mutations; `status` remains read-only and does not wait behind a switch.
3. Return the architecture-defined exit codes.
4. Keep concise timestamped logging in `~/.local/state/display-switcher.log`.

### Structured discovery

1. Query `hyprctl -j monitors all` once per decision.
2. Use `jq` to select:
   - PHL 345E2 by exact make/model/serial.
   - Philips UHDTV by `HDMI-A-*` connector plus exact make/model.
3. Reject multiple/ambiguous matches for either role and reject a TV match on a non-HDMI connector.
4. Require exactly one match for the requested target. Allow the non-target role to be absent so a disconnected TV cannot block Monitor-mode recovery.
5. Parse TV modes as resolution plus numeric refresh. Require 3840×2160 and 144 ± 0.1 Hz before any TV-mode mutation.
6. Implement status from enabled/disabled role state. A sole enabled known role is its mode even when the other display is absent. Both-active and neither-active are `unknown`; never default them to Monitor mode.

### Profile generation

1. Define each profile once. Do not duplicate field lists across staging, final generation, and verification.
2. Generate hyprlang `monitorv2` blocks only.
3. Use the verbatim full live Hyprland 0.56.2 `description` values, including the Monitor serial and TV dummy serial, in persistent selectors. Do not assemble selector text from separate fields. Use runtime connector names for IPC.
4. Enforce `HDMI-A-*` during every TV preflight. Hyprland cannot conjunct connector class with an EDID selector, so require the supported physical contract that the TV remains on native HDMI; apply Monitor mode before any intentional transport change.
5. Write to a temporary sibling file, validate that it is nonempty and contains exactly two output rules, then atomically rename it.
6. Include mode-specific `quirks:prefer_hdr` persistent state.

### Transaction

1. Snapshot the previous generated file and live `quirks:prefer_hdr` value.
2. Write/reload a staging config with target first and keep any connected, active source at a non-overlapping position.
3. Poll every 100 ms for no more than five seconds; verify the target profile is active.
4. Migrate all active workspaces from each connected source to the target.
5. Write/reload the final config with target active first and the non-target description disabled second.
6. Poll and verify the complete final contract.
7. On any post-mutation failure, restore the previous generated file atomically without a monitor reload, restore the snapshotted live HDR preference through IPC, report the observed state, and exit 4.
8. Reapplying the current mode must be harmless and verified.

### Required deletions inside the rewrite

Remove all of the following rather than leaving dormant branches:

- `MONITOR="DP-2"` and `TV="DP-1"` role assumptions.
- Extend, Mirror, `monitor_only`, and `tv_only` cases.
- Text parsing of `hyprctl monitors all`.
- Audio sink constants and PipeWire/WirePlumber logic.
- DPM paths and `force_dpm_high`/`restore_dpm_auto`.
- `fix_pcon_hdmi_mode`, `reconfigure_dp_encoder`, audio PCM restarts, and PCON comments.
- FRL/DSC reset retries and arbitrary six-/five-/two-second sleeps.
- `pkill`/restart handling for dunst, swaync, and swww-daemon.
- Lua feature flags and `lua-monitor-lib.sh` sourcing.
- Adapter-only diagnostic collection.

Phase gate:

- `bash -n src/display_apply.sh` passes.
- `src/display_apply.sh status` returns the truthful current token.
- Invalid command exits 2 without changing the generated file.
- Disconnected/uncapable TV preflight exits 3 without changing the generated file or live topology.
- Direct `monitor` and `tv` commands pass the relevant live acceptance cases before overlay integration.

## Phase 2 — Reduce the Overlay to Two Modes

Owner: `src/display_switcher.py` and `config/display-switcher.css` only. Start after the Phase 1 CLI contract is stable.

1. Replace `MODES` with Monitor and TV only.
2. Delete Python monitor-text parsing. Obtain current state from `display_apply.sh status`.
3. Treat status failure or `unknown` as no current selection, not monitor mode.
4. Retain asynchronous apply, keyboard cycling, Enter confirmation, Escape cancellation, PID single-instance behavior, prewarm, and existing visual theme.
5. Remove the eight-second cooldown file and cooldown checks.
6. Update descriptions so the visible contract is explicit:
   - Monitor: `3440×1440 · SDR`
   - TV: `4K · 144 Hz · HDR · VRR`
7. Keep apply failures visible and preserve the applier's diagnostic in stderr/logs.
8. Adjust CSS only where the two-button layout otherwise leaves incorrect sizing or spacing. No visual redesign.

Phase gate:

- `python3 -m py_compile src/display_switcher.py` passes.
- With Monitor active, opening the overlay marks Monitor current and preselects TV.
- With TV active, opening the overlay marks TV current and preselects Monitor.
- With both displays manually active, opening the overlay marks neither current and allows recovery.
- Super+O cycling cannot select Extend or Mirror.

## Phase 3 — Remove Adapter and Dual-Format Artifacts

Perform after the new applier and overlay work together.

Delete:

- `src/display-dpm.sh`
- `src/fix_pcon_audio.py`
- `src/debug-video.sh`
- `src/lua-monitor-lib.sh`
- `pw.dot`
- ignored `src/__pycache__/`

Update `install.sh`:

1. Create executable symlinks only for the overlay and applier; continue installing/copying `config/display-switcher.css`.
2. Check for Bash, `hyprctl`, `jq`, Python, PyGObject, GTK3, and gtk-layer-shell.
3. Remove old deployed symlinks only when they point into this repository; do not delete unrelated user files.
4. Verify and report the required generated-config source ordering.
5. Remove all PCON, DPM, sudoers, adapter, and MVP wording.

Update `monitors.conf`:

1. Use the full EDID descriptions specified by `ARCHITECTURE.md`, including the Monitor serial and TV dummy serial.
2. Define the Monitor profile exactly as `ARCHITECTURE.md` specifies.
3. Disable the TV by its full description selector.
4. Keep this as the cold-start fallback; the generated file remains the last sourced desired-state override.

Phase gate:

- No runtime file outside `research/` contains `CH7218`, `PCON`, `DPCD`, `DP-1`, `fix-pcon`, `display-dpm`, Extend, or Mirror behavior.
- `install.sh` no longer creates obsolete links.
- Running `install.sh` twice is idempotent.

## Phase 4 — Documentation Cutover

Update after live behavior passes, so documentation describes observed behavior rather than intent.

1. Rewrite `README.md` with the two modes, dependencies, installation, exact TV prerequisite, usage, troubleshooting, and verification commands.
2. Update `AGENTS.md` only if implementation changes an architecture-approved file boundary or command.
3. Keep `research/` unchanged and label it adapter-era historical research from README.
4. Remove the pre-implementation status warning only after the full acceptance matrix passes.
5. Record the tested Hyprland/kernel versions and exact observed connector identities without making connector names configuration requirements.

Phase gate: a new developer can install, switch, validate, and roll back using repository documentation only.

## Phase 5 — External Native-HDMI Cleanup

These are deliberate operator actions, not installer behavior.

Before mutation, record the exact sudoers file containing each obsolete rule. Back up `/etc/default/limine`, each affected sudoers file, the deployed generated config, and the implementation commit. Validate sudoers backups with `visudo -c` before removing anything.

1. Edit `/etc/default/limine`; remove:
   - `amdgpu.dcdebugmask=0x420000`
   - `amdgpu.dcfeaturemask=0x0`
   - `snd_hda_intel.probe_mask=1`
2. Run `sudo limine-update`.
3. Remove obsolete sudoers rules for the old DPM and PCON helpers using `visudo`.
4. Remove stale deployed generated Lua files and obsolete helper symlinks after confirming they belong to this project.
5. Reboot.
6. Verify `/proc/cmdline` contains none of the removed parameters.
7. Repeat the complete live acceptance matrix after reboot. Pre-reboot success is not sufficient because the old adapter parameters remain active until reboot.

Rollback trigger: any display, boot, or audio regression that appears only after this external cleanup and prevents the post-reboot matrix from completing.

Rollback procedure:

1. Boot a previously working Limine entry if the normal entry cannot reach the desktop.
2. Restore the backed-up `/etc/default/limine` and affected sudoers files; run `sudo visudo -c`.
3. Run `sudo limine-update` and reboot.
4. Restore the pre-cleanup generated config. If the implementation itself is implicated, check out its last verified commit; use the baseline checkpoint only when intentionally restoring the adapter-era system and hardware.
5. Verify the restored `/proc/cmdline`, sudo access rules, Monitor-mode desktop, and the behavior that triggered rollback.

## Live Acceptance Matrix

Every row in this table is required. Capture the command, exit code, and relevant structured state.

| Case | Action | Required result |
|---|---|---|
| Status: Monitor | Start from Monitor-only | stdout `monitor`, exit 0 |
| Status: TV | Start from TV-only | stdout `tv`, exit 0 |
| Status: unknown | Manually keep both active | stdout `unknown`, exit 0 |
| TV preflight | Hide/unadvertise 4K144 | exit 3; file checksum and live topology unchanged |
| Missing Monitor | From verified TV-only state, disconnect Monitor and request Monitor | exit 3; existing TV state and generated-file checksum unchanged |
| Missing TV | From verified Monitor-only state, disconnect TV and request TV | exit 3; existing Monitor state and generated-file checksum unchanged |
| Monitor recovery without TV | Disconnect TV, request Monitor | exact Monitor profile; exit 0 |
| Invalid command | Invoke unsupported mode | exit 2; no mutation |
| Monitor → TV | Apply TV | exact TV profile; Monitor disabled; exit 0 |
| TV → Monitor | Apply Monitor | exact Monitor profile; TV disabled; exit 0 |
| Idempotent TV | Apply TV twice | both calls exit 0; second causes no degraded state |
| Idempotent Monitor | Apply Monitor twice | both calls exit 0 |
| Concurrency | Start two mutations together | one owns lock; other exits 5 |
| Failure persistence | Perform the deterministic final-verification injection below | previous generated-file checksum and live HDR preference restored; at least one display stays active |
| Overlay cycle | Exercise Super+O/Enter in both directions | only Monitor and TV selectable; selected transition succeeds |
| Reload stability | Switch repeatedly without killing layer-shell daemons | no Hyprland crash and no stale black workspace |
| Post-reboot | Repeat both transitions after kernel-parameter cleanup | full matrix still passes |

### Deterministic failure-restoration injection

This is a temporary, uncommitted validation edit—not a production flag or permanent test hook.

1. Start in a verified mode. Record the generated file's SHA-256 checksum, live `quirks:prefer_hdr`, and `hyprctl -j monitors all`.
2. Temporarily force the applier's final-verification branch to report failure **after** staging verification and the final reload have completed, immediately before success would be returned. Do not change discovery, generated profiles, staging verification, or reload behavior.
3. Run the opposite-mode transition and capture logs proving staging succeeded, the final reload ran, the injected failure was reached, and restoration executed.
4. Confirm exit 4, confirm the generated file's checksum and live HDR preference equal their pre-transition values, and capture the live topology proving at least one output remains active.
5. Revert the temporary edit and confirm the working diff contains no fault-injection code.

### Conditional connector-renumber evidence

If a second native HDMI port is physically available, replug the TV and repeat both modes to prove EDID discovery survives an `HDMI-A-*` number change. If it is not available, record the GPU port inventory as `N/A`; validator source review must still reject any fixed HDMI connector name in role discovery, IPC, or verification.

### TV verification evidence

Use `hyprctl -j monitors all` and `hyprctl getoption quirks:prefer_hdr`. The final TV object must prove:

- connector `HDMI-A-*`
- `disabled == false`
- width 3840, height 2160
- refresh 144 ± 0.1 Hz
- scale 1.5
- ten-bit `currentFormat`
- `colorManagementPreset == "hdr"`
- `vrr == true`

Also inspect the TV information panel once to corroborate 3840×2160, 144 Hz, HDR, and VRR signaling. Do not use the panel as the only proof.

### Monitor verification evidence

The final Monitor object must prove:

- exact PHL 345E2 identity
- `disabled == false`
- width 3440, height 1440
- refresh 74.98 ± 0.1 Hz
- scale 1
- ten-bit `currentFormat`
- `colorManagementPreset == "srgb"`
- `vrr == false`

The TV object must be disabled and global HDR preference must be off.

## Validator Review Gates

The implementation developer should hand back:

1. One focused diff with no unrelated refactors.
2. A deletion inventory proving adapter/runtime artifacts are gone and `research/` is unchanged.
3. Static-check output.
4. Full live acceptance output, including the post-reboot run.
5. Exact observed state for any failed matrix row; no claimed success based on generated config alone.

Validator review order:

1. Check scope and file ownership against `ARCHITECTURE.md`.
2. Trace discovery ambiguity, preflight no-mutation, and failure restoration paths.
3. Confirm there is one source of truth for profiles and status.
4. Confirm no fixed connector role assumptions or silent mode fallbacks remain.
5. Run the two physical transitions and failure cases.
6. Approve documentation only after observed behavior matches it.

## Definition of Done

Done means all of the following:

- Exactly two modes exist across UI, applier, config, installer, and docs.
- TV mode is proven at 4K144, 10-bit, HDR, and VRR over an `HDMI-A-*` connector.
- Monitor mode is proven at its specified 10-bit SDR profile.
- Every apply verifies effective state and exits nonzero on mismatch.
- Unsupported or missing hardware causes no topology mutation.
- No PCON, DPCD, DPM, audio-routing, adapter retry, fixed-port, dual-format, Extend, or Mirror runtime path remains.
- No project command requires sudo.
- Old boot parameters and sudoers rules are removed through the explicit operator migration.
- The complete matrix passes after reboot.
- README and AGENTS describe the implemented, observed system.
