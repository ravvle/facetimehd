# Graph Report - facetimehd  (2026-08-18)

## Corpus Check
- 40 files · ~81,629 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 504 nodes · 1015 edges · 28 communities (21 shown, 7 thin omitted)
- Extraction: 88% EXTRACTED · 12% INFERRED · 0% AMBIGUOUS · INFERRED: 123 edges (avg confidence: 0.79)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `216f08f8`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- fthd_isp.c
- fthd_drv.c
- common.sh
- fthd_v4l2.c
- CI workflow
- Hardware validation status (open items)
- hw-validate.sh
- fthd_ringbuf.c
- FaceTime HD Camera for Linux (project)
- fthd_debugfs.c
- fthd_hw.h
- extract-firmware.sh
- script-smoke.sh
- smoke-capture.sh
- Installer idempotency via diff against /usr/src
- KDIR=/usr/src/kernels override for RPM containers
- build-deb.sh
- build-rpm.sh
- Removal of unused DDR shmoo calibration code
- build-driver.sh
- AGENTS.md
- isp_fill_channel_info
- FaceTimeHD firmware command notes
- isp_init
- fthd_firmware_roundtrip
- fthd_s_ctrl
- fthd_stop_channel
- fthd_firmware_start

## God Nodes (most connected - your core abstractions)
1. `install.sh script` - 31 edges
2. `fthd_start_channel()` - 26 edges
3. `macbook-tune.sh script` - 21 edges
4. `have()` - 18 edges
5. `hw-validate.sh script` - 17 edges
6. `fthd_pci_probe()` - 16 edges
7. `FaceTimeHD firmware command notes` - 14 edges
8. `show_status()` - 13 edges
9. `uninstall.sh script` - 12 edges
10. `extract-firmware.sh script` - 11 edges

## Surprising Connections (you probably didn't know these)
- `tests/script-smoke.sh Makefile-completeness check` --semantically_similar_to--> `Every shell script is linted guard`  [INFERRED] [semantically similar]
  src/facetimehd/DOWNSTREAM.md → .github/workflows/ci.yml
- `fthd_pci_probe()` --calls--> `fthd_debugfs_init()`  [INFERRED]
  src/facetimehd/fthd_drv.c → src/facetimehd/fthd_debugfs.c
- `fthd_v4l2_close()` --calls--> `fthd_pm_put()`  [INFERRED]
  src/facetimehd/fthd_v4l2.c → src/facetimehd/fthd_drv.h
- `KDIR=/usr/src/kernels override for RPM containers` --conceptually_related_to--> `Kernel build tree tested with -d, not -e or -L`  [INFERRED]
  .github/workflows/ci.yml → CLAUDE.md
- `Kernel build matrix (Ubuntu/Fedora/AlmaLinux)` --conceptually_related_to--> `Supported distribution matrix`  [EXTRACTED]
  .github/workflows/ci.yml → README.md

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Frame decimation and deferred buffer requeue** — src_facetimehd_downstream_frame_rate_decimation, src_facetimehd_downstream_fthd_buffer_return_handler, src_facetimehd_downstream_fthd_irq_work, src_facetimehd_downstream_fthd_send_h2t_buffer, src_facetimehd_downstream_requeue_work, src_facetimehd_downstream_fthd_stop_streaming [EXTRACTED 1.00]
- **Stream survival across suspend/resume** — src_facetimehd_downstream_suspend_mid_stream, src_facetimehd_downstream_fthd_v4l2_suspend_stop, src_facetimehd_downstream_fthd_v4l2_resume_start, src_facetimehd_downstream_fthd_start_channel, src_facetimehd_downstream_control_replay, src_facetimehd_downstream_runtime_pm [EXTRACTED 1.00]
- **Watchdogs for breakage with nobody touching the repo** — _github_workflows_ci_weekly_schedule, _github_workflows_ci_apple_sources_job, _github_workflows_ci_build_matrix, _github_dependabot_action_pinning [EXTRACTED 1.00]

## Communities (28 total, 7 thin omitted)

### Community 0 - "fthd_isp.c"
Cohesion: 0.10
Nodes (25): fthd_isp_cmd_channel_ae_metering_mode_set(), fthd_isp_cmd_channel_ae_speed_set(), fthd_isp_cmd_channel_ae_stability_set(), fthd_isp_cmd_channel_ae_stability_to_stable_set(), fthd_isp_cmd_channel_camera_config_select(), fthd_isp_cmd_channel_crop_set(), fthd_isp_cmd_channel_drc_start(), fthd_isp_cmd_channel_error_handling_config() (+17 more)

### Community 1 - "fthd_drv.c"
Cohesion: 0.07
Nodes (44): irqreturn_t, pci_channel_state_t, pci_ers_result_t, fthd_buffer_exit(), fthd_buffer_init(), iommu_allocator_destroy(), iommu_allocator_init(), u32 (+36 more)

### Community 2 - "common.sh"
Cohesion: 0.09
Nodes (60): collect(), redact(), section(), collect-diagnostics.sh script, usage(), extract-firmware.sh script, dkms_installed_versions(), enroll_mok() (+52 more)

### Community 3 - "fthd_v4l2.c"
Cohesion: 0.08
Nodes (39): iommu_allocate_sgtable(), iommu_free(), fthd_irq_work(), fthd_is_powered(), fthd_mark_firmware_wedged(), fthd_resume(), fthd_suspend(), u32 (+31 more)

### Community 4 - "CI workflow"
Cohesion: 0.07
Nodes (37): Dependabot GitHub Actions pinning policy, Apple download watchdog job, Kernel build matrix (Ubuntu/Fedora/AlmaLinux), Clang strict build job, Sparse static analysis job, Every shell script is linted guard, packaging job (deb/rpm), CI workflow (+29 more)

### Community 5 - "Hardware validation status (open items)"
Cohesion: 0.07
Nodes (31): Hardware report issue form, Debugfs created in probe(), destroyed in remove(), DDR/PLL/FWMSG bring-up messages are dev_dbg, Power management is not this project's job, facetimehd-runtime-pm.conf modprobe drop-in, A wrong firmware guess must be refused, not destructive, Hardware reports are the most valuable contribution, MacBookAir7,2 as the sole validation machine (+23 more)

### Community 6 - "hw-validate.sh"
Cohesion: 0.09
Nodes (17): capture_ok(), check_ring_wrap(), clock_sane(), dmesg_driver(), dmesg_mark(), dmesg_since(), faults_present(), load_module() (+9 more)

### Community 7 - "fthd_ringbuf.c"
Cohesion: 0.28
Nodes (14): buf_t2h_handler(), u32, fthd_handle_irq(), io_t2h_handler(), sharedmalloc_handler(), terminal_handler(), isp_mem_destroy_offset(), u32 (+6 more)

### Community 8 - "FaceTime HD Camera for Linux (project)"
Cohesion: 0.12
Nodes (18): Bug report issue form, DOWNSTREAM.md is the review record for fork changes, driver-patches/ is a generated view, not an input, Fan support is deliberately its own script, Propose driver fixes upstream where they apply, Broadcom BCM1570 PCIe FaceTime HD Camera (14e4:1570), collect-diagnostics.sh one-file bug report, FaceTime HD Camera for Linux (project) (+10 more)

### Community 9 - "fthd_debugfs.c"
Cohesion: 0.10
Nodes (34): loff_t, s32, u8, fthd_debugfs_init(), fthd_debugfs_open(), fthd_debugfs_release(), fthd_debugfs_seq_open(), fthd_debugfs_seq_release() (+26 more)

### Community 10 - "fthd_hw.h"
Cohesion: 0.41
Nodes (12): fthd_hw_pci_post(), _FTHD_ISP_REG_READ(), _FTHD_ISP_REG_WRITE(), fthd_range_valid(), fthd_s2_mem_range_valid(), _FTHD_S2_MEM_READ(), _FTHD_S2_MEM_WRITE(), _FTHD_S2_MEMCPY_FROMIO() (+4 more)

### Community 11 - "extract-firmware.sh"
Cohesion: 0.18
Nodes (8): CALIBRATION_HASHES, CALIBRATION_LAYOUT, DRIVER_COMPRESSION, DRIVER_NAMES, DRIVER_OFFSETS, DRIVER_SIZES, FIRMWARE_VERSIONS, usage()

### Community 12 - "script-smoke.sh"
Cohesion: 0.53
Nodes (8): check_dkms_format(), check_documented_options(), code_only(), expect_output(), expect_status(), make_stub_dkms(), result(), script-smoke.sh script

### Community 14 - "Installer idempotency via diff against /usr/src"
Cohesion: 0.50
Nodes (4): diffutils is an RPM dependency on purpose, Installer idempotency via diff against /usr/src, Version derivation with source fingerprint, Package version omits the source fingerprint

### Community 21 - "isp_fill_channel_info"
Cohesion: 0.67
Nodes (3): isp_fill_channel_info(), isp_free_channel_info(), isp_get_chan_index()

### Community 22 - "FaceTimeHD firmware command notes"
Cohesion: 0.11
Nodes (17): Bounded metering-mode semantics harness, Confirmed read-only command surface, Corrected-build reboot validation (2026-08-18), Corrected-build runtime-PM validation (2026-08-18), FaceTimeHD firmware command notes, Full-system suspend finding (2026-08-18), Image examined, Incident reconstruction (+9 more)

### Community 23 - "isp_init"
Cohesion: 0.24
Nodes (11): resource_size_t, __fthd_isp_cmd(), fthd_isp_cmd_set_loadfile(), fthd_isp_debug_cmd(), isp_acpi_set_power(), isp_enable_sensor(), isp_init(), isp_load_firmware() (+3 more)

### Community 24 - "fthd_firmware_roundtrip"
Cohesion: 0.30
Nodes (12): fthd_firmware_roundtrip(), u32, fthd_isp_cmd_channel_ae_bias_get(), fthd_isp_cmd_channel_ae_bias_set(), fthd_isp_cmd_channel_ae_bias_set_raw(), fthd_isp_cmd_channel_ae_gain_cap_min_set_raw(), fthd_isp_cmd_channel_ae_gain_cap_set_raw(), fthd_isp_cmd_channel_ae_gain_set() (+4 more)

### Community 25 - "fthd_s_ctrl"
Cohesion: 0.25
Nodes (8): fthd_isp_cmd_channel_ae(), fthd_isp_cmd_channel_ae_flicker_freq_set(), fthd_isp_cmd_channel_awb(), fthd_isp_cmd_channel_brightness_set(), fthd_isp_cmd_channel_contrast_set(), fthd_isp_cmd_channel_hue_set(), fthd_isp_cmd_channel_saturation_set(), fthd_s_ctrl()

### Community 26 - "fthd_stop_channel"
Cohesion: 0.25
Nodes (8): fthd_isp_cmd_channel_buffer_return(), fthd_isp_cmd_channel_face_detection_disable(), fthd_isp_cmd_channel_face_detection_stop(), fthd_isp_cmd_channel_motion_history_stop(), fthd_isp_cmd_channel_stop(), fthd_isp_cmd_channel_temporal_filter_disable(), fthd_isp_cmd_channel_temporal_filter_stop(), fthd_stop_channel()

### Community 27 - "fthd_firmware_start"
Cohesion: 0.33
Nodes (6): fthd_firmware_start(), fthd_isp_cmd_camera_config(), fthd_isp_cmd_channel_camera_config(), fthd_isp_cmd_channel_info(), fthd_isp_cmd_print_enable(), fthd_isp_cmd_start()

## Knowledge Gaps
- **34 isolated node(s):** `build-deb.sh script`, `build-rpm.sh script`, `DRIVER_NAMES`, `DRIVER_OFFSETS`, `DRIVER_SIZES` (+29 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **7 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `fthd_pci_probe()` connect `fthd_drv.c` to `fthd_debugfs.c`, `fthd_firmware_start`?**
  _High betweenness centrality (0.008) - this node is a cross-community bridge._
- **Why does `Apple firmware extraction (firmware 1.43.0)` connect `CI workflow` to `FaceTime HD Camera for Linux (project)`?**
  _High betweenness centrality (0.007) - this node is a cross-community bridge._
- **Why does `fthd_start_channel()` connect `fthd_isp.c` to `fthd_v4l2.c`, `fthd_firmware_start`?**
  _High betweenness centrality (0.007) - this node is a cross-community bridge._
- **Are the 2 inferred relationships involving `fthd_start_channel()` (e.g. with `fthd_v4l2_refresh_crop()` and `fthd_stream_start()`) actually correct?**
  _`fthd_start_channel()` has 2 INFERRED edges - model-reasoned connections that need verification._
- **What connects `build-deb.sh script`, `build-rpm.sh script`, `DRIVER_NAMES` to the rest of the system?**
  _34 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `fthd_isp.c` be split into smaller, more focused modules?**
  _Cohesion score 0.10416666666666667 - nodes in this community are weakly interconnected._
- **Should `fthd_drv.c` be split into smaller, more focused modules?**
  _Cohesion score 0.07017543859649122 - nodes in this community are weakly interconnected._