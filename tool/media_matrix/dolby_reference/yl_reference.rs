use oxideav_core::{CodecId, CodecParameters, CodecRegistry, Frame, Packet, TimeBase};
use std::{env, fs, io::{self, Write}};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = env::args().collect();
    let mut registry = CodecRegistry::new();
    oxideav_ac3::register_codecs(&mut registry);
    let params = CodecParameters::audio(CodecId::new(&args[1]));
    let mut decoder = registry.first_decoder(&params)?;
    let bytes = fs::read(&args[2])?;
    let mut input = bytes.as_slice();
    let mut pcm = io::BufWriter::new(io::stdout().lock());
    let mut pts = 0;
    while !input.is_empty() {
        let size = u32::from_be_bytes(input[..4].try_into()?) as usize;
        let packet = Packet::new(0, TimeBase::new(1, 48000), input[4..4+size].to_vec()).with_pts(pts);
        input = &input[4+size..];
        decoder.send_packet(&packet)?;
        let Frame::Audio(frame) = decoder.receive_frame()? else { return Err("expected audio".into()) };
        assert_eq!(frame.samples, 1536);
        pcm.write_all(&frame.data[0])?;
        pts += i64::from(frame.samples);
    }
    pcm.flush()?;
    Ok(())
}
