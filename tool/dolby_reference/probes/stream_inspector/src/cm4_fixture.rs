//! Generated metadata transport cases, not a Dolby target.
use dolby_vision::rpu::dovi_rpu::DoviRpu;
use dolby_vision::rpu::extension_metadata::{CmV29DmData, CmV40DmData, DmData, WithExtMetadataBlocks};
use dolby_vision::rpu::extension_metadata::blocks::*;
use dolby_vision::rpu::generate::GenerateConfig;

pub fn records() -> Vec<DoviRpu> {
    let mut full = DoviRpu::profile81_config(&GenerateConfig::default()).unwrap();
    let mut cm4 = CmV40DmData::default_safe();
    cm4.add_block(ExtMetadataBlock::Level10(ExtMetadataBlockLevel10 {
        length: 5, target_display_index: 3, target_max_pq: 3079,
        target_min_pq: 7, target_primary_index: 0, ..Default::default()
    })).unwrap();
    full.vdr_dm_data.as_mut().unwrap().cmv40_metadata = Some(DmData::V40(cm4));
    let mut reset = full.clone();
    let dm = reset.vdr_dm_data.as_mut().unwrap();
    let mut dynamic = CmV29DmData::default();
    dynamic.add_block(ExtMetadataBlock::Level1(ExtMetadataBlockLevel1 {
        min_pq: 0, max_pq: 3079, avg_pq: 1100,
    })).unwrap();
    dm.cmv29_metadata = Some(DmData::V29(dynamic));
    dm.cmv40_metadata = Some(DmData::V40(CmV40DmData::new_with_l254_402()));
    dm.source_min_pq = 8;
    vec![full.clone(), compressed(&full, true), reset.clone(), compressed(&reset, false)]
}

fn compressed(full: &DoviRpu, multiple: bool) -> DoviRpu {
    let mut result = full.clone();
    result.header.reserved_zero_3bits = 1;
    result.header.use_prev_vdr_rpu_flag = true;
    result.rpu_data_mapping = None;
    let dm = result.vdr_dm_data.as_mut().unwrap();
    dm.compressed = true;
    let mut dynamic = CmV29DmData::default();
    dynamic.add_block(ExtMetadataBlock::Level1(ExtMetadataBlockLevel1 {
        min_pq: 1, max_pq: 3078, avg_pq: 1200,
    })).unwrap();
    dm.cmv29_metadata = Some(DmData::V29(dynamic));
    let mut cm4 = CmV40DmData::default();
    cm4.add_block(ExtMetadataBlock::Level3(ExtMetadataBlockLevel3 {
        min_pq_offset: 2049, max_pq_offset: 2050, avg_pq_offset: 2051,
    })).unwrap();
    let lengths: &[u64] = if multiple { &[10, 12, 13, 19, 25] } else { &[25] };
    for (index, length) in lengths.iter().enumerate() {
        cm4.add_block(ExtMetadataBlock::Level8(ExtMetadataBlockLevel8 {
            length: *length, target_display_index: index as u8 + 1,
            trim_slope: 2001, trim_offset: 2002, trim_power: 2003,
            trim_chroma_weight: 2004, trim_saturation_gain: 2005, ms_weight: 2006,
            target_mid_contrast: if *length >= 12 { 2007 } else { 0 },
            clip_trim: if *length >= 13 { 2008 } else { 0 },
            saturation_vector_field0: if *length >= 19 { 11 } else { 0 },
            hue_vector_field5: if *length >= 25 { 22 } else { 0 },
            ..Default::default()
        })).unwrap();
    }
    cm4.add_block(ExtMetadataBlock::Level9(ExtMetadataBlockLevel9::default_dci_p3())).unwrap();
    cm4.add_block(ExtMetadataBlock::Level11(ExtMetadataBlockLevel11::default_cinema())).unwrap();
    dm.cmv40_metadata = Some(DmData::V40(cm4));
    result
}
