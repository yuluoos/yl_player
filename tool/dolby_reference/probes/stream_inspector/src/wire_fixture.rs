//! TEST ONLY: omit object-level admission to exercise raw parser rejection.
//! Field writers, framing and CRC stay valid. Never used by the inspector.
use bitvec_helpers::bitstream_io_writer::BitstreamIoWriter;
use dolby_vision::rpu::dovi_rpu::DoviRpu;
use dolby_vision::rpu::extension_metadata::{DmData, WithExtMetadataBlocks};
use dolby_vision::rpu::extension_metadata::blocks::*;
use dolby_vision::utils::add_start_code_emulation_prevention_3_byte;
#[path = "cm4_fixture.rs"]
mod fixture;

pub fn crc(bytes: &[u8]) -> u32 {
    let mut value = u32::MAX;
    for byte in bytes {
        value ^= (*byte as u32) << 24;
        for _ in 0..8 {
            value = if value & 0x80000000 != 0 { (value << 1) ^ 0x04c11db7 } else { value << 1 };
        }
    }
    value
}

pub fn raw(rpu: &DoviRpu, unknown: bool) -> Vec<u8> {
    assert!(rpu.remaining.is_none());
    let mut w = BitstreamIoWriter::with_capacity(1024);
    w.write::<8, u8>(25).unwrap();
    rpu.header.write_header(&mut w).unwrap();
    if !rpu.header.use_prev_vdr_rpu_flag {
        rpu.rpu_data_mapping.as_ref().unwrap().write(&mut w, &rpu.header).unwrap();
    }
    let mut dm = rpu.vdr_dm_data.clone().unwrap();
    let cm4 = dm.cmv40_metadata.take().unwrap();
    dm.write(&mut w).unwrap();
    let DmData::V40(blocks) = cm4 else { panic!("fixture CM4") };
    w.write_ue(blocks.blocks_ref().len() as u64).unwrap(); w.byte_align().unwrap();
    for block in blocks.blocks_ref() {
        w.write_ue(block.length_bytes()).unwrap();
        w.write::<8, u8>(if unknown && block.level() == 3 { 216 } else { block.level() }).unwrap();
        block.write(&mut w).unwrap();
        w.pad((block.length_bits()-block.required_bits()) as u32).unwrap();
    }
    w.byte_align().unwrap();
    let checksum = crc(&w.as_slice().unwrap()[1..]);
    w.write::<32, u32>(checksum).unwrap(); w.write::<8, u8>(0x80).unwrap();
    let mut bytes=w.into_inner();add_start_code_emulation_prevention_3_byte(&mut bytes);
    bytes.splice(0..0,[0x7c,1]);bytes
}

pub struct Case {
    pub name: &'static str,
    pub rpu: DoviRpu,
    pub unknown: bool,
    pub patched_parse: bool,
    pub upstream_parse: bool,
}

fn blocks(rpu: &mut DoviRpu) -> &mut dolby_vision::rpu::extension_metadata::CmV40DmData {
    let Some(DmData::V40(blocks))=&mut rpu.vdr_dm_data.as_mut().unwrap().cmv40_metadata else { panic!("CM4") };
    blocks
}

pub fn cases() -> Vec<Case> {
    let records=fixture::records();let mut result=Vec::new();
    let mut missing=records[0].clone();blocks(&mut missing).remove_level(254);
    result.push(Case{name:"full_missing_l254",rpu:missing,unknown:false,patched_parse:false,upstream_parse:false});
    let mut static254=records[1].clone();blocks(&mut static254).add_block(ExtMetadataBlock::Level254(ExtMetadataBlockLevel254::cmv402_default())).unwrap();
    result.push(Case{name:"compressed_static_l254",rpu:static254,unknown:false,patched_parse:false,upstream_parse:true});
    let mut static10=records[1].clone();blocks(&mut static10).add_block(ExtMetadataBlock::Level10(ExtMetadataBlockLevel10::default())).unwrap();
    result.push(Case{name:"compressed_static_l10",rpu:static10,unknown:false,patched_parse:false,upstream_parse:false});
    let mut duplicate=records[0].clone();blocks(&mut duplicate).add_block(ExtMetadataBlock::Level3(ExtMetadataBlockLevel3::default())).unwrap();
    result.push(Case{name:"duplicate_l3",rpu:duplicate,unknown:false,patched_parse:false,upstream_parse:false});
    result.push(Case{name:"unknown_l216",rpu:records[0].clone(),unknown:true,patched_parse:false,upstream_parse:false});
    let mut targets=records[0].clone();
    for _ in 0..2 { blocks(&mut targets).add_block(ExtMetadataBlock::Level8(ExtMetadataBlockLevel8{ length:10,target_display_index:1,..Default::default() })).unwrap(); }
    result.push(Case{name:"duplicate_l8_target",rpu:targets,unknown:false,patched_parse:true,upstream_parse:true});
    result
}
