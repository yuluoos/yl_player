//! Synthetic RPUs for parser/state tests only; not a media or quality reference.
use dolby_vision::rpu::dovi_rpu::DoviRpu;
use dolby_vision::rpu::extension_metadata::{CmV29DmData, CmV40DmData, DmData, WithExtMetadataBlocks};
use dolby_vision::rpu::extension_metadata::blocks::{ExtMetadataBlock, ExtMetadataBlockLevel1, ExtMetadataBlockLevel2, ExtMetadataBlockLevel5};
use dolby_vision::rpu::generate::GenerateConfig;
use std::io::{self, Write};

fn dynamic() -> CmV29DmData {
    let mut result = CmV29DmData::default();
    result.add_block(ExtMetadataBlock::Level1(ExtMetadataBlockLevel1 {
        min_pq: 0, max_pq: 3079, avg_pq: 1300,
    })).unwrap();
    result.add_block(ExtMetadataBlock::Level5(ExtMetadataBlockLevel5::default())).unwrap();
    result
}

fn compressed(full: &DoviRpu) -> DoviRpu {
    let mut rpu = full.clone();
    rpu.header.reserved_zero_3bits = 1;
    rpu.header.use_prev_vdr_rpu_flag = true;
    rpu.rpu_data_mapping = None;
    let dm = rpu.vdr_dm_data.as_mut().unwrap();
    dm.compressed = true;
    dm.cmv29_metadata = Some(DmData::V29(dynamic()));
    dm.cmv40_metadata = None;
    rpu
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut full = DoviRpu::profile81_config(&GenerateConfig::default())?;
    let dm = full.vdr_dm_data.as_mut().unwrap();
    if let Some(DmData::V29(blocks)) = &mut dm.cmv29_metadata {
        blocks.add_block(ExtMetadataBlock::Level2(ExtMetadataBlockLevel2 {
            target_max_pq: 2081, ..Default::default()
        }))?;
        blocks.add_block(ExtMetadataBlock::Level2(ExtMetadataBlockLevel2 {
            target_max_pq: 3079, ..Default::default()
        }))?;
    }
    dm.cmv40_metadata = Some(DmData::V40(CmV40DmData::default_safe()));
    let mut reset = full.clone();
    let dm = reset.vdr_dm_data.as_mut().unwrap();
    dm.cmv29_metadata = Some(DmData::V29(dynamic()));
    dm.cmv40_metadata = None;
    let records = [full.clone(), compressed(&full), reset.clone(), compressed(&reset)];
    let mut output = io::stdout().lock();
    for rpu in records {
        let bytes = rpu.write_hevc_unspec62_nalu()?;
        DoviRpu::parse_unspec62_nalu(&bytes)?;
        output.write_all(&(bytes.len() as u32).to_be_bytes())?;
        output.write_all(&bytes)?;
    }
    Ok(())
}
