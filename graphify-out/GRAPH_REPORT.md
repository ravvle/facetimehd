# Graph Report - facetimehd  (2026-08-18)

## Corpus Check
- 39 files · ~62,602 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 460 nodes · 942 edges · 30 communities (24 shown, 6 thin omitted)
- Extraction: 88% EXTRACTED · 12% INFERRED · 0% AMBIGUOUS · INFERRED: 117 edges (avg confidence: 0.79)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `e4f0090a`
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
- fthd_hw.c
- Apple firmware extraction (firmware 1.43.0)
- fthd_ringbuf.c
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
- fthd_debugfs.c
- fthd_s_ctrl
- fthd_pm_put
- isp_init
- fthd_drv.h
- fthd_isp.h
- fthd_stop_channel
- fthd_firmware_start
- isp_fill_channel_info
- fthd_set_exposure

## God Nodes (most connected - your core abstractions)
1. `install.sh script` - 30 edges
2. `fthd_start_channel()` - 25 edges
3. `macbook-tune.sh script` - 21 edges
4. `have()` - 18 edges
5. `fthd_pci_probe()` - 17 edges
6. `fthd_s_ctrl()` - 15 edges
7. `hw-validate.sh script` - 14 edges
8. `show_status()` - 12 edges
9. `extract-firmware.sh script` - 11 edges
10. `info()` - 11 edges

## Surprising Connections (you probably didn't know these)
- `tests/script-smoke.sh Makefile-completeness check` --semantically_similar_to--> `Every shell script is linted guard`  [INFERRED] [semantically similar]
  src/facetimehd/DOWNSTREAM.md → .github/workflows/ci.yml
- `fthd_pci_probe()` --calls--> `fthd_debugfs_init()`  [INFERRED]
  src/facetimehd/fthd_drv.c → src/facetimehd/fthd_debugfs.c
- `fthd_pci_probe()` --calls--> `fthd_hwmon_register()`  [INFERRED]
  src/facetimehd/fthd_drv.c → src/facetimehd/fthd_hwmon.c
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

## Communities (30 total, 6 thin omitted)

### Community 0 - "fthd_isp.c"
Cohesion: 0.14
Nodes (24): fthd_isp_cmd_channel_ae_speed_set(), fthd_isp_cmd_channel_ae_stability_set(), fthd_isp_cmd_channel_ae_stability_to_stable_set(), fthd_isp_cmd_channel_camera_config_select(), fthd_isp_cmd_channel_crop_set(), fthd_isp_cmd_channel_drc_start(), fthd_isp_cmd_channel_error_handling_config(), fthd_isp_cmd_channel_face_detection_enable() (+16 more)

### Community 1 - "fthd_drv.c"
Cohesion: 0.17
Nodes (22): irqreturn_t, fthd_debugfs_exit(), fthd_irq_handler(), fthd_irq_install(), fthd_irq_uninstall(), fthd_pci_init(), fthd_pci_probe(), fthd_pci_release_mem() (+14 more)

### Community 2 - "common.sh"
Cohesion: 0.10
Nodes (58): collect(), redact(), section(), collect-diagnostics.sh script, usage(), extract-firmware.sh script, dkms_installed_versions(), enroll_mok() (+50 more)

### Community 3 - "fthd_v4l2.c"
Cohesion: 0.07
Nodes (40): pci_channel_state_t, pci_ers_result_t, iommu_allocate_sgtable(), iommu_free(), fthd_irq_work(), fthd_is_powered(), fthd_mark_firmware_wedged(), fthd_pci_error_detected() (+32 more)

### Community 4 - "CI workflow"
Cohesion: 0.10
Nodes (25): Dependabot GitHub Actions pinning policy, Kernel build matrix (Ubuntu/Fedora/AlmaLinux), Clang strict build job, Sparse static analysis job, Every shell script is linted guard, packaging job (deb/rpm), CI workflow, installer smoke test job (+17 more)

### Community 5 - "Hardware validation status (open items)"
Cohesion: 0.07
Nodes (31): Hardware report issue form, Debugfs created in probe(), destroyed in remove(), DDR/PLL/FWMSG bring-up messages are dev_dbg, Power management is not this project's job, facetimehd-runtime-pm.conf modprobe drop-in, A wrong firmware guess must be refused, not destructive, Hardware reports are the most valuable contribution, MacBookAir7,2 as the sole validation machine (+23 more)

### Community 6 - "hw-validate.sh"
Cohesion: 0.19
Nodes (14): capture_ok(), check_ring_wrap(), dmesg_driver(), dmesg_mark(), dmesg_since(), load_module(), log(), log_section() (+6 more)

### Community 7 - "fthd_hw.c"
Cohesion: 0.18
Nodes (15): u32, fthd_ddr_verify_mem(), u32, fthd_ddr_phy_save_regs(), fthd_hw_ddr_phy_soft_reset(), fthd_hw_ddr_rewrite_mode_regs(), fthd_hw_ddr_status_busy(), fthd_hw_init() (+7 more)

### Community 8 - "Apple firmware extraction (firmware 1.43.0)"
Cohesion: 0.07
Nodes (30): Bug report issue form, Apple download watchdog job, Range-fetch and RAR carving of AppleCamera64.exe, curl named only when /usr/bin/curl is missing, Required vs best-effort dependency split, DOWNSTREAM.md is the review record for fork changes, driver-patches/ is a generated view, not an input, Fan support is deliberately its own script (+22 more)

### Community 9 - "fthd_ringbuf.c"
Cohesion: 0.28
Nodes (14): buf_t2h_handler(), u32, fthd_handle_irq(), io_t2h_handler(), sharedmalloc_handler(), terminal_handler(), __fthd_isp_cmd(), fthd_isp_debug_cmd() (+6 more)

### Community 10 - "fthd_hw.h"
Cohesion: 0.41
Nodes (12): fthd_hw_pci_post(), _FTHD_ISP_REG_READ(), _FTHD_ISP_REG_WRITE(), fthd_range_valid(), fthd_s2_mem_range_valid(), _FTHD_S2_MEM_READ(), _FTHD_S2_MEM_WRITE(), _FTHD_S2_MEMCPY_FROMIO() (+4 more)

### Community 11 - "extract-firmware.sh"
Cohesion: 0.18
Nodes (8): CALIBRATION_HASHES, CALIBRATION_LAYOUT, DRIVER_COMPRESSION, DRIVER_NAMES, DRIVER_OFFSETS, DRIVER_SIZES, FIRMWARE_VERSIONS, usage()

### Community 12 - "script-smoke.sh"
Cohesion: 0.61
Nodes (7): check_dkms_format(), check_documented_options(), expect_output(), expect_status(), make_stub_dkms(), result(), script-smoke.sh script

### Community 14 - "Installer idempotency via diff against /usr/src"
Cohesion: 0.50
Nodes (4): diffutils is an RPM dependency on purpose, Installer idempotency via diff against /usr/src, Version derivation with source fingerprint, Package version omits the source fingerprint

### Community 20 - "fthd_debugfs.c"
Cohesion: 0.17
Nodes (17): fthd_debugfs_init(), fthd_debugfs_open(), fthd_debugfs_release(), fthd_debugfs_seq_open(), fthd_debugfs_seq_release(), seq_channel_buf_h2t_read(), seq_channel_buf_t2h_read(), seq_channel_debug_read() (+9 more)

### Community 21 - "fthd_s_ctrl"
Cohesion: 0.12
Nodes (16): fthd_isp_cmd_channel_ae_bias_set(), fthd_isp_cmd_channel_ae_flicker_freq_set(), fthd_isp_cmd_channel_ae_metering_mode_set(), fthd_isp_cmd_channel_awb(), fthd_isp_cmd_channel_awb_cct_manual(), fthd_isp_cmd_channel_brightness_set(), fthd_isp_cmd_channel_chroma_suppression_set(), fthd_isp_cmd_channel_contrast_set() (+8 more)

### Community 22 - "fthd_pm_put"
Cohesion: 0.22
Nodes (11): loff_t, fthd_store_debug(), seq_sensor_temperature_read(), fthd_pm_get(), fthd_pm_put(), s32, fthd_hwmon_read_raw(), s32 (+3 more)

### Community 23 - "isp_init"
Cohesion: 0.24
Nodes (10): resource_size_t, fthd_isp_cmd_set_loadfile(), isp_acpi_set_power(), isp_enable_sensor(), isp_init(), isp_load_firmware(), isp_mem_create(), isp_mem_destroy() (+2 more)

### Community 24 - "fthd_drv.h"
Cohesion: 0.27
Nodes (4): fthd_buffer_exit(), fthd_buffer_init(), iommu_allocator_destroy(), iommu_allocator_init()

### Community 25 - "fthd_isp.h"
Cohesion: 0.29
Nodes (5): u32, fthd_hwmon_is_visible(), fthd_hwmon_read(), fthd_hwmon_register(), umode_t

### Community 26 - "fthd_stop_channel"
Cohesion: 0.25
Nodes (8): fthd_isp_cmd_channel_buffer_return(), fthd_isp_cmd_channel_face_detection_disable(), fthd_isp_cmd_channel_face_detection_stop(), fthd_isp_cmd_channel_motion_history_stop(), fthd_isp_cmd_channel_stop(), fthd_isp_cmd_channel_temporal_filter_disable(), fthd_isp_cmd_channel_temporal_filter_stop(), fthd_stop_channel()

### Community 27 - "fthd_firmware_start"
Cohesion: 0.33
Nodes (6): fthd_firmware_start(), fthd_isp_cmd_camera_config(), fthd_isp_cmd_channel_camera_config(), fthd_isp_cmd_channel_info(), fthd_isp_cmd_print_enable(), fthd_isp_cmd_start()

### Community 28 - "isp_fill_channel_info"
Cohesion: 0.40
Nodes (5): u32, isp_fill_channel_info(), isp_free_channel_info(), isp_get_chan_index(), isp_mem_destroy_offset()

### Community 29 - "fthd_set_exposure"
Cohesion: 0.50
Nodes (4): fthd_isp_cmd_channel_ae(), fthd_isp_cmd_channel_ae_gain_set(), fthd_isp_cmd_channel_ae_integration_time_set(), fthd_set_exposure()

## Knowledge Gaps
- **18 isolated node(s):** `build-deb.sh script`, `build-rpm.sh script`, `DRIVER_NAMES`, `DRIVER_OFFSETS`, `DRIVER_SIZES` (+13 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **6 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `fthd_pci_probe()` connect `fthd_drv.c` to `fthd_hw.c`, `fthd_debugfs.c`, `fthd_pm_put`, `fthd_drv.h`, `fthd_isp.h`, `fthd_firmware_start`?**
  _High betweenness centrality (0.011) - this node is a cross-community bridge._
- **Why does `fthd_start_channel()` connect `fthd_isp.c` to `fthd_v4l2.c`, `fthd_firmware_start`?**
  _High betweenness centrality (0.007) - this node is a cross-community bridge._
- **Are the 2 inferred relationships involving `fthd_start_channel()` (e.g. with `fthd_v4l2_refresh_crop()` and `fthd_stream_start()`) actually correct?**
  _`fthd_start_channel()` has 2 INFERRED edges - model-reasoned connections that need verification._
- **Are the 10 inferred relationships involving `fthd_pci_probe()` (e.g. with `fthd_buffer_exit()` and `fthd_buffer_init()`) actually correct?**
  _`fthd_pci_probe()` has 10 INFERRED edges - model-reasoned connections that need verification._
- **What connects `build-deb.sh script`, `build-rpm.sh script`, `DRIVER_NAMES` to the rest of the system?**
  _18 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `fthd_isp.c` be split into smaller, more focused modules?**
  _Cohesion score 0.14461538461538462 - nodes in this community are weakly interconnected._
- **Should `common.sh` be split into smaller, more focused modules?**
  _Cohesion score 0.09588421528720036 - nodes in this community are weakly interconnected._