#[path = "../src/long_cm4_fixture.rs"]
mod fixture;
use std::io::{self,Write};
fn main() -> Result<(),Box<dyn std::error::Error>> {
    let mut out=io::stdout().lock();
    for rpu in fixture::records() {
        let bytes=rpu.write_hevc_unspec62_nalu()?;
        out.write_all(&(bytes.len() as u32).to_be_bytes())?;out.write_all(&bytes)?;
    }
    Ok(())
}
