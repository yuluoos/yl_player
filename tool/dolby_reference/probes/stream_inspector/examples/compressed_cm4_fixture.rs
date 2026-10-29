#[path = "../src/cm4_fixture.rs"]
mod fixture;
use std::io::{self, Write};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut output = io::stdout().lock();
    for rpu in fixture::records() {
        let bytes = rpu.write_hevc_unspec62_nalu()?;
        output.write_all(&(bytes.len() as u32).to_be_bytes())?;
        output.write_all(&bytes)?;
    }
    Ok(())
}
