// Research-only: unmodified, bounded RPU NALs and signalled metadata only.
use std::collections::BTreeMap;
use std::fs::File;
use std::io::{self, BufReader, BufWriter, Read, Write};
use dolby_vision::rpu::dovi_rpu::DoviRpu;
use dolby_vision::rpu::extension_metadata::{DmData, WithExtMetadataBlocks};

type ProbeResult<T> = Result<T, Box<dyn std::error::Error>>;

fn read_frame(input: &mut impl Read) -> ProbeResult<Option<Vec<u8>>> {
    let mut header = [0u8; 4];
    if input.read(&mut header[..1])? == 0 { return Ok(None); }
    input.read_exact(&mut header[1..])?;
    let length = u32::from_be_bytes(header) as usize;
    if !(1..=65536).contains(&length) { return Err("length".into()); }
    let mut data = vec![0u8; length];
    input.read_exact(&mut data)?;
    Ok(Some(data))
}

fn levels(metadata: &DmData) -> Vec<u8> {
    let blocks = match metadata {
        DmData::V29(value) => value.blocks_ref(),
        DmData::V40(value) => value.blocks_ref(),
    };
    let mut values: Vec<u8> = blocks.iter().map(|block| block.level()).collect();
    values.sort(); values.dedup(); values
}

fn run() -> ProbeResult<()> {
    let args: Vec<_> = std::env::args_os().collect();
    let mapping_mode = args.len() == 3 && args[2] == "--mapping";
    if args.len() != 2 && !mapping_mode { return Err("arguments".into()); }
    let file = File::open(&args[1])?;
    if file.metadata()?.len() > 32*1024*1024 { return Err("size".into()); }
    let mut input = BufReader::new(file);
    let mut output = BufWriter::new(io::stdout().lock());
    let mut count = 0;
    while let Some(data) = read_frame(&mut input)? {
        count += 1;
        if count > 32768 { return Err("count".into()); }
        let rpu = DoviRpu::parse_unspec62_nalu(&data)?;
        let mut cm_levels = BTreeMap::new();
        if let Some(dm) = &rpu.vdr_dm_data {
            if let Some(value) = &dm.cmv29_metadata { cm_levels.insert("2.9", levels(value)); }
            if let Some(value) = &dm.cmv40_metadata { cm_levels.insert("4.0", levels(value)); }
        }
        let mut record = serde_json::json!({
            "profile": rpu.dovi_profile,
            "el_type": rpu.el_type,
            "cm_levels": cm_levels,
            "display_metadata": rpu.vdr_dm_data,
            "use_previous_mapping": rpu.header.use_prev_vdr_rpu_flag,
            "unparsed_rpu_bits": rpu.remaining.as_ref().map_or(0, |bits| bits.len()),
        });
        if mapping_mode {
            record["mapping"] = serde_json::to_value(&rpu.rpu_data_mapping)?;
            record["previous_mapping_id"] = serde_json::to_value(
                if rpu.header.use_prev_vdr_rpu_flag { Some(rpu.header.prev_vdr_rpu_id) } else { None })?;
        }
        serde_json::to_writer(&mut output, &record)?;
        output.write_all(b"\n")?;
    }
    if count == 0 { return Err("empty".into()); }
    output.flush()?;
    Ok(())
}

fn main() {
    if run().is_err() {
        eprintln!("RPU stream inspection failed");
        std::process::exit(2);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn empty_eof_is_distinct_from_truncated_frame() {
        assert!(read_frame(&mut Cursor::new([])).unwrap().is_none());
        for data in [vec![0], vec![0, 0, 0], vec![0, 0, 0, 3, 124, 1]] {
            assert!(read_frame(&mut Cursor::new(data)).is_err());
        }
    }
    #[test]
    fn declared_lengths_are_bounded_before_allocation() {
        for length in [0u32, 65537, u32::MAX] {
            assert!(read_frame(&mut Cursor::new(length.to_be_bytes())).is_err());
        }
    }
    #[test]
    fn original_bytes_are_preserved_and_eof_checked() {
        let mut input = Cursor::new([0, 0, 0, 3, 124, 1, 25]);
        assert_eq!(read_frame(&mut input).unwrap(), Some(vec![124, 1, 25]));
        assert!(read_frame(&mut input).unwrap().is_none());
    }
}
