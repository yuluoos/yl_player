use oxideav_dts::{iter_frames, CoreStreamDecoder};
use std::{env, fs, io::{self, Write}};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let stream = fs::read(env::args_os().nth(1).expect("DTS elementary stream"))?;
    let mut decoder = CoreStreamDecoder::new(2);
    let mut output = io::BufWriter::new(io::stdout().lock());
    let mut consumed = 0;
    for frame in iter_frames(&stream) {
        let frame = frame?;
        let pcm = decoder.decode_frame(frame.data, &frame.header)?;
        assert_eq!(pcm.len(), 2);
        assert_eq!(pcm[0].len(), 512);
        assert_eq!(pcm[1].len(), 512);
        for (left, right) in pcm[0].iter().zip(&pcm[1]) {
            output.write_all(&left.to_le_bytes())?;
            output.write_all(&right.to_le_bytes())?;
        }
        consumed += frame.data.len();
    }
    assert_eq!(consumed, stream.len());
    output.flush()?;
    Ok(())
}
