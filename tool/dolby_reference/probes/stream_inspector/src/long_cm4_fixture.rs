//! Long-form custom-primary wire values; source transport only.
#[path = "cm4_fixture.rs"]
mod fixture;
use dolby_vision::rpu::dovi_rpu::DoviRpu;
use dolby_vision::rpu::extension_metadata::{DmData,WithExtMetadataBlocks};
use dolby_vision::rpu::extension_metadata::blocks::*;
pub fn records() -> Vec<DoviRpu> {
    let mut records=fixture::records();
    for (i,rpu) in records.iter_mut().enumerate() {
        let Some(DmData::V40(blocks))=&mut rpu.vdr_dm_data.as_mut().unwrap().cmv40_metadata else {panic!("CM4")};
        if i==0 {
            blocks.remove_level(10);
            blocks.add_block(ExtMetadataBlock::Level10(ExtMetadataBlockLevel10 {
                length:21,target_display_index:3,target_max_pq:3079,target_min_pq:7,target_primary_index:255,
                target_primary_red_x:20000,target_primary_red_y:10000,target_primary_green_x:9000,target_primary_green_y:18000,
                target_primary_blue_x:4000,target_primary_blue_y:2000,target_primary_white_x:10248,target_primary_white_y:10747,
            })).unwrap();
        }
        if i%2==1 {
            blocks.remove_level(9);
            // Include the signed-wire boundary in one synthetic record. These
            // are not qualified physical display primaries or mapping targets.
            let edge=i==3;
            blocks.add_block(ExtMetadataBlock::Level9(ExtMetadataBlockLevel9 {
                length:17,source_primary_index:255,
                source_primary_red_x:if edge {32768} else {20001},source_primary_red_y:if edge {65535} else {10001},
                source_primary_green_x:if edge {1} else {9001},source_primary_green_y:if edge {32767} else {18001},
                source_primary_blue_x:4001,source_primary_blue_y:2001,source_primary_white_x:10249,source_primary_white_y:10748,
            })).unwrap();
        }
    }
    records
}
