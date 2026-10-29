#[path = "../src/wire_fixture.rs"]
mod fixture;
use std::{fs, path::PathBuf};
fn main() -> Result<(),Box<dyn std::error::Error>> {
    let args:Vec<_>=std::env::args_os().collect();if args.len()!=2 {return Err("output directory required".into());}
    let root=PathBuf::from(&args[1]);fs::create_dir(&root)?;
    let mut manifest=Vec::new();
    for case in fixture::cases() {
        let bytes=fixture::raw(&case.rpu,case.unknown);
        let mut framed=(bytes.len() as u32).to_be_bytes().to_vec();framed.extend_from_slice(&bytes);
        let name=format!("{}.rpus",case.name);fs::write(root.join(&name),framed)?;
        manifest.push(serde_json::json!({"name":case.name,"file":name,"patched_parse":case.patched_parse,"upstream_parse":case.upstream_parse}));
    }
    println!("{}",serde_json::to_string(&manifest)?);Ok(())
}
