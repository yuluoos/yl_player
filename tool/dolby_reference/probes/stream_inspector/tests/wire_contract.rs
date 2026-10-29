#[path = "../src/wire_fixture.rs"]
mod wire;
#[path = "../src/cm4_fixture.rs"]
mod fixture;
use dolby_vision::rpu::dovi_rpu::DoviRpu;
use dolby_vision::utils::clear_start_code_emulation_prevention_3_byte;

#[test]
fn raw_writer_matches_valid_library_bytes_and_known_crc_vector() {
    assert_eq!(wire::crc(b"123456789"),0x0376e6e7);
    let patched=std::env::var("YL_TEST_COMPRESSED_CM4").as_deref()==Ok("1");
    for (i,rpu) in fixture::records().iter().enumerate() {
        if i%2==0 || patched { assert_eq!(wire::raw(rpu,false),rpu.write_hevc_unspec62_nalu().unwrap()); }
    }
}

#[test]
fn raw_crc_valid_semantic_cases_reach_actual_parser() {
    let patched=std::env::var("YL_TEST_COMPRESSED_CM4").as_deref()==Ok("1");
    for case in wire::cases() {
        let bytes=wire::raw(&case.rpu,case.unknown);
        let data=clear_start_code_emulation_prevention_3_byte(&bytes[2..]);
        let end=data.len()-5;assert_eq!(wire::crc(&data[1..end]),u32::from_be_bytes(data[end..end+4].try_into().unwrap()));
        let parsed=DoviRpu::parse_unspec62_nalu(&bytes);
        assert_eq!(parsed.is_ok(),if patched {case.patched_parse} else {case.upstream_parse},"{}: {:?}",case.name,parsed.err());
    }
}
