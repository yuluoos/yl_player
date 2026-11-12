"""Keep bounded simulator startup evidence after an iOS CI failure."""
import os
from pathlib import Path
import subprocess


def main():
    simulator = os.environ.get("YL_IOS_SIMULATOR_ID")
    if not simulator:
        raise SystemExit("YL_IOS_SIMULATOR_ID is required")
    root = Path(os.environ.get("YL_APPLE_EVIDENCE_DIR", "packages/yl_player/example/build/apple-evidence"))
    root = root / "simulator-failure"
    root.mkdir(parents=True, exist_ok=True)
    commands = {
        "devices": ["xcrun", "simctl", "list", "devices", "--json"],
        "runner-log": ["xcrun", "simctl", "spawn", simulator, "log", "show",
                       "--last", "15m", "--style", "compact",
                       "--predicate", 'process == "Runner" OR senderImagePath ENDSWITH "/Flutter"'],
    }
    for name, command in commands.items():
        with (root / (name + ".log")).open("wb") as output:
            try:
                result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, timeout=60)
                output.write(("\nexitCode=" + str(result.returncode) + "\n").encode())
            except subprocess.TimeoutExpired:
                output.write(b"\ndiagnosticsTimedOutAfterSeconds=60\n")


if __name__ == "__main__":
    main()
