//! Synthetic valid RPUs exercise the real library/parser boundary, not image quality.
use dolby_vision::rpu::dovi_rpu::DoviRpu;
use dolby_vision::rpu::extension_metadata::{CmV29DmData, DmData, WithExtMetadataBlocks};
use dolby_vision::rpu::extension_metadata::blocks::{ExtMetadataBlock, ExtMetadataBlockLevel1, ExtMetadataBlockLevel5};
use dolby_vision::rpu::generate::GenerateConfig;
use dolby_vision::rpu::vdr_dm_data::CmVersion;
use std::fs;
use std::process::Command;

#[test]
fn optional_color_header_preserves_compression_placeholders_and_old_modes() {
    let config = GenerateConfig { cm_version: CmVersion::V29, ..Default::default() };
    let full = DoviRpu::profile81_config(&config).unwrap();
    let mut compressed = full.clone();
    compressed.header.reserved_zero_3bits = 1;
    compressed.header.use_prev_vdr_rpu_flag = true;
    compressed.header.prev_vdr_rpu_id = 0;
    compressed.rpu_data_mapping = None;
    let dm = compressed.vdr_dm_data.as_mut().unwrap();
    dm.compressed = true;
    dm.scene_refresh_flag = 1;
    // Keep this synthetic NAL above libdovi's 25-byte minimum with valid
    // dynamic blocks; compressed records must not carry static L6 metadata.
    let mut dynamic = CmV29DmData::default();
    dynamic.add_block(ExtMetadataBlock::Level1(ExtMetadataBlockLevel1 {
        min_pq: 0, max_pq: 3079, avg_pq: 1000,
    })).unwrap();
    dynamic.add_block(ExtMetadataBlock::Level5(ExtMetadataBlockLevel5::default())).unwrap();
    dm.cmv29_metadata = Some(DmData::V29(dynamic));
    dm.cmv40_metadata = None;
    let mut framed = Vec::new();
    for rpu in [full, compressed] {
        let bytes = rpu.write_hevc_unspec62_nalu().unwrap();
        DoviRpu::parse_unspec62_nalu(&bytes).unwrap();
        framed.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
        framed.extend_from_slice(&bytes);
    }
    let dir = std::env::temp_dir().join(format!("yl-dovi-color-contract-{}", std::process::id()));
    fs::create_dir(&dir).unwrap();
    let path = dir.join("synthetic.rpus");
    fs::write(&path, framed).unwrap();
    for mode in [None, Some("--mapping"), Some("--dm-color")] {
        let mut command = Command::new(env!("CARGO_BIN_EXE_yl-dovi-stream-inspector"));
        command.arg(&path);
        if let Some(flag) = mode { command.arg(flag); }
        let output = command.output().unwrap();
        assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
        let records: Vec<serde_json::Value> = String::from_utf8(output.stdout).unwrap()
            .lines().map(|line| serde_json::from_str(line).unwrap()).collect();
        assert_eq!(records.len(), 2);
        assert_eq!(records[0]["display_metadata"]["signal_bit_depth"], 12);
        assert_eq!(records[1]["display_metadata"]["signal_bit_depth"], 0);
        assert_eq!(records[1]["display_metadata"]["ycc_to_rgb_coef0"], 0);
        assert_eq!(records[1]["display_metadata"]["compressed"], true);
        assert_eq!(records[1]["display_metadata"]["scene_refresh_flag"], 1);
        assert_eq!(records[1].get("rpu_header").is_some(), mode == Some("--dm-color"));
        assert_eq!(records[1].get("mapping").is_some(), mode.is_some());
        if mode == Some("--dm-color") {
            assert_eq!(records[1]["rpu_header"]["reserved_zero_3bits"], 1);
            assert_eq!(records[1]["rpu_header"]["vdr_seq_info_present_flag"], true);
            assert_eq!(records[1]["previous_mapping_id"], 0);
        }
    }
    fs::remove_dir_all(dir).unwrap();
}
