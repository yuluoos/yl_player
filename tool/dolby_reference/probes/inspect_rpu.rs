// Research-only: inspect one extracted, unmodified UNSPEC62 NAL. No conversion.
use dolby_vision::rpu::dovi_rpu::DoviRpu;
fn main() {
    let result = (|| -> Result<(), Box<dyn std::error::Error>> {
        let path = std::env::args().nth(1).ok_or("missing input")?;
        if std::fs::metadata(&path)?.len() > 65536 { return Err("size".into()); }
        let bytes = std::fs::read(path)?;
        let rpu = DoviRpu::parse_unspec62_nalu(&bytes)?;
        println!("{}", serde_json::to_string(&rpu)?);
        Ok(())
    })();
    if result.is_err() {
        eprintln!("RPU inspection failed");
        std::process::exit(2);
    }
}
