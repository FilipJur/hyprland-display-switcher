# Plan: Root Cause Analysis — UGREEN CH7218A PCON FRL Link Training Failure on AMD RX 6800 XT

## Objective
Exhaustively investigate why a UGREEN DP 1.4 to HDMI 2.1 adapter (Chrontel CH7218A PCON) cannot maintain stable 10-bit FRL output when it is the ONLY active display on an AMD RX 6800 XT (Navi 21, RDNA 2). The adapter works perfectly in dual-display extend mode. Find concrete code paths, register names, commit hashes, workarounds, and root causes.

## Skill Loading
- **Stage 1**: `deep-research-swarm` — multi-agent parallel research across kernel source, mailing lists, bug trackers, forums
- **Stage 2**: `vibecoding-general-swarm` — if we need to write a kernel patch or tool

## Stage 1 — Parallel Deep Research (Multi-Agent Swarm)

Deploy 6 parallel research agents, each with a focused mandate. All agents return concrete findings with source URLs, commit hashes, code paths, and register names.

### Agent 1: Kernel Source Code — PCON FRL Link Training & `read_and_intersect_post_frl_lt_status`
- Search the Linux kernel source tree (focus on `drivers/gpu/drm/amd/display/`) for:
  - Function `read_and_intersect_post_frl_lt_status`
  - Function `read_post_frl_lt_status`
  - Any PCON (Protocol Converter) related code
  - FRL (Fixed Rate Link) link training flow
  - What registers are read? What conditions cause failure? Is there a fallback to TMDS?
- Search for `CH7218` or `Chrontel` quirks
- Search for DSC (Display Stream Compression) configuration differences between single and dual display
- Git log for `drm/amd/display` commits mentioning PCON, FRL, link training

### Agent 2: Kernel Source Code — Display Disable Path & Clock Reconfiguration
- Search amdgpu DC for the display disable path:
  - What happens when a secondary monitor is disabled?
  - Does it reconfigure clock domains (DPPCLK, DISPCLK, DPREFCLK)?
  - Does it change DP link configuration (lane count, link rate)?
  - Does it toggle DSC?
  - Does it reset the display controller (DCN 3.1.x)?
- Search for MCLK (memory clock) behavior differences between single and dual display
- Search for `dcfeaturemask` bits related to multi-monitor behavior
- Search for `force_clock_mode` or `forced_clocks` debug options

### Agent 3: Mailing Lists & Bug Trackers — PCON FRL & CH7218 Known Issues
- Search lore.kernel.org for:
  - "PCON TX link training has not finished"
  - "PCON FRL"
  - "CH7218"
  - "amdgpu" + "PCON"
- Search Freedesktop GitLab (gitlab.freedesktop.org) for amdgpu issues:
  - Issues mentioning PCON, FRL, link training
  - Issues mentioning CH7218 or similar PCON adapters
- Search AMD's GPUOpen or bug tracker

### Agent 4: Forums & Community — Known Workarounds & Real-World Fixes
- Search Level1Techs forum (thread 227748 and others):
  - PCON adapter issues on AMD
  - CH7218 workarounds
  - `dc_debug_mask` settings
- Search Reddit r/linux_gaming and r/Amd:
  - HDMI 2.1 adapter issues
  - PCON link training
  - MCLK drop issues
- Search Phoronix comments and articles
- Search GitHub issues (any repository) for amdgpu PCON problems

### Agent 5: Kernel Parameters, Module Options & sysfs — Power/CLK Controls
- Search for:
  - `amdgpu` module parameters that affect display reconfiguration
  - `power_dpm_force_performance_level` — how to write without root (polkit, dbus, sysfs ownership)
  - `amdgpu.dc_debug_mask` documented bits and their effects
  - Ways to prevent MCLK from dropping below a threshold
  - `force_clock_mode` or similar debug options
- Search kernel docs for amdgpu driver parameters

### Agent 6: Kernel Regression Analysis — 6.18 vs 7.0 amdgpu Display Code
- Identify key differences in `drivers/gpu/drm/amd/display/` between kernel 6.18 and 7.0
- Focus on:
  - PCON/FRL related changes
  - Display disable/enable path changes
  - MCLK/clock domain changes
  - Any commits that touch `read_and_intersect_post_frl_lt_status`
  - DSC-related changes
- Use git log/diff concepts — search for relevant commits in the changelog

## Stage 2 — Synthesis & Patch Search
- Once all agents return, cross-reference findings
- Search for any existing kernel patches that address the specific failure mode
- Identify the most promising workaround or fix

## Deliverable
A comprehensive report with:
- Concrete code paths (file paths, line numbers where possible)
- Register names and bit definitions
- Commit hashes of relevant patches
- Exact kernel parameters and their values
- Workarounds ranked by likelihood of success
- Clear statement of root cause if found
