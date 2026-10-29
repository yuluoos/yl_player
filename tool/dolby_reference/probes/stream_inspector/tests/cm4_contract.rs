#[path = "../src/cm4_fixture.rs"]
mod fixture;
use dolby_vision::rpu::dovi_rpu::DoviRpu;
use dolby_vision::rpu::extension_metadata::{DmData, WithExtMetadataBlocks};
use dolby_vision::rpu::extension_metadata::blocks::*;

#[test]
fn compressed_context_is_explicit_and_full_cm4_stays_strict() {
    let patched = std::env::var("YL_TEST_COMPRESSED_CM4").as_deref() == Ok("1");
    let records = fixture::records();
    for (index, rpu) in records.iter().enumerate() {
        let bytes = rpu.write_hevc_unspec62_nalu();
        assert_eq!(bytes.is_ok(), index % 2 == 0 || patched);
        if let Ok(bytes) = bytes {
            let parsed = DoviRpu::parse_unspec62_nalu(&bytes).unwrap();
            assert_eq!(parsed.vdr_dm_data.unwrap().compressed, index % 2 == 1);
            let mut bad_crc = bytes.clone();
            let n = bad_crc.len(); bad_crc[n-4] ^= 1;
            assert!(DoviRpu::parse_unspec62_nalu(&bad_crc).is_err());
        }
    }
    let mut full = records[0].clone();
    if let Some(DmData::V40(blocks)) = &mut full.vdr_dm_data.as_mut().unwrap().cmv40_metadata {
        blocks.remove_level(254);
    }
    assert!(full.write_hevc_unspec62_nalu().is_err());
    if patched {
        for block in [ExtMetadataBlock::Level254(ExtMetadataBlockLevel254::cmv402_default()),
                      ExtMetadataBlock::Level10(ExtMetadataBlockLevel10 { length:5, ..Default::default() })] {
            let mut compressed = records[1].clone();
            if let Some(DmData::V40(blocks)) = &mut compressed.vdr_dm_data.as_mut().unwrap().cmv40_metadata {
                blocks.add_block(block).unwrap();
            }
            assert!(compressed.write_hevc_unspec62_nalu().is_err());
        }
    }
}
