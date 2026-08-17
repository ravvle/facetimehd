# Graph Report - facetimehd  (2026-08-18)

## Corpus Check
- 42 files · ~61,713 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 461 nodes · 943 edges · 20 communities (14 shown, 6 thin omitted)
- Extraction: 88% EXTRACTED · 12% INFERRED · 0% AMBIGUOUS · INFERRED: 117 edges (avg confidence: 0.79)
- Token cost: 86,905 input · 0 output

## Community Hubs (Navigation)
- ISP Command Interface
- Buffers, Debugfs and Driver Core
- Installer and Shared Shell Layer
- V4L2 Streaming and Power Management
- CI Watchdogs and Packaging
- Camera Controls and Hardware Validation
- Hardware Validation Test Script
- DDR and PLL Bring-up
- Project Identity and Contribution Rules
- Ring Buffer and IRQ Handlers
- Register and Memory Access Macros
- Firmware Extraction Tables
- Script Smoke Test
- Capture Smoke Test
- Versioning and Idempotency Decisions
- Kernel Build Tree Detection
- Debian Package Build
- RPM Package Build
- DDR Calibration Cleanup
- Driver Build Test

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
- `Firmware checksum tables live in one place` --rationale_for--> `Apple firmware extraction (firmware 1.43.0)`  [EXTRACTED]
  CLAUDE.md → README.md
- `facetimehd-firmware-install wrapper` --references--> `Apple firmware extraction (firmware 1.43.0)`  [EXTRACTED]
  packaging/README.md → README.md
- `Security scope: driver parsing, extraction, root installers` --references--> `Apple firmware extraction (firmware 1.43.0)`  [EXTRACTED]
  SECURITY.md → README.md
- `Kernel build matrix (Ubuntu/Fedora/AlmaLinux)` --conceptually_related_to--> `Supported distribution matrix`  [EXTRACTED]
  .github/workflows/ci.yml → README.md

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Watchdogs for breakage with nobody touching the repo** — _github_workflows_ci_weekly_schedule, _github_workflows_ci_apple_sources_job, _github_workflows_ci_build_matrix, _github_dependabot_action_pinning [EXTRACTED 1.00]
- **Stream survival across suspend/resume** — src_facetimehd_downstream_suspend_mid_stream, src_facetimehd_downstream_fthd_v4l2_suspend_stop, src_facetimehd_downstream_fthd_v4l2_resume_start, src_facetimehd_downstream_fthd_start_channel, src_facetimehd_downstream_control_replay, src_facetimehd_downstream_runtime_pm [EXTRACTED 1.00]
- **Frame decimation and deferred buffer requeue** — src_facetimehd_downstream_frame_rate_decimation, src_facetimehd_downstream_fthd_buffer_return_handler, src_facetimehd_downstream_fthd_irq_work, src_facetimehd_downstream_fthd_send_h2t_buffer, src_facetimehd_downstream_requeue_work, src_facetimehd_downstream_fthd_stop_streaming [EXTRACTED 1.00]

## Communities (20 total, 6 thin omitted)

### Community 0 - "ISP Command Interface"
Cohesion: 0.05
Nodes (72): resource_size_t, fthd_firmware_start(), u32, fthd_isp_cmd_camera_config(), fthd_isp_cmd_channel_ae(), fthd_isp_cmd_channel_ae_bias_set(), fthd_isp_cmd_channel_ae_flicker_freq_set(), fthd_isp_cmd_channel_ae_gain_set() (+64 more)

### Community 1 - "Buffers, Debugfs and Driver Core"
Cohesion: 0.05
Nodes (60): irqreturn_t, loff_t, fthd_buffer_exit(), fthd_buffer_init(), iommu_allocator_destroy(), iommu_allocator_init(), fthd_debugfs_exit(), fthd_debugfs_init() (+52 more)

### Community 2 - "Installer and Shared Shell Layer"
Cohesion: 0.09
Nodes (58): collect(), redact(), section(), collect-diagnostics.sh script, usage(), extract-firmware.sh script, dkms_installed_versions(), enroll_mok() (+50 more)

### Community 3 - "V4L2 Streaming and Power Management"
Cohesion: 0.07
Nodes (41): pci_channel_state_t, pci_ers_result_t, iommu_allocate_sgtable(), iommu_free(), fthd_irq_work(), fthd_is_powered(), fthd_mark_firmware_wedged(), fthd_pci_error_detected() (+33 more)

### Community 4 - "CI Watchdogs and Packaging"
Cohesion: 0.07
Nodes (37): Dependabot GitHub Actions pinning policy, Apple download watchdog job, Kernel build matrix (Ubuntu/Fedora/AlmaLinux), Clang strict build job, Sparse static analysis job, Every shell script is linted guard, packaging job (deb/rpm), CI workflow (+29 more)

### Community 5 - "Camera Controls and Hardware Validation"
Cohesion: 0.07
Nodes (31): Hardware report issue form, Debugfs created in probe(), destroyed in remove(), DDR/PLL/FWMSG bring-up messages are dev_dbg, Power management is not this project's job, facetimehd-runtime-pm.conf modprobe drop-in, A wrong firmware guess must be refused, not destructive, Hardware reports are the most valuable contribution, MacBookAir7,2 as the sole validation machine (+23 more)

### Community 6 - "Hardware Validation Test Script"
Cohesion: 0.19
Nodes (14): capture_ok(), check_ring_wrap(), dmesg_driver(), dmesg_mark(), dmesg_since(), load_module(), log(), log_section() (+6 more)

### Community 7 - "DDR and PLL Bring-up"
Cohesion: 0.18
Nodes (15): u32, fthd_ddr_verify_mem(), u32, fthd_ddr_phy_save_regs(), fthd_hw_ddr_phy_soft_reset(), fthd_hw_ddr_rewrite_mode_regs(), fthd_hw_ddr_status_busy(), fthd_hw_init() (+7 more)

### Community 8 - "Project Identity and Contribution Rules"
Cohesion: 0.12
Nodes (18): Bug report issue form, DOWNSTREAM.md is the review record for fork changes, driver-patches/ is a generated view, not an input, Fan support is deliberately its own script, Propose driver fixes upstream where they apply, Broadcom BCM1570 PCIe FaceTime HD Camera (14e4:1570), collect-diagnostics.sh one-file bug report, FaceTime HD Camera for Linux (project) (+10 more)

### Community 9 - "Ring Buffer and IRQ Handlers"
Cohesion: 0.31
Nodes (13): buf_t2h_handler(), u32, fthd_handle_irq(), io_t2h_handler(), sharedmalloc_handler(), terminal_handler(), u32, fthd_channel_ringbuf_dump() (+5 more)

### Community 10 - "Register and Memory Access Macros"
Cohesion: 0.41
Nodes (12): fthd_hw_pci_post(), _FTHD_ISP_REG_READ(), _FTHD_ISP_REG_WRITE(), fthd_range_valid(), fthd_s2_mem_range_valid(), _FTHD_S2_MEM_READ(), _FTHD_S2_MEM_WRITE(), _FTHD_S2_MEMCPY_FROMIO() (+4 more)

### Community 11 - "Firmware Extraction Tables"
Cohesion: 0.18
Nodes (8): CALIBRATION_HASHES, CALIBRATION_LAYOUT, DRIVER_COMPRESSION, DRIVER_NAMES, DRIVER_OFFSETS, DRIVER_SIZES, FIRMWARE_VERSIONS, usage()

### Community 12 - "Script Smoke Test"
Cohesion: 0.61
Nodes (7): check_dkms_format(), check_documented_options(), expect_output(), expect_status(), make_stub_dkms(), result(), script-smoke.sh script

### Community 14 - "Versioning and Idempotency Decisions"
Cohesion: 0.50
Nodes (4): diffutils is an RPM dependency on purpose, Installer idempotency via diff against /usr/src, Version derivation with source fingerprint, Package version omits the source fingerprint

## Knowledge Gaps
- **18 isolated node(s):** `build-deb.sh script`, `build-rpm.sh script`, `DRIVER_NAMES`, `DRIVER_OFFSETS`, `DRIVER_SIZES` (+13 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **6 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `fthd_pci_probe()` connect `Buffers, Debugfs and Driver Core` to `ISP Command Interface`, `V4L2 Streaming and Power Management`, `DDR and PLL Bring-up`?**
  _High betweenness centrality (0.011) - this node is a cross-community bridge._
- **Why does `Apple firmware extraction (firmware 1.43.0)` connect `CI Watchdogs and Packaging` to `Project Identity and Contribution Rules`?**
  _High betweenness centrality (0.009) - this node is a cross-community bridge._
- **Why does `fthd_start_channel()` connect `ISP Command Interface` to `V4L2 Streaming and Power Management`?**
  _High betweenness centrality (0.007) - this node is a cross-community bridge._
- **Are the 2 inferred relationships involving `fthd_start_channel()` (e.g. with `fthd_v4l2_refresh_crop()` and `fthd_stream_start()`) actually correct?**
  _`fthd_start_channel()` has 2 INFERRED edges - model-reasoned connections that need verification._
- **Are the 10 inferred relationships involving `fthd_pci_probe()` (e.g. with `fthd_buffer_exit()` and `fthd_buffer_init()`) actually correct?**
  _`fthd_pci_probe()` has 10 INFERRED edges - model-reasoned connections that need verification._
- **What connects `build-deb.sh script`, `build-rpm.sh script`, `DRIVER_NAMES` to the rest of the system?**
  _18 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `ISP Command Interface` be split into smaller, more focused modules?**
  _Cohesion score 0.050721954831543875 - nodes in this community are weakly interconnected._