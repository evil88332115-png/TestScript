# TestScript

Jetson/Ubuntu hardware validation scripts for media playback, storage, network, RTC, CPU, memory, and benchmark tests.

This repository is intended to be copied to a Jetson target and run locally from the target system.

## Target environment

- Ubuntu / Jetson Linux
- NVIDIA JetPack / L4T for Jetson-specific multimedia tests
- Bash shell
- `sudo` access
- NAS mount available for media test files when required

Install common requirements first:

```bash
chmod +x run_0_mount_nas.sh
./run_0_mount_nas.sh
```

`run_0_mount_nas.sh` installs/checks the shared dependencies used by the test scripts, then mounts the NAS test-data share.

## Basic usage

```bash
git clone https://github.com/evil88332115-png/MaxTestScript.git
cd MaxTestScript
chmod +x *.sh
./run_0_mount_nas.sh
```

Then run the required test script directly:

```bash
./run_4_6_CPU.sh
./run_5_11_network_interface_initialization.sh
./run_7_2_memory.sh
```

Some scripts are interactive and may ask for interface selection, server IP, password, mount path, shutdown time, or test mode.

## Script list

### Setup

| Script | Purpose |
| --- | --- |
| `run_0_mount_nas.sh` | Install/check common test dependencies and mount NAS share for test media files |
| `run_1_requirement.sh` | Install/check common test dependencies only |
| `check.sh` | General check script |

### System / storage / network

| Script | Purpose |
| --- | --- |
| `run_4_5_resolution.sh` | Auto-detect and switch display resolutions from largest to smallest, then back to largest |
| `run_4_6_CPU.sh` | Print CPU online/present/possible/max frequency information |
| `run_4_7_memory.sh` | Memory test |
| `run_4_8_nvme.sh` | NVMe test |
| `run_4_9_usb.sh` | USB storage test |
| `run_4_10_iperf.sh` | LAN iperf test |
| `run_4_11_iperf_dual.sh` | Dual iperf test |
| `run_4_12_sftp.sh` | SFTP transfer test |
| `run_5_10_internet_download_test.sh` | Internet download/upload test using wget/wput |
| `run_5_11_network_interface_initialization.sh` | Interactive LAN/Wi-Fi down/up initialization test |
| `run_6_5_lan_continuous_throughput_monitoring.sh` | Continuous LAN throughput monitoring |
| `run_6_6_network_monitor_packet_loss_rate.sh` | Continuous packet loss and latency monitoring using mtr |
| `run_6_7_maximum_storage_utilization_test.sh` | Fill root filesystem with dd while leaving reserved free space |
| `run_6_9_system_stress_test.sh` | System stress menu using glmark2, glxgears, memtester, and bonnie++ |

### Multimedia

| Script | Purpose |
| --- | --- |
| `run_4_21_audio_decode.sh` | Audio decode playback test |
| `run_4_23_video_decode.sh` | Video decode playback test |
| `run_4_24_reader_container_formats.sh` | Container format read/playback test |
| `run_6_3_stress_test_via_online_streaming_playback.sh` | Online streaming playback stress test with one-line FPS/system status |
| `run_5_7_fps.sh` | FPS/video playback test |
| `run_5_8_video_bit_rate.sh` | Video bitrate playback test |
| `run_5_9_vertical_multimedia.sh` | Vertical 1080x1920 playback and rotation test |

### Thermal / RTC / benchmark

| Script | Purpose |
| --- | --- |
| `run_4_25_thermal_drawtemp.sh` | Thermal test with hardware decode playback and CPU+GPU temperature curve output |
| `drawtempcurve_auto.py` | Temperature curve drawing helper |
| `run_5_4_rtc.sh` | Interactive RTC/timezone/shutdown test |
| `run_5_5_display_resolution.sh` | Play a video while switching display resolutions by operator Enter confirmation |
| `run_7_1_coremark.sh` | CoreMark-PRO clone/build/run script |
| `run_7_2_memory.sh` | sysbench memory read/write test |
| `run_7_3_nvme_ssd.sh` | NVMe SSD dd read/write test |
| `run_7_4_USB.sh` | Auto-detected USB storage dd read/write test |
| `run_7_5_graphics_engine.sh` | Graphics engine benchmark using glmark2 and GravityMark |
| `run_7_6_iperf2_network_bandwidth_test.sh` | iperf2 network bandwidth test with CSV/PNG/PDF report |
| `run_8_1_emmc_internal_storage.sh` | eMMC/internal storage loop write stress test |
| `run_8_3_client_net_security_test.sh` | Client network security/reliability test using ping, HTTP request, and iperf3 |

## Notes

- Some tests write temporary files to storage devices. Confirm the selected device/mount point before running storage tests.
- Network tests may bring interfaces down/up and can disconnect SSH sessions.
- `run_5_11_network_interface_initialization.sh` includes normal and low-level LAN/Wi-Fi modes. Use the low-level modes only when validating LED/UI behavior.
- Multimedia tests may depend on NAS paths such as `/mnt/nas_home/TEST FILE/...`. Mount NAS before running those tests.
- Jetson multimedia tests require NVIDIA GStreamer components such as `nvv4l2decoder`, `nv3dsink`, and `nvgstplayer-1.0`.
