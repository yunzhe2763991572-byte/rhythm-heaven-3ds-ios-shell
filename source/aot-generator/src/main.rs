//! Local-only code generation. Never send the input or output to Actions.
use std::{env, path::{Path, PathBuf}};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = env::args_os().skip(1).collect();
    if args.len() != 2 {
        return Err("Usage: rh3ds-aot-generate <decrypted-game.cia> <new-output-directory>".into());
    }
    let output = PathBuf::from(&args[1]);
    if output.exists() { return Err("Use a new output directory; originals are never replaced".into()); }
    let title = recomp3ds::rom::Title::load(Path::new(&args[0]))?;
    if title.program_id() != 0x0004000000155A00 {
        return Err("Only the documented Japanese release is supported by this host configuration".into());
    }
    let generated = recomp3ds::build::generate(
        Path::new(&args[0]), |_| output, None, recomp3ds::Mods::default(),
        &|event| println!("{event:?}"),
    )?;
    println!("Generated {} local C units for {:016X}", generated.sources.len(), generated.title.program_id());
    Ok(())
}
